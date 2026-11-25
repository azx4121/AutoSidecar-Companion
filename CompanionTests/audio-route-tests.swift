@main
struct AudioRoutes {
    static func main() throws {
        let buffers = SpeakerBuffers()
        for (rate, channels): (Double, UInt32) in [(48_000, 2), (44_100, 2), (44_100, 1), (48_000, 2)] {
            buffers.active.reset()
            buffers.setOutputChannels(Int(channels))
            try check(buffers, rate: rate, channels: channels)
            print("PASS \(Int(rate)) Hz、\(channels) 聲道")
        }
    }

    private static func check(_ buffers: SpeakerBuffers, rate: Double, channels: UInt32) throws {
        let engine = AVAudioEngine()
        let source = makeSpeakerSource(buffer: buffers)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        try engine.start()
        defer { engine.stop() }
        for block in 0..<10 {
            let samples = (0..<256).flatMap { frame -> [Float] in
                let time = Double(block * 256 + frame) / 48_000
                return [Float(sin(2 * .pi * 400 * time)) * 0.2,
                        Float(sin(2 * .pi * 900 * time)) * 0.2]
            }
            buffers.active.push(Float32AudioPacket(channels: 2, samples: samples))
        }
        let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        var waves = [[Float]](repeating: [], count: Int(channels))
        for _ in 0..<5 {
            let status = try engine.renderOffline(256, to: destination)
            precondition(status == .success)
            for index in waves.indices {
                waves[index].append(contentsOf: UnsafeBufferPointer(
                    start: destination.floatChannelData![index], count: Int(destination.frameLength)))
            }
        }
        func energy(_ wave: [Float], at frequency: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for (frame, sample) in wave.enumerated() {
                let angle = Double(frame) * 2 * Double.pi * frequency / rate
                real += Double(sample) * sin(angle)
                imaginary += Double(sample) * cos(angle)
            }
            return hypot(real, imaginary) / Double(wave.count)
        }
        precondition(energy(waves[0], at: 400) > 0.015)
        if channels == 1 {
            precondition(energy(waves[0], at: 900) > 0.015, "單聲道輸出遺失右側訊號")
        } else {
            precondition(energy(waves[0], at: 900) < 0.015)
            precondition(energy(waves[1], at: 900) > 0.015)
            precondition(energy(waves[1], at: 400) < 0.015)
        }
    }
}
