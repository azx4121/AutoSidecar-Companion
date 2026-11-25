import AVFoundation
import Foundation
import os
import WDSession

final class SpeakerBuffers: Sendable {
    private let wired = AudioJitterBuffer(channels: Int(SessionConstants.speakerChannels),
                                          targetFrames: 1_440, maxFrames: 4_800)
    // The observed Wi-Fi bursts can be about 100 ms apart.
    private let wireless = AudioJitterBuffer(channels: Int(SessionConstants.speakerChannels),
                                             targetFrames: 5_760, maxFrames: 11_520)
    private let route = OSAllocatedUnfairLock(initialState: (usesWiFi: false, mono: false))

    var active: AudioJitterBuffer { route.withLock { $0.usesWiFi ? wireless : wired } }

    func select(useWiFi: Bool) {
        (useWiFi ? wireless : wired).reset()
        route.withLock { $0.usesWiFi = useWiFi }
    }

    func setOutputChannels(_ channels: Int) {
        route.withLock { $0.mono = channels == 1 }
    }

    func render(_ left: UnsafeMutablePointer<Float>?, _ right: UnsafeMutablePointer<Float>?, frames: Int) {
        let state = route.withLock { $0 }
        (state.usesWiFi ? wireless : wired).pull(left, right, frames: frames)
        // Our source always renders stereo. A mono hardware route can otherwise select only the left input.
        guard state.mono, let left, let right else { return }
        for frame in 0..<frames {
            let mixed = left[frame] * 0.5 + right[frame] * 0.5
            left[frame] = mixed
            right[frame] = mixed
        }
    }
}

/// iPad audio (D-017, D-018):
/// - speaker: Mac audio packets -> jitter buffer -> AVAudioEngine -> iPad speaker
/// - microphone (off by default): iPad mic -> voice processing (echo
///   cancellation) -> 48 kHz mono PCM packets -> Mac "iPad Microphone"
///
/// Main-actor confined except the jitter buffer (thread-safe) and the tap /
/// render blocks, which only touch the buffer, a converter and `onMicrophone`.
@MainActor
final class ClientAudio {
    let speakerBuffer = SpeakerBuffers()
    private(set) var speakerOn = false
    private(set) var microphoneOn = false
    private var engine: AVAudioEngine?
    private var interruptionObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var restartWork: DispatchWorkItem?
    private var formatRetries = 0
    private var recentRestarts: [Date] = []
    /// Reports the directions that are really running (after failures too), so
    /// the Mac is never told "microphone on" while nothing is captured.
    var onStateChange: ((_ speaker: Bool, _ microphone: Bool) -> Void)?
    var onOutputRouteChange: ((String?) -> Void)?
    private var currentOutputDescription: String?

    private func reportOutput(_ description: String?) {
        guard currentOutputDescription != description else { return }
        currentOutputDescription = description
        onOutputRouteChange?(description)
    }

    private func reportCurrentOutput() {
        let session = AVAudioSession.sharedInstance()
        speakerBuffer.setOutputChannels(session.outputNumberOfChannels)
        let ports = session.currentRoute.outputs
        guard speakerOn, engine?.isRunning == true, !ports.isEmpty,
              session.sampleRate > 0, session.outputNumberOfChannels > 0 else {
            reportOutput(nil)
            return
        }
        let names = ports.map { $0.portType == .builtInSpeaker ? "內建喇叭" : $0.portName }
        reportOutput("\(names.joined(separator: "、")) · \(Int(session.sampleRate.rounded())) Hz · \(session.outputNumberOfChannels) 聲道")
    }

