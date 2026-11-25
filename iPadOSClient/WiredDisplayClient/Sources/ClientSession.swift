import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Network
import os
import UIKit
import WDProtocol
import WDSession
import WDVideo

struct WirelessMac: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let fingerprint: String?
}

/// Observable connection state for the UI. Main actor only.
@MainActor @Observable
final class ConnectionModel {
    enum Phase: Equatable {
        case starting
        case waitingForMac
        case connecting
        case streaming
        case failed(String)
    }

    var phase: Phase = .starting
    var macName = ""
    var streamConfig: StreamConfig?
    var lastError: String?
    var framesShown = 0
    var framesDropped = 0
    var wirelessEnabled = false
    var wirelessMacs: [WirelessMac] = []
    var wirelessStatus: String?
    var transport: String?
    var supportsWirelessSidecar = false
    var keyEventsSent = 0
    var pointerEventsSent = 0
    var speakerFramesReceived = 0
    var speakerUnderruns = 0
    var speakerFormat: String?
    var outputRoute: String?
    var speakerOn = false
    var microphoneOn = false
    /// Set while an unknown Mac waits for the user to confirm pairing (D-023).
    var pairingCode: String?
    var pairedMacs: [TrustStore.TrustedPeer] = []
    /// Brightness indicator (D-033): the value and a token that changes on
    /// every Mac-driven change, so the overlay can hide after a moment.
    var brightnessHUD: (value: Float, token: Int)?
}

/// One encrypted Mac session at a time. USB uses the original loopback
/// listener. The optional Wi-Fi path dials a discovered Mac instead.
///
/// Concurrency: all mutable state below is confined to `queue`; that is the
/// invariant behind `@unchecked Sendable`. UI updates hop to the main actor.
final class ClientSession: @unchecked Sendable {
    private static let bonjourType = "_wireddisplay._tcp"
    private static let wirelessEnabledKey = "wirelessDesktopEnabled"
    private static let wirelessPreferenceKey = "wirelessDesktopPreferredMac"
    private static let wirelessAddressKey = "wirelessDesktopLastWiredAddress"

    /// Received from the Mac that starts the managed USB desktop. The address
    /// is a fallback hint; it grants no trust to whatever listens there.
    static func rememberWirelessAddress(_ value: String) {
        guard privateWirelessAddress(value) != nil else { return }
        UserDefaults.standard.set(value, forKey: wirelessAddressKey)
    }

