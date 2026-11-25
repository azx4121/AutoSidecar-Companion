import AVFoundation
import Foundation
import os
import WDMacAudio
import WDSession

/// Bridges the WiredDisplayAudio loopback devices and the session (D-017):
/// - speaker: record "iPad Speaker Tap" (what Mac apps play into "iPad Speaker") via a CoreAudio IOProc
///   -> one PCM packet per ~5 ms IO cycle -> iPad
/// - microphone: iPad PCM packets -> jitter buffer -> play into "iPad Microphone Feed",
///   which apps record as "iPad Microphone" (D-032)
///
/// Each direction starts and stops alone.
/// Recording the loopback input needs the Microphone permission (TCC) for this
/// app. Methods are called from the session queue; render/tap callbacks run on
/// CoreAudio threads and only touch the jitter buffer and `send`.
final class HostAudioBridge: @unchecked Sendable {
    private var microphoneEngine: AVAudioEngine?
    // 30 ms target / 100 ms cap: the iPad now sends a packet every IO cycle.
    private let microphoneBuffer = AudioJitterBuffer(channels: Int(SessionConstants.microphoneChannels),
                                                     targetFrames: 1440, maxFrames: 4800)
    private let send: @Sendable ([UInt8]) -> Void
    /// Diagnostics: packets each way, logged periodically.
    private let counters = OSAllocatedUnfairLock(initialState: (sent: 0, received: 0, receivedFrames: 0))

    init(send: @escaping @Sendable ([UInt8]) -> Void) {
        let counters = counters
        self.send = { payload in
            send(payload)
            let sent = counters.withLock { $0.sent += 1; return $0.sent }
            if sent == 1 || sent % 5000 == 0 { Log.info("audio: speaker packets sent to iPad: \(sent)") }
        }
    }

    deinit { stopAll() }

    var isSpeakerRunning: Bool { speakerProc != nil }
    var isMicrophoneRunning: Bool { microphoneEngine != nil }

    // MARK: speaker (Mac -> iPad)

    /// IO buffer requested from CoreAudio for both bridges: 240 frames = 5 ms.
    /// Replaces AVAudioEngine taps, which delivered ~100 ms chunks (step 2).
    static let ioBufferFrames: UInt32 = 240

    private var speakerDevice: AudioDeviceID = 0
    private var speakerOutputDevice: AudioDeviceID = 0
    private var speakerProc: AudioDeviceIOProcID?
    private var speakerFifo: SpeakerFifo?

