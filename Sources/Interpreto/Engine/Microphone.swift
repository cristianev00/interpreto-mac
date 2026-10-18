import AVFoundation
import Speech

/// Captures a microphone and streams it, converted to the speech model's format, as analyzer input.
///
/// With echo cancellation on, the spoken translation plays through this same engine, and Apple's
/// voice processing (as in FaceTime) removes it from what the microphone hears. So the speaker can
/// keep talking while the translation is spoken, without it being heard as speech.
final class Microphone {
    let engine = AVAudioEngine()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tapped = false

    /// Called on the audio thread with the input level (RMS, 0…1).
    var onLevel: ((Float) -> Void)?

    func start(device: AudioDeviceID?, format target: AVAudioFormat, echoCancellation: Bool) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != echoCancellation {
            if engine.isRunning { engine.stop() }
            try input.setVoiceProcessingEnabled(echoCancellation)
        }
        if echoCancellation {
            // Don't turn down other apps (a video being translated, a call) while listening.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            input.isVoiceProcessingAGCEnabled = true
        }
        AudioDevices.route(input, to: device)
        let source = input.outputFormat(forBus: 0)
        // Microphones (and voice processing, which reports 9 identical channels) can be
        // multichannel: take the first channel as mono, then convert to the model's format.
        guard source.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: target) else {
            throw NSError(domain: "Interpreto", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This microphone can’t be used. Choose another one in Settings."])
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont

        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] raw, _ in
            guard let self, let ch = raw.floatChannelData?[0],
                  let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: raw.frameLength),
                  let dst = buffer.floatChannelData?[0] else { return }
            let n = Int(raw.frameLength)
            buffer.frameLength = raw.frameLength
            dst.update(from: ch, count: n)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            self.onLevel?(sqrt(sum / Float(max(1, n))))
            let capacity = AVAudioFrameCount(Double(n) * target.sampleRate / source.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
        }
        tapped = true
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        return stream
    }

    /// Stops listening. With `keepEngine`, the engine keeps running so a translation still being
    /// spoken through it can finish; call `stopEngine()` afterwards.
    func stop(keepEngine: Bool = false) {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        continuation?.finish()
        continuation = nil
        if !keepEngine { stopEngine() }
    }

    func stopEngine() {
        guard !tapped else { return }
        engine.stop()
    }
}