    private func scheduleRestart(after delay: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restartWork = nil
                self.apply(speaker: self.speakerOn, microphone: self.microphoneOn, isRetry: true)
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private struct InputNotReady: Error {}
    var onMicrophone: (@Sendable (AudioPacket) -> Void)?
    var onError: ((String) -> Void)?

    var isActive: Bool { speakerOn || microphoneOn }

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            ClientLog.write("audio interruption type=\(typeValue.map(String.init) ?? "?") reason=\(reason.map(String.init) ?? "-")")
            MainActor.assumeIsolated {
                guard let self, self.isActive,
                      typeValue == AVAudioSession.InterruptionType.ended.rawValue else { return }
                // Phone call, Siri, another app's audio ended: resume.
                self.apply(speaker: self.speakerOn, microphone: self.microphoneOn)
            }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportCurrentOutput() }
            }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, let engine = self.engine else { return }
                // Enabling voice processing fires this for our own change. If the
                // engine is still running there is nothing to do. If it STOPPED,
                // restart it after the route settles — ignoring that case left
                // speaker and microphone dead (BUG-029). Restarting immediately
                // read a 0 Hz input format and crashed (BUG-026), hence the delay.
                if engine.isRunning {
                    self.reportCurrentOutput()
                    ClientLog.write("audio configuration change: engine still running, ignored")
                    return
                }
                self.reportOutput(nil)
                let now = Date()
                self.recentRestarts = self.recentRestarts.filter { now.timeIntervalSince($0) < 30 } + [now]
                guard self.recentRestarts.count <= 8 else {
                    ClientLog.write("audio configuration changes: too many restarts, giving up")
                    self.fail("audio keeps restarting; toggle it off and on")
                    return
                }
                // Voice processing stops the engine once right after it engages.
                // Building a NEW engine re-engages it and stops again ~120 ms later,
                // forever (BUG-030, seen in client.log). Restart the SAME engine,
                // keeping its graph and microphone tap; rebuild only if that fails.
                ClientLog.write("audio configuration change stopped the engine; resuming the same engine")
                self.resume(engine)
            }
        }
    }

    /// (Re)builds the audio engine for the requested directions. The
    /// microphone is only started after the user granted permission.
    func apply(speaker: Bool, microphone: Bool, isRetry: Bool = false) {
        if !isRetry { formatRetries = 0 }
        restartWork?.cancel()
        restartWork = nil
        teardown()
        speakerOn = speaker
        microphoneOn = microphone
        guard speaker || microphone else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            if microphone {
                // Video-chat mode: echo cancellation (the iPad speaker is next to
                // its microphones) + gain control. Only while the mic is on;
                // otherwise plain .playback keeps full speaker quality.
                try session.setCategory(.playAndRecord, mode: .videoChat,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            // These are requests. Some routes only support a different clock or buffer size.
            do { try session.setPreferredSampleRate(SessionConstants.audioSampleRate) }
            catch { ClientLog.write("audio: using the route's sample rate (\(error))") }
            do { try session.setPreferredIOBufferDuration(0.005) }
            catch { ClientLog.write("audio: using the route's buffer duration (\(error))") }
            try session.setActive(true)
            speakerBuffer.setOutputChannels(session.outputNumberOfChannels)

            let engine = AVAudioEngine()
            if microphone {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                try installMicrophoneSink(on: engine)
            }
            if speaker {
                speakerBuffer.active.reset()
                let source = Self.makeSpeakerSource(buffer: speakerBuffer)
                engine.attach(source)
                engine.connect(source, to: engine.mainMixerNode,
                               format: AVAudioFormat(standardFormatWithSampleRate: SessionConstants.audioSampleRate,
                                                     channels: 2))
            } else {
                // Voice processing needs the output side running; keep it silent.
                engine.mainMixerNode.outputVolume = 0
                _ = engine.mainMixerNode
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            reportCurrentOutput()
            formatRetries = 0
            ClientLog.write("audio started (speaker \(speaker), microphone \(microphone)), session " +
                            "\(session.category.rawValue)/\(session.mode.rawValue) \(session.sampleRate) Hz, " +
                            "route \(session.currentRoute.outputs.map(\.portName)) <- \(session.currentRoute.inputs.map(\.portName))")
            onStateChange?(speaker, microphone)
        } catch is InputNotReady where formatRetries < 6 {
            // Route still settling (0 Hz input): try again shortly, never crash.
            formatRetries += 1
            ClientLog.write("microphone input not ready; retry \(formatRetries)/6")
            teardown()
            scheduleRestart(after: 0.3 * Double(formatRetries))
        } catch {
            ClientLog.write("audio failed (speaker \(speaker), microphone \(microphone)): \(error)")
            if microphone && speaker {
                apply(speaker: true, microphone: false)
                if speakerOn { onError?(uiText("The iPad microphone could not start. Mac audio will continue playing.")) }
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    private func resume(_ engine: AVAudioEngine, attempt: Int = 1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(attempt)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.engine === engine, !engine.isRunning else { return }
                do {
                    engine.prepare()
                    try engine.start()
                    self.reportCurrentOutput()
                    ClientLog.write("audio engine resumed after configuration change (attempt \(attempt)), " +
                                    "output \(engine.outputNode.outputFormat(forBus: 0))")
                } catch where attempt < 4 {
                    ClientLog.write("audio resume attempt \(attempt) failed: \(error)")
                    self.resume(engine, attempt: attempt + 1)
                } catch {
                    ClientLog.write("audio resume failed: \(error); rebuilding")
                    self.scheduleRestart(after: 0.5)
                }
            }
        }
    }

    private func fail(_ reason: String) {
        teardown()
        speakerOn = false
        microphoneOn = false
        onError?(uiText("Audio: %@", reason))
        onStateChange?(false, false)
    }

    func stop() {
        apply(speaker: false, microphone: false)
    }

    private func teardown() {
        reportOutput(nil)
        guard let engine else { return }
        engine.stop()
        self.engine = nil
    }

    private func installMicrophoneSink(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // A tap on an invalid format raises an Objective-C exception (BUG-026).
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw InputNotReady() }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SessionConstants.audioSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "WiredDisplay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unsupported microphone format \(inputFormat)"])
        }
        let box = ConverterBox(converter: converter, target: target)
        ClientLog.write("microphone sink format \(inputFormat), IO buffer \(AVAudioSession.sharedInstance().ioBufferDuration * 1000) ms")
        // A sink node receives every IO cycle (~5 ms) instead of the ~50 ms
        // chunks a tap delivered (step 2).
        let sink = AVAudioSinkNode(receiverBlock: Self.makeMicrophoneSink(format: inputFormat, box: box, send: onMicrophone))
        engine.attach(sink)
        engine.connect(input, to: sink, format: inputFormat)
    }

    /// Built outside the main actor: AVAudioEngine calls it on its real-time
    /// thread, and a main-actor-isolated closure there traps under Swift 6
    /// (BUG-031).
    private nonisolated static func makeMicrophoneSink(format: AVAudioFormat, box: ConverterBox,
                                                       send: (@Sendable (AudioPacket) -> Void)?) -> AVAudioSinkNodeReceiverBlock {
        return { _, frameCount, bufferList -> OSStatus in
            guard let send, frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil)
            else { return noErr }
            buffer.frameLength = frameCount
            guard let packets = box.convert(buffer) else { return noErr }
            for packet in packets { send(packet) }
            box.sentPackets += packets.count
            if box.sentPackets == packets.count || box.sentPackets % 1000 < packets.count {
                let peak = packets.last?.samples.map { abs(Int($0)) }.max() ?? 0
                ClientLog.write("microphone packets captured \(box.sentPackets), last peak \(peak), frames/packet \(packets.last?.frameCount ?? 0)")
            }
            return noErr
        }
    }

    /// Converter state used only on the tap's thread.
    private final class ConverterBox: @unchecked Sendable {
        let converter: AVAudioConverter
        let target: AVAudioFormat
        var sentPackets = 0

        init(converter: AVAudioConverter, target: AVAudioFormat) {
            self.converter = converter
            self.target = target
        }

        func convert(_ buffer: AVAudioPCMBuffer) -> [AudioPacket]? {
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = output.floatChannelData, output.frameLength > 0 else { return nil }
            var packets: [AudioPacket] = []
            var offset = 0
            let frames = Int(output.frameLength)
            while offset < frames {
                let count = min(frames - offset, SessionConstants.maxAudioFramesPerPacket)
                packets.append(AudioPacket(channels: SessionConstants.microphoneChannels,
                                           samples: PCM.interleave([UnsafePointer(data[0] + offset)], frames: count)))
                offset += count
            }
            return packets
        }
    }

    private nonisolated static func makeSpeakerSource(buffer: SpeakerBuffers) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: SessionConstants.audioSampleRate, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            // No array here: render callbacks must not allocate (audit C-5).
            let first = list.count > 0 ? list[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let second = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
            buffer.render(first, second, frames: Int(frameCount))
            return noErr
        }
    }

    /// Asks for microphone permission (first time shows the system prompt).
    static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