    @discardableResult
    func startSpeaker(float32: Bool, preferBlackHole: Bool = false) throws -> AudioDeviceID {
        guard speakerProc == nil else { return speakerOutputDevice }
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if preferBlackHole, authorization != .authorized {
            throw AudioDevices.Error.coreAudio("Microphone permission is required for the LAN speaker", kAudioDevicePermissionsError)
        }
        let loopback = try AudioDevices.speakerLoopback(preferBlackHole: preferBlackHole)
        let device = loopback.captureDevice
        if loopback.usesSharedBlackHole, !AudioDevices.hasStereoFloatInput(device, sampleRate: SessionConstants.audioSampleRate) {
            throw AudioDevices.Error.coreAudio("BlackHole 2ch must already be configured for 48 kHz stereo Float32",
                                              kAudioDeviceUnsupportedFormatError)
        }
        // BlackHole may already be in use by AutoSidecar. Do not change its
        // sample rate or I/O buffer size to start the LAN stream.
        let frames = loopback.usesSharedBlackHole
            ? AudioDevices.bufferFrameSize(device)
            : AudioDevices.setBufferFrameSize(device, frames: Self.ioBufferFrames)
        let pcmFormat = float32 ? "Float32LE" : "Int16LE"
        Log.info("audio: speaker capture from \(loopback.usesSharedBlackHole ? "BlackHole 2ch" : "WiredDisplay Tap"), \(pcmFormat) stereo 48 kHz, IO buffer \(frames) frames, microphone TCC \(authorization.rawValue)")
        // The real-time IO thread only copies into a preallocated FIFO;
        // packets are built, encrypted and queued on a normal thread (audit
        // B-7: allocating, locking and encrypting on the IO thread risks
        // dropouts when the Mac is busy).
        let fifo = SpeakerFifo(channels: Int(SessionConstants.speakerChannels), lowLatency: preferBlackHole)
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil, Self.makeSpeakerIOBlock(fifo: fifo))
        guard status == noErr, let procID else { throw AudioDevices.Error.coreAudio("create speaker IOProc", status) }
        fifo.startSender(float32: float32, send)
        let started = AudioDeviceStart(device, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            fifo.stopSender()
            throw AudioDevices.Error.coreAudio("start speaker IOProc", started)
        }
        speakerDevice = device
        speakerOutputDevice = loopback.outputDevice
        speakerProc = procID
        speakerFifo = fifo
        Log.info("audio: speaker bridge started (CoreAudio -> iPad)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            Log.info("audio: speaker IO check after 3 s: \(fifo.ioCycles) IO cycles, \(fifo.overflowFrames) dropped frames")
        }
        return speakerOutputDevice
    }

    func stopSpeaker() {
        guard let procID = speakerProc else { return }
        AudioDeviceStop(speakerDevice, procID)
        AudioDeviceDestroyIOProcID(speakerDevice, procID)
        speakerProc = nil
        speakerOutputDevice = 0
        if let fifo = speakerFifo {
            fifo.stopSender()
            Log.info("audio: speaker stopped after \(fifo.ioCycles) IO cycles, \(fifo.overflowFrames) FIFO overflow frames")
        }
        speakerFifo = nil
        Log.info("audio: speaker bridge stopped")
    }

    /// Copies each I/O cycle's interleaved or planar Float32 into the FIFO.
    private nonisolated static func makeSpeakerIOBlock(fifo: SpeakerFifo) -> AudioDeviceIOBlock {
        return { _, inputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = list.first, first.mData != nil else { return }
            fifo.write(list)
        }
    }

    // MARK: microphone (iPad -> Mac)

    func startMicrophone() throws {
        guard microphoneEngine == nil else { return }
        let device = try AudioDevices.find(.microphoneFeed)
        let engine = AVAudioEngine()
        try AudioDevices.bind(engine.outputNode, to: device)
        AudioDevices.setBufferFrameSize(device, frames: Self.ioBufferFrames)
        microphoneBuffer.reset()
        let source = Self.makeSource(buffer: microphoneBuffer)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: SessionConstants.audioSampleRate, channels: 2))
        try engine.start()
        microphoneEngine = engine
        Log.info("audio: microphone bridge started (iPad -> iPad Microphone)")
    }

    func stopMicrophone() {
        guard let engine = microphoneEngine else { return }
        engine.stop()
        microphoneEngine = nil
        microphoneBuffer.reset()
        Log.info("audio: microphone bridge stopped; jitter stats \(microphoneBuffer.stats)")
    }

    /// From the network; cheap and thread-safe.
    func pushMicrophone(_ packet: AudioPacket) {
        microphoneBuffer.push(packet)
        let (count, frames) = counters.withLock { c -> (Int, Int) in
            c.received += 1
            c.receivedFrames += packet.frameCount
            return (c.received, c.receivedFrames)
        }
        if count == 1 || count % 2000 == 0 {
            let peak = packet.samples.map { abs(Int($0)) }.max() ?? 0
            Log.info("audio: microphone packets from iPad: \(count) (\(frames) frames, last peak \(peak)/32767, " +
                     "engine \(microphoneEngine != nil ? "running" : "NOT running"), jitter \(microphoneBuffer.stats))")
        }
    }

    func stopAll() {
        stopSpeaker()
        stopMicrophone()
    }

    /// Built outside any actor so the render block is not main-actor isolated.
    private nonisolated static func makeSource(buffer: AudioJitterBuffer) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: SessionConstants.audioSampleRate, channels: 2)!
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            // No array here: render callbacks must not allocate (audit C-5).
            let first = list.count > 0 ? list[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let second = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
            buffer.pull(first, second, frames: Int(frameCount))
            return noErr
        }
    }
}

