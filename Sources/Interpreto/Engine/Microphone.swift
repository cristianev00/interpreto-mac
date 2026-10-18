import AVFoundation
import Speech

/// Captures a microphone and streams it, converted to the speech model's format, as analyzer input.
final class Microphone {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    /// Called on the audio thread with the input level (RMS, 0…1).
    var onLevel: ((Float) -> Void)?

    func start(device: AudioDeviceID?, format target: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        AudioDevices.route(input, to: device)
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "Interpreto", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This microphone can’t be used. Choose another one in Settings."])
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont

        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            if let ch = buffer.floatChannelData?[0] {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
                self.onLevel?(sqrt(sum / Float(max(1, buffer.frameLength))))
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / source.sampleRate) + 64
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
        engine.prepare()
        try engine.start()
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