    private static func privateWirelessAddress(_ value: String) -> IPv4Address? {
        guard let address = IPv4Address(value) else { return nil }
        let bytes = Array(address.rawValue)
        guard bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168) else { return nil }
        return address
    }

    private struct WirelessPreference: Codable {
        let serviceID: String
        let name: String
        let identity: [UInt8]
    }

    private struct WirelessAttempt {
        let mac: WirelessMac
        /// Required on an automatic attempt. Manual pairing compares a code.
        let pinnedIdentity: [UInt8]?
    }

    private let queue = DispatchQueue(label: "wireddisplay.client.session", qos: .userInteractive)
    private let model: ConnectionModel
    private let renderer: SwitchableSink
    private var decodeFailures = DecodeFailureDetector()
    private var hello: Hello

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var wirelessEndpoints: [String: NWEndpoint] = [:]
    private var wirelessMacs: [WirelessMac] = []
    private var wirelessEnabled = UserDefaults.standard.bool(forKey: ClientSession.wirelessEnabledKey)
    private var wirelessPreference: WirelessPreference? = {
        guard let data = UserDefaults.standard.data(forKey: ClientSession.wirelessPreferenceKey) else { return nil }
        return try? JSONDecoder().decode(WirelessPreference.self, from: data)
    }()
    private var wirelessAttempt: WirelessAttempt?
    private var wirelessRetry: DispatchWorkItem?
    private var wirelessRetryDelay: TimeInterval = 1
    private var blockAutomaticReconnect = false
    private var connection: NWConnection?
    private var parser = FrameParser()
    private var validator: SequenceValidator?
    private var framer = SessionFramer(sessionID: 0, clock: { 0 })
    private var peerHello: Hello?
    private var config: StreamConfig?
    private var format: CMVideoFormatDescription?
    private var formatSets: [[UInt8]] = []
    private var lastKeyframeRequest = Date.distantPast
    private var lastHeard = Date()
    private var handshakeDeadline = Date.distantFuture
    /// D-023: this iPad's identity and the Macs it trusts (Keychain).
    let trust = TrustStore(keychainService: "org.autosidecar.companion.receiver")
    private var channel: SecureChannel?
    /// The Mac proved its identity but the user has not confirmed it yet.
    private var pendingPeer: SecureChannel.Peer?
    private var trustedPeer: SecureChannel.Peer?
    /// The Mac's hello can arrive before the user confirms pairing.
    private var pendingHostHello: Hello?
    private var outstandingSends = 0
    private var watchdog: DispatchSourceTimer?
    private var running = false
    private var foreground = false
    /// What the user enabled; re-sent to the host on every new connection.
    private var audioRoute = (speaker: false, microphone: false)
    /// False while the app is in the background with audio running (D-018).
    private var videoActive = true
    private let speakerBuffers: SpeakerBuffers
    private var speakerSink: AudioJitterBuffer { speakerBuffers.active }
    private var speakerPackets = 0
    private var speakerFramesReceived = 0
    private var speakerUnderrunsAtConnect = 0
    private var speakerFormat: String?
    private var keyEventsSent = 0
    private var pointerEventsSent = 0
    private var presentMeter = FrameRateMeter()
    /// Latency diagnostics: host clock minus iPad clock, estimated from pings
    /// (the largest sample is closest, since one-way delay only lowers it).
    private var clockOffset: Int64?
    /// Recent offset samples (one per ping, every 2 s). The offset is the max
    /// over the last 8 only: the Mac and iPad clocks drift ~20 ppm apart, and
    /// an all-time max made "sent->enqueued" climb 1.2 ms a minute (soak test,
    /// audit). Cleared on every connection.
    private var offsetSamples: [Int64] = []
    private var transitSamples: [Double] = []
    private var droppedMicrophone = 0

    init(model: ConnectionModel, renderer: SwitchableSink, hello: Hello, speakerSink: SpeakerBuffers) {
        self.model = model
        self.renderer = renderer
        self.hello = hello
        speakerBuffers = speakerSink
        refreshPairedMacs()
        let wifi = wirelessEnabled
        ui { $0.wirelessEnabled = wifi }
    }

    /// The user answered the pairing prompt for the current connection.
    func answerPairing(code: String, accept: Bool) {
        queue.async { [self] in
            guard let peer = pendingPeer, peer.pairingCode == code, let connection else { return }
            pendingPeer = nil
            ui { $0.pairingCode = nil }
            guard accept else {
                if wirelessAttempt != nil { blockAutomaticReconnect = true }
                return endConnection(reason: "pairing declined on the iPad", sendBye: true)
            }
            do {
                try trust.trust(peer.identityKey, name: "Mac")
            } catch {
                return endConnection(reason: "could not save pairing: \(error)", sendBye: true)
            }
            ClientLog.write("paired with Mac \(peer.fingerprint)")
            refreshPairedMacs()
            becomeTrusted(peer, on: connection)
        }
    }

    func forgetPairedMacs() {
        queue.async { [self] in
            trust.forgetAllPeers()
            wirelessPreference = nil
            UserDefaults.standard.removeObject(forKey: Self.wirelessPreferenceKey)
            UserDefaults.standard.removeObject(forKey: Self.wirelessAddressKey)
            endConnection(reason: "pairing cleared on the iPad", sendBye: true)
            refreshPairedMacs()
        }
    }

    private func refreshPairedMacs() {
        let peers = trust.peers
        ui { $0.pairedMacs = peers }
    }

    /// The Mac set the iPad's brightness (keys or menu slider, D-033). Main actor.
    var onBrightness: (@MainActor @Sendable (Float) -> Void)?
    /// Local cursor (D-038), delivered on the main queue.
    var onCursor: (@MainActor @Sendable (Float, Float, Bool) -> Void)?
    var onCursorImage: (@MainActor @Sendable (CursorImage) -> Void)?
    private var reportedBrightness: Float?

    /// The live protocol supports a size update. A change of codec, HDR or rate
    /// requires a fresh authenticated hello, using the existing paired identity.
    func updateDisplayProfile(_ next: Hello) {
        queue.async { [self] in
            guard next != hello else { return }
            var resized = hello
            resized.pixelWidth = next.pixelWidth
            resized.pixelHeight = next.pixelHeight
            hello = next
            guard let connection, trustedPeer != nil else { return }
            if resized == next, peerHello != nil {
                let payload = SessionCodec.encode(.panelSize(width: next.pixelWidth, height: next.pixelHeight))
                send(stream: .control, payload: payload, on: connection)
            } else {
                endConnection(reason: "iPad 顯示能力更新，正在重新協商", sendBye: true)
            }
        }
    }

    /// Tell the Mac the iPad's current brightness (connect, Control Center).
    func sendBrightness(_ value: Float) {
        queue.async { [self] in
            reportedBrightness = value
            guard let connection, peerHello != nil else { return }
            send(stream: .control, payload: SessionCodec.encode(.brightness(value)), on: connection)
        }
    }

    func setAudioRoute(speaker: Bool, microphone: Bool) {
        queue.async { [self] in
            audioRoute = (speaker, microphone)
            guard let connection, peerHello != nil else { return }
            send(stream: .control, payload: SessionCodec.encode(.audioRoute(speaker: speaker, microphone: microphone)),
                 on: connection)
        }
    }

    /// Background with audio: keep the connection, pause video (D-018).
    func setVideoActive(_ active: Bool) {
        queue.async { [self] in
            guard videoActive != active else { return }
            videoActive = active
            if !active {
                foreground = false
                stopWirelessDiscovery()
                if wirelessAttempt != nil, peerHello == nil {
                    endConnection(reason: "iPad left the foreground during Wi-Fi pairing", sendBye: false)
                }
                config = nil
                format = nil
                renderer.flush(removingImage: true)
            }
            guard let connection, peerHello != nil else { return }
            send(stream: .control, payload: SessionCodec.encode(.videoActive(active)), on: connection)
        }
    }

    func sendMicrophone(_ packet: AudioPacket) {
        queue.async { [self] in
            guard let connection, peerHello != nil, audioRoute.microphone else {
                droppedMicrophone += 1
                if droppedMicrophone == 1 || droppedMicrophone % 500 == 0 {
                    ClientLog.write("microphone packet not sent (connected \(self.connection != nil), " +
                                    "hello \(peerHello != nil), route \(audioRoute.microphone)) x\(droppedMicrophone)")
                }
                return
            }
            // Bounded: never let microphone audio pile up behind a slow link.
            guard outstandingSends <= 64 else { return }
            send(stream: .microphone, payload: packet.encoded(), on: connection)
        }
    }


    // MARK: lifecycle (call from main)

    func start() {
        queue.async { [self] in
            foreground = true
            if !running {
                running = true
                startListener()
            }
            startWirelessDiscovery()
            scheduleWirelessReconnect()
        }
    }

    /// App leaving the foreground or user disconnect: iPadOS suspends us, so
    /// close cleanly instead of pretending to stay connected.
    func stop(reason: String) {
        queue.async { [self] in
            running = false
            foreground = false
            stopWirelessDiscovery()
            endConnection(reason: reason, sendBye: true)
            listener?.cancel()
            listener = nil
            ui { $0.phase = .starting }
        }
    }

    func send(_ event: InputEvent) {
        queue.async { [self] in
            guard let connection, peerHello != nil, videoActive else { return }
            // Bounded: if the link backs up, drop pointer moves first; never
            // drop button changes or releaseAll.
            if case .pointer(.move, _, _, _) = event, outstandingSends > 64 { return }
            guard send(stream: .input, payload: SessionCodec.encode(event), on: connection) else { return }
            switch event {
            case .key: keyEventsSent += 1
            case .pointer, .scroll, .gestureScroll, .magnify, .rotate: pointerEventsSent += 1
            case .releaseAll: break
            }
            publishCounters()
        }
    }

    func switchToWirelessSidecar() {
        queue.async { [self] in
            guard videoActive, config != nil, let connection, wirelessAttempt != nil,
                  peerHello?.supportsWirelessSidecar == true else { return }
            send(stream: .control, payload: SessionCodec.encode(.switchToWirelessSidecar), on: connection)
        }
    }

    func setWirelessEnabled(_ enabled: Bool) {
        queue.async { [self] in
            wirelessEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Self.wirelessEnabledKey)
            ui { $0.wirelessEnabled = enabled }
            if enabled {
                blockAutomaticReconnect = false
                wirelessRetryDelay = 1
                startWirelessDiscovery()
                scheduleWirelessReconnect()
            } else {
                stopWirelessDiscovery()
                if wirelessAttempt != nil {
                    endConnection(reason: "Wi-Fi disabled on the iPad", sendBye: true)
                }
            }
        }
    }

    func connectWireless(to id: String) {
        queue.async { [self] in
            guard connection == nil, foreground, wirelessEnabled,
                  let mac = wirelessMacs.first(where: { $0.id == id }),
                  let endpoint = wirelessEndpoints[id] else { return }
            wirelessRetry?.cancel()
            wirelessRetry = nil
            blockAutomaticReconnect = false
            wirelessRetryDelay = 1
            dialWireless(mac, endpoint: endpoint, pinnedIdentity: nil)
        }
    }

    private static func wirelessParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        #if !targetEnvironment(simulator)
        parameters.requiredInterfaceType = .wifi
        #endif
        return parameters
    }

    private func startWirelessDiscovery() {
        guard foreground, wirelessEnabled, browser == nil else { return }
        let created = NWBrowser(for: .bonjourWithTXTRecord(type: Self.bonjourType, domain: "local."),
                                using: Self.wirelessParameters())
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self, let created, self.browser === created else { return }
            self.wirelessDiscoveryChanged(state)
        }
        created.browseResultsChangedHandler = { [weak self, weak created] results, _ in
            guard let self, let created, self.browser === created else { return }
            self.updateWirelessResults(results)
        }
        browser = created
        ui { $0.wirelessStatus = "正在搜尋同一個 Wi-Fi 網路上的 Mac…" }
        created.start(queue: queue)
    }

    private func stopWirelessDiscovery() {
        wirelessRetry?.cancel()
        wirelessRetry = nil
        browser?.cancel()
        browser = nil
        wirelessEndpoints.removeAll()
        wirelessMacs.removeAll()
        ui {
            $0.wirelessMacs = []
            $0.wirelessStatus = nil
        }
    }

    private func wirelessDiscoveryChanged(_ state: NWBrowser.State) {
        ClientLog.write("Wi-Fi discovery: \(state)")
        switch state {
        case .ready:
            let waiting = wirelessPreference?.name
            ui { $0.wirelessStatus = waiting.map { "等待已配對的 Mac：\($0)" } ?? "選擇同一個 Wi-Fi 網路上的 Mac。" }
            scheduleWirelessReconnect()
        case .waiting:
            ui { $0.wirelessStatus = "請確認 Wi-Fi 已連線，且已允許此 App 取用區域網路。" }
        case .failed(let error):
            stopWirelessDiscovery()
            ui { $0.wirelessStatus = "無法搜尋 Mac：\(error)。請在控制面板重新啟用 Wi-Fi。" }
        default:
            break
        }
    }

    private func updateWirelessResults(_ results: Set<NWBrowser.Result>) {
        var endpoints: [String: NWEndpoint] = [:]
        var macs: [String: WirelessMac] = [:]
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            let id = "\(domain.lowercased())/\(name.precomposedStringWithCanonicalMapping.lowercased())"
            endpoints[id] = .service(name: name, type: type, domain: domain, interface: nil)
            let fingerprint: String?
            if case .bonjour(let record) = result.metadata, case .string(let value) = record.getEntry(for: "fp") {
                fingerprint = value
            } else {
                fingerprint = nil
            }
            macs[id] = WirelessMac(id: id, name: name, fingerprint: fingerprint)
        }
        wirelessEndpoints = endpoints
        let sortedMacs = macs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sortedMacs != wirelessMacs {
            ClientLog.write("Wi-Fi discovery found \(sortedMacs.count) compatible service(s)")
        }
        wirelessMacs = sortedMacs
        ui { $0.wirelessMacs = sortedMacs }
        scheduleWirelessReconnect()
    }

    private func preferredWirelessMac() -> (mac: WirelessMac, identity: [UInt8])? {
        let peers = trust.peers
        if let saved = wirelessPreference, let peer = peers.first(where: { $0.identityKey == saved.identity }) {
            if let previous = wirelessMacs.first(where: {
                $0.id == saved.serviceID && ($0.fingerprint == nil || $0.fingerprint == peer.fingerprint)
            }) {
                return (previous, peer.identityKey)
            }
            let renamed = wirelessMacs.filter { $0.fingerprint == peer.fingerprint }
            return renamed.count == 1 ? (renamed[0], peer.identityKey) : nil
        }
        let candidates = wirelessMacs.compactMap { mac in
            peers.first { $0.fingerprint == mac.fingerprint }.map { (mac, $0.identityKey) }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func scheduleWirelessReconnect() {
        guard foreground, wirelessEnabled, !blockAutomaticReconnect, connection == nil,
              wirelessRetry == nil, automaticWirelessTarget() != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wirelessRetry = nil
            guard self.foreground, self.wirelessEnabled, !self.blockAutomaticReconnect, self.connection == nil,
                  let target = self.automaticWirelessTarget() else { return }
            self.wirelessRetryDelay = min(self.wirelessRetryDelay * 2, 12)
            self.dialWireless(target.mac, endpoint: target.endpoint, pinnedIdentity: target.identity)
        }
        wirelessRetry = work
        queue.asyncAfter(deadline: .now() + wirelessRetryDelay, execute: work)
    }

    private func automaticWirelessTarget() -> (mac: WirelessMac, endpoint: NWEndpoint, identity: [UInt8])? {
        if let discovered = preferredWirelessMac(), let endpoint = wirelessEndpoints[discovered.mac.id] {
            return (discovered.mac, endpoint, discovered.identity)
        }
        guard let savedAddress = UserDefaults.standard.string(forKey: Self.wirelessAddressKey),
              let address = Self.privateWirelessAddress(savedAddress),
              let port = NWEndpoint.Port(rawValue: SessionConstants.wirelessPort) else { return nil }
        let peers = trust.peers
        let saved = wirelessPreference
        let peer = peers.first { $0.identityKey == saved?.identity } ?? (peers.count == 1 ? peers.first : nil)
        guard let peer else { return nil }
        let mac = WirelessMac(id: saved?.serviceID ?? "paired-ipv4", name: peer.name, fingerprint: peer.fingerprint)
        return (mac, .hostPort(host: .ipv4(address), port: port), peer.identityKey)
    }

    private func dialWireless(_ mac: WirelessMac, endpoint: NWEndpoint, pinnedIdentity: [UInt8]?) {
        if case .hostPort = endpoint { ClientLog.write("Wi-Fi dialing the address learned over USB") }
        accept(NWConnection(to: endpoint, using: Self.wirelessParameters()),
               wireless: WirelessAttempt(mac: mac, pinnedIdentity: pinnedIdentity))
    }

    // MARK: listener

    private func startListener() {
        guard let port = NWEndpoint.Port(rawValue: SessionConstants.clientPort) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port) // BUG-011
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        if let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            options.noDelay = true
        }
        do {
            let created = try NWListener(using: parameters)
            created.stateUpdateHandler = { [weak self, weak created] state in
                guard let self, let created else { return }
                self.listenerChanged(created, state)
            }
            created.newConnectionHandler = { [weak self, weak created] connection in
                guard let self, let created, self.listener === created else { return connection.cancel() }
                self.accept(connection)
            }
            listener = created
            created.start(queue: queue)
        } catch {
            ui { $0.phase = .failed("listener: \(error)") }
        }
    }

    private func listenerChanged(_ source: NWListener, _ state: NWListener.State) {
        guard listener === source else { return }
        ClientLog.write("listener \(state)")
        switch state {
        case .ready:
            if connection == nil { ui { $0.phase = .waitingForMac } }
        case .failed(let error):
            listener = nil
            source.cancel()
            if connection == nil, !wirelessEnabled { ui { $0.phase = .failed("listener: \(error)") } }
            // Retry while the app is in front.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.running, self.listener == nil else { return }
                self.startListener()
            }
        default:
            break
        }
    }

    private func accept(_ incoming: NWConnection, wireless: WirelessAttempt? = nil) {
        guard connection == nil else {
            ClientLog.write("incoming connection refused: a session is still open (one Mac at a time)")
            return incoming.cancel()
        }
        let transport = wireless == nil ? "USB-C" : "Wi-Fi"
        ClientLog.write("connection starting: \(transport)")
        let channel: SecureChannel
        do {
            channel = SecureChannel(role: .client, identity: try trust.identity())
        } catch {
            ClientLog.write("identity unavailable: \(error)")
            ui { $0.lastError = "Keychain: \(error)" }
            return incoming.cancel()
        }
        connection = incoming
        wirelessAttempt = wireless
        self.channel = channel
        pendingPeer = nil
        trustedPeer = nil
        pendingHostHello = nil
        parser = FrameParser()
        validator = nil
        peerHello = nil
        config = nil
        format = nil
        formatSets = []
        outstandingSends = 0
        clockOffset = nil
        offsetSamples = []
        transitSamples = []
        framesShown = 0
        framesDropped = 0
        keyEventsSent = 0
        pointerEventsSent = 0
        speakerPackets = 0
        speakerFramesReceived = 0
        speakerFormat = nil
        speakerBuffers.select(useWiFi: wireless != nil)
        speakerUnderrunsAtConnect = speakerSink.stats.underruns
        presentMeter = FrameRateMeter()
        countersPublished = 0
        publishCounters()
        var generator = SystemRandomNumberGenerator()
        framer = SessionFramer(sessionID: generator.next(), channel: channel,
                               clock: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
        lastHeard = Date()
        handshakeDeadline = Date().addingTimeInterval(12)
        let name = wireless?.mac.name ?? ""
        ui {
            $0.transport = transport
            $0.macName = name
            $0.lastError = nil
            $0.phase = .connecting
        }
        startWatchdog()
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            guard let self, let incoming, self.connection === incoming else { return }
            switch state {
            case .ready:
                // Handshake first (D-023); our hello follows once we trust the Mac.
                self.send(stream: .control, payload: channel.authHelloPayload, on: incoming)
                self.receive(on: incoming)
            case .failed(let error):
                self.endConnection(reason: "connection failed: \(error)", sendBye: false)
            case .cancelled:
                self.endConnection(reason: "connection closed", sendBye: false)
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.connection != nil else { return }
            if self.peerHello == nil {
                if Date() >= self.handshakeDeadline {
                    self.endConnection(reason: "connection or pairing timed out", sendBye: false)
                }
            } else if Date().timeIntervalSince(self.lastHeard) > 6 {
                self.endConnection(reason: "no traffic from Mac for 6 s", sendBye: false)
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func endConnection(reason: String, sendBye: Bool) {
        watchdog?.cancel()
        watchdog = nil
        guard let current = connection else { return }
        connection = nil
        wirelessAttempt = nil
        channel = nil
        pendingPeer = nil
        trustedPeer = nil
        pendingHostHello = nil
        current.stateUpdateHandler = nil
        if sendBye, peerHello != nil, let wire = try? framer.frame(.control, payload: SessionCodec.encode(.bye(reason))) {
            current.send(content: Data(wire), completion: .contentProcessed { _ in current.cancel() })
        } else {
            current.cancel()
        }
        renderer.flush(removingImage: true)
        renderer.selectHDR10(false)
        speakerSink.reset()
        let wasStreaming = config != nil
        config = nil
        let stillRunning = running // read on `queue`, not on the main actor
        ui {
            $0.streamConfig = nil
            $0.transport = nil
            $0.supportsWirelessSidecar = false
            $0.pairingCode = nil
            $0.lastError = reason
            if case .failed = $0.phase { return }
            $0.phase = stillRunning ? .waitingForMac : .starting
        }
        ClientLog.write("connection ended (streaming \(wasStreaming)): \(reason)")
        scheduleWirelessReconnect()
    }

    // MARK: receive

    private func receive(on current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === current else { return }
            if let error { return self.endConnection(reason: "receive: \(error)", sendBye: false) }
            if let data, !data.isEmpty {
                do {
                    try self.parser.append(data)
                    while let frame = try self.parser.next() {
                        if self.validator == nil {
                            guard frame.header.stream == .control else {
                                return self.endConnection(reason: "first frame was not control", sendBye: false)
                            }
                            self.validator = SequenceValidator(sessionID: frame.header.sessionID)
                        }
                        try self.validator?.accept(frame.header)
                        self.lastHeard = Date()
                        guard let channel = self.channel else { return }
                        switch try channel.receive(frame) {
                        case .none: break
                        case .sendProof(let proof): self.send(stream: .control, payload: proof, on: current)
                        case .verified(let peer): self.verified(peer, on: current)
                        case .message(let opened): try self.handle(opened, on: current)
                        }
                        guard self.connection === current else { return }
                    }
                } catch {
                    return self.endConnection(reason: "protocol error: \(error)", sendBye: false)
                }
            }
            if isComplete { return self.endConnection(reason: "Mac closed the connection", sendBye: false) }
            self.receive(on: current)
        }
    }

    /// The Mac proved its identity: pinned Macs connect at once; an unknown
    /// Mac waits for the user (the code is shown on both screens).
    private func verified(_ peer: SecureChannel.Peer, on current: NWConnection) {
        if let pin = wirelessAttempt?.pinnedIdentity, pin != peer.identityKey {
            blockAutomaticReconnect = true
            return endConnection(reason: "已配對 Mac 的身分已變更。請手動選擇並核對配對碼。", sendBye: false)
        }
        // Both ends can take time to compare the code, even when this iPad has
        // already paired and the Mac has since forgotten its copy.
        handshakeDeadline = Date().addingTimeInterval(wirelessAttempt == nil ? 120 : 125)
        if trust.isTrusted(peer.identityKey) {
            ClientLog.write("Mac authenticated: paired key \(peer.fingerprint)")
            return becomeTrusted(peer, on: current)
        }
        ClientLog.write("unknown Mac \(peer.fingerprint): asking the user (code \(peer.pairingCode))")
        pendingPeer = peer
        ui { $0.pairingCode = peer.pairingCode }
    }

    private func becomeTrusted(_ peer: SecureChannel.Peer, on current: NWConnection) {
        trustedPeer = peer
        send(stream: .control, payload: SessionCodec.encode(.hello(hello)), on: current)
        if let host = pendingHostHello {
            pendingHostHello = nil
            do { try acceptHostHello(host, on: current) } catch {
                endConnection(reason: "protocol error: \(error)", sendBye: false)
            }
        }
    }

    private func handle(_ frame: Frame, on current: NWConnection) throws {
        switch frame.header.stream {
        case .control:
            switch try SessionCodec.decodeControl(frame.payload) {
            case .hello(let host):
                guard peerHello == nil, pendingHostHello == nil, host.role == .host else {
                    throw WireError.invalidValue("unexpected hello")
                }
                guard trustedPeer != nil else {
                    pendingHostHello = host
                    ui { $0.macName = host.deviceName } // shown in the pairing prompt
                    return
                }
                try acceptHostHello(host, on: current)
            case .streamConfig(let streamConfig):
                guard peerHello != nil else { throw WireError.invalidValue("config before hello") }
                guard videoActive else { return } // late config from before a pause
                guard !streamConfig.hdr10 || hello.supportsHDR10 else { throw WireError.invalidValue("HDR10 was not negotiated") }
                // A new point size alone (the Mac's "looks like" changed) keeps
                // the decoder; a new codec or pixel size starts over.
                if config?.codec != streamConfig.codec || config?.pixelWidth != streamConfig.pixelWidth
                    || config?.pixelHeight != streamConfig.pixelHeight || config?.hdr10 != streamConfig.hdr10 {
                    format = nil
                }
                renderer.selectHDR10(streamConfig.hdr10)
                config = streamConfig
                ui {
                    $0.streamConfig = streamConfig
                    $0.phase = .streaming
                    $0.lastError = nil
                }
            case .ping(let value):
                send(stream: .control, payload: SessionCodec.encode(.pong(value)), on: current)
                let estimate = Int64(bitPattern: value) &- Int64(bitPattern: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                offsetSamples.append(estimate)
                if offsetSamples.count > 8 { offsetSamples.removeFirst() }
                clockOffset = offsetSamples.max()
            case .brightness(let value):
                if let apply = onBrightness { Task { @MainActor in apply(value) } }
            case .cursor(let x, let y, let visible):
                if let apply = onCursor { DispatchQueue.main.async { MainActor.assumeIsolated { apply(x, y, visible) } } }
            case .cursorImage(let image):
                if let apply = onCursorImage { DispatchQueue.main.async { MainActor.assumeIsolated { apply(image) } } }
            case .pong, .requestKeyframe, .audioRoute, .videoActive, .decodeFailed, .panelSize,
                    .switchToWirelessSidecar:
                break
            case .authHello, .authProof:
                throw WireError.invalidValue("handshake message after handshake")
            case .bye(let reason):
                endConnection(reason: "Mac: \(reason)", sendBye: false)
            }
        case .video:
            guard trustedPeer != nil else { throw WireError.invalidValue("video before pairing") }
            guard videoActive else { return } // frames in flight when video paused
            guard let config else {
                // A frame can overtake its config (start, resume, rotation):
                // drop it and ask for a keyframe instead of ending the session (D-042).
                requestKeyframe(on: current)
                return
            }
            present(AccessUnit(codec: config.codec == .hevc ? .hevc : .h264, annexB: frame.payload),
                    timestamp: frame.header.timestampNanos, on: current)
        case .speaker:
            guard trustedPeer != nil else { throw WireError.invalidValue("audio before pairing") }
            if Float32AudioPacket.isPayload(frame.payload) {
                guard hello.supportsFloat32Speaker else { throw WireError.invalidValue("unnegotiated Float32 PCM") }
                let packet = try Float32AudioPacket.decode(frame.payload, expectedChannels: SessionConstants.speakerChannels)
                speakerSink.push(packet)
                speakerFramesReceived += packet.frameCount
                speakerFormat = "48 kHz PCM Float32"
            } else {
                let packet = try AudioPacket.decode(frame.payload, expectedChannels: SessionConstants.speakerChannels)
                speakerSink.push(packet)
                speakerFramesReceived += packet.frameCount
                speakerFormat = "48 kHz PCM 16-bit"
            }
            speakerPackets += 1
            publishCounters()
            if speakerPackets == 1 || speakerPackets % 500 == 0 {
                ClientLog.write("speaker packets received \(speakerPackets), \(speakerFramesReceived) PCM frames, jitter \(speakerSink.stats)")
            }
        case .input, .microphone, .camera:
            throw WireError.invalidValue("unexpected \(frame.header.stream) stream from Mac")
        }
    }

    private func acceptHostHello(_ host: Hello, on current: NWConnection) throws {
        guard host.protocolVersion == SessionConstants.protocolVersion else {
            throw WireError.invalidValue("Mac protocol \(host.protocolVersion)")
        }
        peerHello = host
        let supportsWirelessSidecar = wirelessAttempt != nil && host.supportsWirelessSidecar
        ui {
            $0.macName = host.deviceName
            $0.supportsWirelessSidecar = supportsWirelessSidecar
        }
        // Tell the host what to start: audio directions, and whether
        // video is wanted right now.
        send(stream: .control, payload: SessionCodec.encode(.audioRoute(speaker: audioRoute.speaker,
                                                                         microphone: audioRoute.microphone)),
             on: current)
        if !videoActive {
            send(stream: .control, payload: SessionCodec.encode(.videoActive(false)), on: current)
        }
        if let reportedBrightness {
            send(stream: .control, payload: SessionCodec.encode(.brightness(reportedBrightness)), on: current)
        }
        if let peer = trustedPeer {
            trust.rename(peer.identityKey, to: host.deviceName)
            refreshPairedMacs()
            if let wirelessAttempt {
                let saved = WirelessPreference(serviceID: wirelessAttempt.mac.id, name: host.deviceName,
                                              identity: peer.identityKey)
                wirelessPreference = saved
                if let data = try? JSONEncoder().encode(saved) {
                    UserDefaults.standard.set(data, forKey: Self.wirelessPreferenceKey)
                }
                wirelessRetryDelay = 1
            }
        }
    }

    private func present(_ unit: AccessUnit, timestamp: UInt64, on current: NWConnection) {
        if unit.isKeyframe {
            let sets = unit.parameterSets
            if format == nil || sets != formatSets {
                do {
                    format = try SampleBuffers.formatDescription(for: unit)
                    formatSets = sets
                } catch {
                    format = nil
                    NSLog("WiredDisplay: bad keyframe: \(error)")
                    if decodeFailures.failed(at: ProcessInfo.processInfo.systemUptime) {
                        ClientLog.write("keyframes keep failing; asking the Mac for a simpler format")
                        send(stream: .control, payload: SessionCodec.encode(.decodeFailed), on: current)
                    }
                }
            }
        }
        if renderer.takeSwitch() {
            // Renderer switched (D-040): start the new path at a keyframe.
            renderer.flush(removingImage: false)
            format = nil
            if !unit.isKeyframe { requestKeyframe(on: current); return }
            format = try? SampleBuffers.formatDescription(for: unit)
        }
        if renderer.isFailed {
            // Repeated failures = this iPad cannot decode the format (D-031):
            // ask the Mac to step down (no 4:4:4, then 8-bit).
            ClientLog.write("renderer failed: \(renderer.failureDescription ?? "no error")")
            if decodeFailures.failed(at: ProcessInfo.processInfo.systemUptime) {
                ClientLog.write("decode keeps failing; asking the Mac for a simpler format")
                send(stream: .control, payload: SessionCodec.encode(.decodeFailed), on: current)
            }
        }
        if renderer.needsFlush {
            // The flag only clears after a flush; without one video froze for
            // good (review finding 4). Resume at the next keyframe.
            NSLog("WiredDisplay: renderer needs flush; flushing")
            renderer.flush(removingImage: false)
            if !unit.isKeyframe { format = nil }
        }
        // The decoder fell behind and frames were dropped (issue #1): resume
        // at a keyframe. If it keeps happening, this iPad cannot decode the
        // format fast enough; ask the Mac for a lighter one (no 4:4:4, then
        // 8-bit), as for a decode failure (D-031).
        let backlog = renderer.takeBacklogEvents()
        if backlog.keyframeWanted { requestKeyframe(on: current) }
        if backlog.stalls > 0 {
            ClientLog.write("decoder behind the stream (\(backlog.stalls) stall(s)); frames dropped until a keyframe")
            for _ in 0..<backlog.stalls where decodeFailures.failed(at: ProcessInfo.processInfo.systemUptime) {
                ClientLog.write("decoder keeps falling behind; asking the Mac for a lighter format")
                send(stream: .control, payload: SessionCodec.encode(.decodeFailed), on: current)
            }
        }
        guard let format else {
            requestKeyframe(on: current)
            countFrame(shown: false)
            return
        }
        if config?.hdr10 == true, unit.isKeyframe {
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
            let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
            let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
            guard transfer as? String == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
                  primaries as? String == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                  matrix as? String == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String else {
                ClientLog.write("HDR10 frame missing Rec.2020/PQ format")
                send(stream: .control, payload: SessionCodec.encode(.decodeFailed), on: current)
                formatSets = []
                self.format = nil
                return
            }
            ClientLog.write("verified HEVC keyframe Rec.2020/PQ")
        }
        do {
            let time = CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000)
            let sample = try SampleBuffers.sampleBuffer(for: unit, format: format, presentationTime: time)
            if timestamp % 30 == 0, let offset = clockOffset {
                let hostNow = Int64(bitPattern: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) &+ offset
                let transit = Double(hostNow &- Int64(bitPattern: timestamp)) / 1e6
                CMSetAttachment(sample, key: "WiredDisplayTransitMS" as CFString,
                                value: NSNumber(value: transit), attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
            }
            renderer.enqueue(sample)
            countFrame(shown: true)
            if let offset = clockOffset {
                // Mac sent it -> iPad hands it to the display layer (transport,
                // decryption, parsing); excludes encode and the final vsync.
                let local = Int64(bitPattern: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) &+ offset
                transitSamples.append(Double(local &- Int64(bitPattern: timestamp)) / 1_000_000)
            }
            if let report = presentMeter.tick(bytes: unit.annexB.count) {
                var line = "video submitted to renderer: \(report)"
                if !transitSamples.isEmpty {
                    let sorted = transitSamples.sorted()
                    line += String(format: ", sent->enqueued p50 %.1f p95 %.1f ms", sorted[sorted.count / 2], sorted[sorted.count * 95 / 100])
                    transitSamples.removeAll(keepingCapacity: true)
                }
                ClientLog.write(line)
            }
        } catch {
            requestKeyframe(on: current)
            countFrame(shown: false)
        }
    }

    /// Frame counters for the Controls panel, published at most once a
    /// second instead of one main-actor hop per video frame (audit B-11).
    private var framesShown = 0, framesDropped = 0
    private var countersPublished: TimeInterval = 0

    private func countFrame(shown: Bool) {
        if shown { framesShown += 1 } else { framesDropped += 1 }
        publishCounters()
    }

    private func publishCounters() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - countersPublished >= 1 else { return }
        countersPublished = now
        let (shownTotal, droppedTotal) = (framesShown, framesDropped)
        let (keys, pointers, audioFrames) = (keyEventsSent, pointerEventsSent, speakerFramesReceived)
        let stats = speakerSink.stats
        let underruns = stats.underruns - speakerUnderrunsAtConnect
        let format = speakerFormat
        ui {
            $0.framesShown = shownTotal
            $0.framesDropped = droppedTotal
            $0.keyEventsSent = keys
            $0.pointerEventsSent = pointers
            $0.speakerFramesReceived = audioFrames
            $0.speakerUnderruns = underruns
            $0.speakerFormat = format
        }
    }

    private func requestKeyframe(on current: NWConnection) {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = Date()
        send(stream: .control, payload: SessionCodec.encode(.requestKeyframe), on: current)
    }

    @discardableResult
    private func send(stream: StreamType, payload: [UInt8], on current: NWConnection) -> Bool {
        guard let wire = try? framer.frame(stream, payload: payload) else { return false }
        outstandingSends += 1
        current.send(content: Data(wire), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                // Completions from an old connection must not touch the new one
                // (review finding 10).
                guard self.connection === current else { return }
                self.outstandingSends -= 1
                if let error { self.endConnection(reason: "send: \(error)", sendBye: false) }
            }
        })
        return true
    }

    private func ui(_ update: @escaping @MainActor (ConnectionModel) -> Void) {
        let model = model
        Task { @MainActor in update(model) }
    }
}