/// Single-producer (CoreAudio IO thread) / single-consumer (sender thread)
/// sample FIFO for the speaker bridge. The producer never allocates and only
/// try-locks: if the sender happens to hold the lock, that one IO cycle
/// (5 ms) is dropped and counted rather than blocking the IO thread.
final class SpeakerFifo: @unchecked Sendable {
    let channels: Int
    private let capacityFrames: Int
    private let packetFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private var readFrame = 0, writeFrame = 0, count = 0
    /// Heap-allocated: an os_unfair_lock must not move (no `&property`).
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()
    private let wake = DispatchSemaphore(value: 0)
    private var running = false
    private var cycles = 0, dropped = 0

    init(channels: Int, lowLatency: Bool) {
        self.channels = channels
        capacityFrames = lowLatency ? 1_920 : 48_000 // 40 ms on LAN
        packetFrames = lowLatency ? 480 : SessionConstants.maxAudioFramesPerPacket
        storage = .allocate(capacity: capacityFrames * channels)
        storage.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * channels)
        storage.deallocate()
        lock.deallocate()
    }

    var ioCycles: Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return cycles }
    var overflowFrames: Int { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return dropped }

    /// IO thread.
    func write(_ list: UnsafeMutableAudioBufferListPointer) {
        guard os_unfair_lock_trylock(lock) else { return }
        cycles += 1
        let first = list[0]
        let interleaved = list.count == 1
        let sourceChannels = interleaved ? max(Int(first.mNumberChannels), 1) : 1
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
        let shouldWake = count == 0 && frames > 0
        let retained = min(frames, capacityFrames)
        let excess = max(0, retained - (capacityFrames - count))
        readFrame = (readFrame + excess) % capacityFrames
        count -= excess
        dropped += excess + frames - retained
        for frame in (frames - retained)..<frames {
            let base = writeFrame * channels
            for channel in 0..<channels {
                if interleaved {
                    let floats = first.mData!.assumingMemoryBound(to: Float.self)
                    storage[base + channel] = floats[frame * sourceChannels + min(channel, sourceChannels - 1)]
                } else {
                    let buffer = list[min(channel, list.count - 1)]
                    storage[base + channel] = frame < Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        ? (buffer.mData?.assumingMemoryBound(to: Float.self)[frame] ?? 0) : 0
                }
            }
            writeFrame = (writeFrame + 1) % capacityFrames
        }
        count += retained
        os_unfair_lock_unlock(lock)
        if shouldWake { wake.signal() }
    }

    /// Everything buffered so far, oldest first (sender thread).
    private func drain(into output: UnsafeMutablePointer<Float>) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let frames = min(count, packetFrames)
        guard running, frames > 0 else { return 0 }
        let first = min(frames, capacityFrames - readFrame)
        output.update(from: storage + readFrame * channels, count: first * channels)
        output.advanced(by: first * channels).update(from: storage, count: (frames - first) * channels)
        readFrame = (readFrame + frames) % capacityFrames
        count -= frames
        return frames
    }

    func startSender(float32: Bool, _ send: @escaping @Sendable ([UInt8]) -> Void) {
        os_unfair_lock_lock(lock); running = true; os_unfair_lock_unlock(lock)
        let thread = Thread { [self] in
            let scratchSize = packetFrames * channels
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchSize)
            scratch.initialize(repeating: 0, count: scratchSize)
            defer {
                scratch.deinitialize(count: scratchSize)
                scratch.deallocate()
            }
            while true {
                wake.wait()
                os_unfair_lock_lock(lock); let keepGoing = running; os_unfair_lock_unlock(lock)
                guard keepGoing else { return }
                while case let frames = drain(into: scratch), frames > 0 {
                    let samples = UnsafeBufferPointer(start: scratch, count: frames * channels)
                    send(encoded(samples, float32: float32))
                }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "wireddisplay.speaker-sender"
        thread.start()
    }

    private func encoded(_ samples: UnsafeBufferPointer<Float>, float32: Bool) -> [UInt8] {
        let channelByte = UInt8(channels)
        if float32 {
            return Float32AudioPacket(channels: channelByte, samples: samples.map { $0.isFinite ? $0 : 0 }).encoded()
        }
        let integers = samples.map { sample in
            guard sample.isFinite else { return Int16(0) }
            return Int16((max(-1, min(1, sample)) * 32_767).rounded())
        }
        return AudioPacket(channels: channelByte, samples: integers).encoded()
    }

    func stopSender() {
        os_unfair_lock_lock(lock); running = false; os_unfair_lock_unlock(lock)
        wake.signal()
    }
}
