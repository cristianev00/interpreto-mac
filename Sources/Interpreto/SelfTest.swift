import AVFoundation
import Speech
import SwiftUI

/// `Interpreto --selftest en|zh clip1.wav clip2.wav …` streams recordings through the app's own
/// recognizer and translator at real-time speed (like a microphone, with a pause between clips)
/// and prints each sentence, its translation and the delay after the speaker stopped.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--translate") {       // --translate en|zh "text" ["term = 术语\n…"]
            let d: Direction = args[i + 1] == "zh" ? .zhToEn : .enToZh
            let g = Glossary(text: args.count > i + 3 ? args[i + 3] : "")
            Task { @MainActor in
                print((try? await Translator().translate(args[i + 2], d, glossary: g)) ?? "<error>")
                exit(0)
            }
            RunLoop.main.run()
        }
        guard let i = args.firstIndex(of: "--selftest") else { InterpretoApp.main(); return }
        let dir: Direction = args[i + 1] == "zh" ? .zhToEn : .enToZh
        let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            await SelfTest.run(dir, files)
            exit(0)
        }
        RunLoop.main.run()
    }
}

/// Seconds of audio fed so far (the test's exact audio clock).
final class FedClock: @unchecked Sendable {
    static let shared = FedClock()
    private let lock = NSLock()
    private var t = 0.0
    var seconds: Double { lock.withLock { t } }
    func add(_ s: Double) { lock.withLock { t += s } }
}

@MainActor
enum SelfTest {
    static func run(_ d: Direction, _ files: [URL]) async {
        let recognizer = Recognizer()
        let translator = Translator()
        let t0 = Date()
        var clipEnds: [Double] = []
        var pending: [Task<Void, Never>] = []
        func now() -> Double { Date().timeIntervalSince(t0) }

        do {
            try await recognizer.start(direction: d, vocabulary: [], input: { format in
                let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
                Task.detached {
                    for f in files {
                        guard let file = try? AVAudioFile(forReading: f) else { continue }
                        await feed(file, to: format, cont)
                        await MainActor.run { clipEnds.append(now()) }
                        await feedSilence(1.2, format, cont)
                    }
                    await feedSilence(2.0, format, cont)
                    cont.finish()
                }
                return stream
            }, onPartial: { p in if Recognizer.debug { print(String(format: "    %.2fs partial: %@", now(), String(p.suffix(50)))) } },
            onCommit: { id, text, _, wordEnd in
                let heard = FedClock.shared.seconds
                let speechEnd = wordEnd
                pending.append(Task { @MainActor in
                    let tr = (try? await translator.translate(text, d, glossary: Glossary(text: ""))) ?? "<error>"
                    let done = FedClock.shared.seconds
                    print(String(format: "[sentence %.2fs, translated %.2fs after the last word]", heard - speechEnd, done - speechEnd))
                    print("  \(text)\n  → \(tr)")
                })
            }, onRevise: { _, text in
                pending.append(Task { @MainActor in
                    let tr = (try? await translator.translate(text, d, glossary: Glossary(text: ""))) ?? "<error>"
                    print(String(format: "[revised at %.2fs]\n  \(text)\n  → \(tr)", now()))
                })
            }, onError: { print("error:", $0) })
        } catch { print("start failed:", error); return }
        let expected = files.count
        while clipEnds.count < expected { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2.5))
        await recognizer.stop()
        for t in pending { await t.value }
    }

    nonisolated static func feed(_ file: AVAudioFile, to target: AVAudioFormat, _ cont: AsyncStream<AnalyzerInput>.Continuation) async {
        let src = file.processingFormat
        guard let conv = AVAudioConverter(from: src, to: target) else { return }
        let chunk = AVAudioFrameCount(src.sampleRate / 10)          // 100 ms, sent in real time
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk), (try? file.read(into: buf, frameCount: chunk)) != nil,
                  let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(chunk) * target.sampleRate / src.sampleRate) + 64)
            else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return buf
            }
            cont.yield(AnalyzerInput(buffer: out))
            FedClock.shared.add(Double(buf.frameLength) / src.sampleRate)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    nonisolated static func feedSilence(_ seconds: Double, _ format: AVAudioFormat, _ cont: AsyncStream<AnalyzerInput>.Continuation) async {
        for _ in 0..<Int(seconds * 10) {
            let n = AVAudioFrameCount(format.sampleRate / 10)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            b.frameLength = n
            // Room tone, like a real microphone between sentences (not digital silence).
            if let p = b.int16ChannelData?[0] { for i in 0..<Int(n) { p[i] = Int16.random(in: -60...60) } }
            else if let p = b.floatChannelData?[0] { for i in 0..<Int(n) { p[i] = Float.random(in: -0.002...0.002) } }
            cont.yield(AnalyzerInput(buffer: b))
            FedClock.shared.add(0.1)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
