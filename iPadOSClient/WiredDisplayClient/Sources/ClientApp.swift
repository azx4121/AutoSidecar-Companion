import AVFoundation
import SwiftUI
import UIKit
import VideoToolbox
import WDSession

/// Owns the long-lived objects. Created once; the session is built on first
/// activation because the screen's size is only reliable once a scene exists.
@MainActor
final class AppModel {
    let connection = ConnectionModel()
    let videoView = VideoView(frame: .zero)
    let audio = ClientAudio()
    private(set) var session: ClientSession?
    private var sink: SwitchableSink?
    /// Experimental Metal renderer (D-040), remembered.
    func setMetalRenderer(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: VideoView.metalRendererKey)
        let usable = on && videoView.metalRenderer != nil
        videoView.usesMetal = usable
        sink?.select(metal: usable)
        ClientLog.write("renderer: \(usable ? "Metal (experimental)" : "system display layer")")
    }
    /// Diagnostics: the E-05 loopback echo on 127.0.0.1:9000, so cable
    /// throughput can be measured with `wd-usbmux-probe echo` without swapping
    /// apps (free teams cannot register more App IDs). Foreground only.
    private let echoLog = EventLog()
    private lazy var echo = EchoServer(events: echoLog)
    /// Off unless asked for (audit C-7): launch with `-diagnosticEcho YES`
    /// (e.g. `xcrun devicectl device process launch … -- -diagnosticEcho YES`).
    private var echoEnabled: Bool { UserDefaults.standard.bool(forKey: "diagnosticEcho") }

    private var foregroundRequested = false
    private var nextWirelessPreference: Bool?

    init() {
        videoView.onPanelChange = { [weak self] in self?.schedulePanelUpdate() }
    }

    func activate(wirelessEnabled: Bool? = nil) {
        foregroundRequested = true
        if let wirelessEnabled { nextWirelessPreference = wirelessEnabled }
        guard let hello = makeHello() else {
            session?.setVideoActive(false)
            if videoView.window != nil {
                connection.lastError = "請將接收器開在 iPad 內建螢幕，等候讀取顯示資訊。"
            }
            return
        }
        if session == nil {
            let sink = SwitchableSink(standard: DisplayLayerSink(videoView.displayLayer.sampleBufferRenderer),
                                      metal: videoView.metalRenderer)
            self.sink = sink
            // Metal is the default since the user found it better (D-040).
            setMetalRenderer(UserDefaults.standard.object(forKey: VideoView.metalRendererKey) as? Bool ?? true)
            let nativeBounds = screen?.nativeBounds.size
            ClientLog.write("panel \(Self.modelIdentifier()): negotiated \(hello.pixelWidth)x\(hello.pixelHeight) @\(hello.scale)x, UIKit native bounds \(String(describing: nativeBounds))")
            let session = ClientSession(model: connection, renderer: sink,
                                        hello: hello, speakerSink: audio.speakerBuffer)
            videoView.onInput = { [weak session] event in session?.send(event) }
            audio.onMicrophone = { [weak session] packet in session?.sendMicrophone(packet) }
            audio.onError = { [weak self] message in self?.connection.lastError = message }
            audio.onOutputRouteChange = { [weak self] description in self?.connection.outputRoute = description }
            audio.onStateChange = { [weak self, weak session] speaker, microphone in
                guard let self else { return }
                connection.speakerOn = speaker
                connection.microphoneOn = microphone
                session?.setAudioRoute(speaker: speaker, microphone: microphone)
            }
            session.onBrightness = { [weak self] value in self?.applyBrightness(value) }
            session.onCursor = { [weak self] x, y, visible in self?.videoView.setCursor(x: x, y: y, visible: visible) }
            session.onCursorImage = { [weak self] image in
                self?.videoView.setCursorImage(png: image.png, width: image.width, height: image.height,
                                               hotX: image.hotX, hotY: image.hotY)
            }
            NotificationCenter.default.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportBrightness() }
            }
            let changes: [Notification.Name] = [
                .NSProcessInfoPowerStateDidChange, AVPlayer.eligibleForHDRPlaybackDidChangeNotification,
                UIScreen.modeDidChangeNotification, UIScreen.referenceDisplayModeStatusDidChangeNotification
            ]
            for change in changes {
                NotificationCenter.default.addObserver(forName: change, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.schedulePanelUpdate() }
                }
            }
            self.session = session
            // Mac audio on the iPad speaker is on by default; the microphone is not.
            setAudio(speaker: true, microphone: false)
        } else {
            session?.updateDisplayProfile(hello)
        }
        if let nextWirelessPreference {
            session?.setWirelessEnabled(nextWirelessPreference)
            self.nextWirelessPreference = nil
        }
        session?.setVideoActive(true)
        reportBrightness()
        session?.start()
        if echoEnabled { echo.start() }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func reconnect() {
        session?.stop(reason: "user reconnect")
        activate()
    }

    /// Leaving the foreground: with audio running, keep the session and pause
    /// video (D-018); otherwise end the session as before.
    func deactivate(reason: String) {
        foregroundRequested = false
        panelUpdate?.cancel()
        ClientLog.write("app leaving foreground: \(reason) (audio active \(audio.isActive))")
        if echoEnabled { echo.stop(reason: "app not active") }
        session?.send(.releaseAll)
        if audio.isActive {
            session?.setVideoActive(false)
        } else {
            session?.stop(reason: reason)
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: brightness (D-033)

    private var displayScene: UIWindowScene? {
        guard let scene = videoView.window?.windowScene,
              scene.screen === UIScreen.main else { return nil }
        return scene
    }
    private var screen: UIScreen? { displayScene?.screen }
    /// The last value the Mac set, so applying it is not reported back as a
    /// user change (that echo made quick key presses jump back).
    private var appliedBrightness: Float?
    private var hudToken = 0

    private func applyBrightness(_ value: Float) {
        guard let screen else { return }
        appliedBrightness = value
        screen.brightness = CGFloat(value)
        hudToken += 1
        let token = hudToken
        connection.brightnessHUD = (value, token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, connection.brightnessHUD?.token == token else { return }
            connection.brightnessHUD = nil
        }
    }

    private func reportBrightness() {
        guard let screen else { return }
        let value = Float(screen.brightness)
        if let applied = appliedBrightness, abs(applied - value) < 0.01 { return }
        appliedBrightness = nil
        session?.sendBrightness(min(max(value, 0), 1))
    }

    func setAudio(speaker: Bool, microphone: Bool) {
        connection.speakerOn = speaker
        connection.microphoneOn = microphone
        // The route is sent from onStateChange once audio really runs (or fails).
        audio.apply(speaker: speaker, microphone: microphone)
        if !speaker && !microphone { session?.setAudioRoute(speaker: false, microphone: false) }
    }

    func setMicrophone(_ enabled: Bool) {
        guard enabled else { return setAudio(speaker: audio.speakerOn, microphone: false) }
        Task { @MainActor in
            if await ClientAudio.requestMicrophonePermission() {
                setAudio(speaker: audio.speakerOn, microphone: true)
            } else {
                connection.lastError = "麥克風權限尚未開啟。請至「設定」的「隱私權與安全性」中檢查麥克風權限。"
                connection.microphoneOn = false
            }
        }
    }

    /// For the controls panel: what this iPad tells the Mac.
    var deviceInfo: DeviceInfo? {
        guard let hello = makeHello() else { return nil }
        return DeviceInfo(model: Self.modelIdentifier(), panel: "\(hello.pixelWidth) × \(hello.pixelHeight) px",
                          pixelsPerInch: Int(hello.pixelsPerInch), maxRefreshHz: Int(hello.maxRefreshHz),
                          hevcHardware: hello.codecs.contains(VideoCodec.hevc), supportsHDR10: hello.supportsHDR10,
                          wideGamut: videoView.traitCollection.displayGamut == .P3)
    }

    private func makeHello() -> Hello? {
        guard let scene = videoView.window?.windowScene else { return nil }
        let screen = scene.screen
        let orientation = scene.effectiveGeometry.interfaceOrientation
        let portrait = orientation == .unknown ? screen.bounds.height > screen.bounds.width : orientation.isPortrait
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        guard let panel = ReceiverPanel(model: Self.modelIdentifier(), builtIn: screen === UIScreen.main,
                                       nativeSize: screen.nativeBounds.size, displayScale: screen.scale,
                                       portrait: portrait, maximumFPS: screen.maximumFramesPerSecond,
                                       lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, hevc: hevc,
                                       hdrPlayback: AVPlayer.eligibleForHDRPlayback, headroom: screen.potentialEDRHeadroom)
        else { return nil }
        return Hello(role: .client, deviceName: UIDevice.current.name,
                     pixelWidth: panel.width, pixelHeight: panel.height, scale: panel.scale,
                     maxRefreshHz: panel.maxRefreshHz, codecs: hevc ? [.h264, .hevc] : [.h264],
                     pixelsPerInch: Self.pixelsPerInch(), supportsFloat32Speaker: true,
                     supportsHDR10: panel.supportsHDR10)
    }

    static func builtInPanelSize(on screen: UIScreen) -> CGSize? {
        guard screen === UIScreen.main,
              let corrected = ReceiverPanel.zoomCorrection(for: modelIdentifier()) else { return nil }
        let bounds = screen.bounds.size
        return bounds.width >= bounds.height ? corrected : CGSize(width: corrected.height, height: corrected.width)
    }

    private var panelUpdate: DispatchWorkItem?

    private func schedulePanelUpdate() {
        panelUpdate?.cancel()
        guard foregroundRequested else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.foregroundRequested else { return }
                self.activate()
            }
        }
        panelUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Hardware model identifier, e.g. "iPad14,10".
    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func pixelsPerInch() -> UInt16 {
        let model = modelIdentifier()
        // mini 5 (iPad11,1/2), mini 6 (iPad14,1/2), mini A17 Pro (iPad16,1/2).
        let minis: Set<String> = ["iPad11,1", "iPad11,2", "iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2"]
        if minis.contains(model) { return 326 }
        return ReceiverPanel.zoomCorrection(for: model) == nil ? 0 : 264
    }
}

@main
struct WiredDisplayClientApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(app: app, connection: app.connection,
                     openWiFi: { app.activate(wirelessEnabled: true) },
                     openUSB: { app.activate(wirelessEnabled: false) })
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: app.activate()
                    case .background: app.deactivate(reason: "iPad app moved to background")
                    default: break
                    }
                }
                .onOpenURL { url in
                    switch url.absoluteString.lowercased() {
                    case "autosidecar-companion://usb": app.activate(wirelessEnabled: false)
                    case "autosidecar-companion://connect": app.activate(wirelessEnabled: true)
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    let app: AppModel
    let connection: ConnectionModel
    let openWiFi: () -> Void
    let openUSB: () -> Void
    @State private var showControls = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoSurface(view: app.videoView, streamConfig: connection.streamConfig)
                .ignoresSafeArea()

            Group {
                if let code = connection.pairingCode {
                    ZStack {
                        Backdrop()
                        PairingScreen(macName: connection.macName, code: code) { accept in
                            app.session?.answerPairing(code: code, accept: accept)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if connection.phase != .streaming {
                    ZStack {
                        Backdrop()
                        StatusScreen(info: statusInfo, enableWireless: openWiFi,
                                     enableWired: openUSB,
                                     selectWirelessMac: { app.session?.connectWireless(to: $0) })
                    }
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.35), value: connection.pairingCode)
            .animation(.smooth(duration: 0.35), value: connection.phase)
            .animation(.easeOut(duration: 0.2), value: connection.brightnessHUD?.token)

            if let hud = connection.brightnessHUD {
                BrightnessHUD(value: hud.value)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 28)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                if connection.supportsWirelessSidecar, connection.phase == .streaming {
                    Button {
                        app.session?.switchToWirelessSidecar()
                    } label: {
                        Label("無線並行 60 Hz", systemImage: "hand.tap")
                            .font(.callout.weight(.semibold))
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("以手指或巧控鍵盤操作 Mac。聲音會回到 Mac 的輸出。")
                }
                ControlsButton(streaming: connection.phase == .streaming) { showControls.toggle() }
                    .popover(isPresented: $showControls) {
                        ControlsPanel(app: app, connection: connection)
                    }
            }
        }
        .background(.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(.dark)
    }

    private var statusInfo: StatusInfo {
        let stage: StatusInfo.Stage
        switch connection.phase {
        case .starting, .streaming: stage = .starting
        case .waitingForMac: stage = .waitingForMac
        case .connecting: stage = .connecting
        case .failed(let reason): stage = .failed(reason)
        }
        return StatusInfo(stage: stage, macName: connection.macName, lastError: connection.lastError,
                          wirelessEnabled: connection.wirelessEnabled, wirelessStatus: connection.wirelessStatus,
                          wirelessMacs: connection.wirelessMacs)
    }
}

/// Bridges the UIKit video view and keeps its stream size in sync.
struct VideoSurface: UIViewRepresentable {
    let view: VideoView
    let streamConfig: StreamConfig?

    func makeUIView(context: Context) -> VideoView { view }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.displaysHDR10 = streamConfig?.hdr10 ?? false
        uiView.streamSize = streamConfig.map { CGSize(width: Int($0.pointWidth), height: Int($0.pointHeight)) }
        uiView.streamRefreshHz = streamConfig.map { Int($0.refreshHz) } ?? 0
        uiView.metalRenderer?.setStreamGeometry(streamConfig)
    }
}

/// Binds the controls panel to the live session.
struct ControlsPanel: View {
    let app: AppModel
    let connection: ConnectionModel
    /// BUG-035: on = video composited by the GPU (dithered) instead of a
    /// hardware overlay plane, which showed rings in smooth gradients.
    @AppStorage(VideoView.smoothGradientsKey) private var smoothGradients = true
    @AppStorage(VideoView.metalRendererKey) private var metalRenderer = true

    var body: some View {
        ControlsContent(
            summary: summary,
            wirelessEnabled: Binding(get: { connection.wirelessEnabled },
                                     set: { app.session?.setWirelessEnabled($0) }),
            speaker: Binding(get: { connection.speakerOn },
                             set: { app.setAudio(speaker: $0, microphone: connection.microphoneOn) }),
            microphone: Binding(get: { connection.microphoneOn }, set: { app.setMicrophone($0) }),
            smoothGradients: Binding(get: { smoothGradients },
                                     set: { smoothGradients = $0; app.videoView.smoothGradients = $0 }),
            metalRenderer: app.videoView.metalRenderer == nil ? nil
                : Binding(get: { metalRenderer }, set: { metalRenderer = $0; app.setMetalRenderer($0) }),
            pairedMacs: connection.pairedMacs.map { PairedMacRow(name: $0.name, fingerprint: $0.fingerprint) },
            forgetPaired: { app.session?.forgetPairedMacs() },
            reconnect: app.reconnect,
            device: app.deviceInfo)
    }

    private var summary: SessionSummary {
        let config = connection.streamConfig
        return SessionSummary(
            macName: connection.macName,
            streaming: connection.phase == .streaming,
            logicalSize: config.map { "\($0.pointWidth) × \($0.pointHeight)" },
            detail: config.map { "\($0.pixelWidth) × \($0.pixelHeight) px · 目標 \($0.refreshHz) FPS · \($0.hdr10 ? "HDR10" : "SDR") · \($0.codec == .hevc ? "HEVC" : "H.264")" },
            framesShown: connection.framesShown,
            framesDropped: connection.framesDropped,
            transport: connection.transport,
            keyEventsSent: connection.keyEventsSent,
            pointerEventsSent: connection.pointerEventsSent,
            speakerFramesReceived: connection.speakerFramesReceived,
            speakerUnderruns: connection.speakerUnderruns,
            speakerFormat: connection.speakerFormat,
            outputRoute: connection.outputRoute)
    }
}
