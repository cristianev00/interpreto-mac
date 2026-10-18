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
        if let i = args.firstIndex(of: "--voicetest") {      // --voicetest zh-CN|en-US "text" out-folder
            Task { @MainActor in await VoiceTest.run(language: args[i + 1], text: args[i + 2], folder: args[i + 3]); exit(0) }
            RunLoop.main.run()
        }
        if args.contains("--reusetest") {                    // app sequence: same mic, echo off then on
            func note(_ t: String) {
                let url = URL.desktopDirectory.appending(path: "Interpreto Diagnostics/reusetest.txt")
                let line = t + "\n"
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? Data(line.utf8).write(to: url) }
            }
            note("launched; mic permission status \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = allowed)")
            Task { @MainActor in
                note("task running")
                let mic = Microphone(), speaker = Speaker()
                let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
                for echo in [false, true, true] {
                    speaker.use(engine: echo ? mic.engine : nil)
                    note("starting mic, echo \(echo)")
                    let s: AsyncStream<AnalyzerInput>
                    do { s = try mic.start(device: nil, format: fmt, echoCancellation: echo) } catch { note("start failed: \(error)"); continue }
                    note("mic started")
                    let drain = Task.detached { for await _ in s {} }
                    try? await Task.sleep(for: .seconds(2))
                    let line = "RESULT echo \(echo): \(mic.buffersReceived) buffers in 2 s, VP \(mic.engine.inputNode.isVoiceProcessingEnabled), input format \(mic.engine.inputNode.outputFormat(forBus: 0)), running \(mic.engine.isRunning)\n"
                    print(line, terminator: "")
                    let url = URL.desktopDirectory.appending(path: "Interpreto Diagnostics/reusetest.txt")
                    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? Data(line.utf8).write(to: url) }
                    mic.stop(); drain.cancel()
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--echotest") {       // --echotest on|off seconds
            Task { @MainActor in await EchoTest.run(echo: args[i + 1] == "on", seconds: Double(args[i + 2]) ?? 20); exit(0) }
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
                        print(String(format: "CLIP start %.2f", FedClock.shared.seconds))
                        await feed(file, to: format, cont)
                        print(String(format: "CLIP end %.2f", FedClock.shared.seconds))
                        await MainActor.run { clipEnds.append(now()) }
                        await feedSilence(1.2, format, cont)
                    }
                    await feedSilence(2.0, format, cont)
                    cont.finish()
                }
                return stream
            }, onPartial: { p in
                print(String(format: "PARTIAL %.2f %d %@", FedClock.shared.seconds, p.count, String(p.suffix(30))))
            },
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


/// Writes what the voice produces (raw) to raw.caf, and lists every buffer format it delivered.
@MainActor
enum VoiceTest {
    static func run(language: String, text: String, folder: String) async {
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: text)
        u.voice = Speaker.voices(for: language).first
        print("all voices now:", AVSpeechSynthesisVoice.speechVoices().count)
        try? await Task.sleep(for: .seconds(2))
        print("all voices after 2 s:", AVSpeechSynthesisVoice.speechVoices().count)
        Speaker.voices(for: language).prefix(4).forEach { print("  candidate:", $0.identifier, $0.quality.rawValue) }
        print("voice:", u.voice.map { "\($0.name) \($0.identifier) quality \($0.quality.rawValue)" } ?? "none")
        var file: AVAudioFile?
        var formats = Set<String>()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            synth.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { done.resume(); return }
                formats.insert(pcm.format.description)
                if file == nil {
                    file = try? AVAudioFile(forWriting: URL(fileURLWithPath: folder + "/raw.caf"), settings: pcm.format.settings,
                                            commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try? file?.write(from: pcm)
            }
        }
        print("formats delivered:", formats.count)
        // Compare old (fresh converter per buffer) vs new (mixer converts) at 48 kHz.
        guard let raw = try? AVAudioFile(forReading: URL(fileURLWithPath: folder + "/raw.caf")) else { return }
        let src = raw.processingFormat
        let out48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        var chunks: [AVAudioPCMBuffer] = []
        while raw.framePosition < raw.length {
            let b = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 1024)!
            try? raw.read(into: b, frameCount: 1024); chunks.append(b)
        }
        // old
        let old = try! AVAudioFile(forWriting: URL(fileURLWithPath: folder + "/old.caf"), settings: out48.settings)
        for b in chunks {
            let conv = AVAudioConverter(from: src, to: out48)!
            let o = AVAudioPCMBuffer(pcmFormat: out48, frameCapacity: AVAudioFrameCount(Double(b.frameLength) * 48_000 / src.sampleRate) + 64)!
            var fed = false; var err: NSError?
            conv.convert(to: o, error: &err) { _, st in if fed { st.pointee = .noDataNow; return nil }; fed = true; st.pointee = .haveData; return b }
            try? old.write(from: o)
        }
        // new: player in the source format, mixer renders 48 kHz (offline)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: src)
        try! engine.enableManualRenderingMode(.offline, format: out48, maximumFrameCount: 4096)
        try! engine.start()
        for b in chunks { player.scheduleBuffer(b, completionHandler: nil) }
        player.play()
        let new = try! AVAudioFile(forWriting: URL(fileURLWithPath: folder + "/new.caf"), settings: out48.settings)
        let total = AVAudioFramePosition(Double(raw.length) * 48_000 / src.sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while engine.manualRenderingSampleTime < total {
            if (try? engine.renderOffline(4096, to: buf)) == .success { try? new.write(from: buf) } else { break }
        }
        print("wrote old.caf and new.caf")
    }
}


/// Real-room test: listens to the microphone (English) while Interpreto keeps speaking Chinese
/// on the speakers. With echo cancellation, only the person in the room should be transcribed.
@MainActor
enum EchoTest {
    static func run(echo: Bool, seconds: Double) async {
        let mic = Microphone(), recognizer = Recognizer(), speaker = Speaker()
        speaker.use(engine: echo ? mic.engine : nil)
        print("echo cancellation:", echo)
        do {
            try await recognizer.start(direction: .enToZh, vocabulary: [],
                input: { f in
                    let live = try mic.start(device: nil, format: f, echoCancellation: echo)
                    // Also save exactly what the recognizer hears.
                    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "interpreto-heard-\(echo ? "on" : "off").caf")
                    let file = try AVAudioFile(forWriting: url, settings: f.settings, commonFormat: f.commonFormat, interleaved: f.isInterleaved)
                    print("saving heard audio to", url.path)
                    return AsyncStream { cont in
                        Task.detached { for await x in live { try? file.write(from: x.buffer); cont.yield(x) }; cont.finish() }
                    }
                },
                onPartial: { _ in }, onCommit: { _, text, s, e in print(String(format: "  heard [%.1f–%.1fs]: %@", s, e, text)) },
                onRevise: { _, text in print("  revised:", text) }, onError: { print("error", $0) })
        } catch { print("start failed", error); return }
        let lines = ["今天我们学习C语言中的指针。", "指针是一个存储地址的变量。", "请大家打开课本第三十页。", "我们来看第一个例子。"]
        let t0 = Date()
        var k = 0
        while Date().timeIntervalSince(t0) < seconds {
            if !speaker.isSpeaking {
                print(String(format: "  [voice starts at %.1fs]", Date().timeIntervalSince(t0)))
                speaker.speak(lines[k % lines.count], language: "zh-CN", voiceID: nil, outputUID: nil, onStart: {})
                k += 1
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        mic.stop()
        await recognizer.stop()
        print("Interpreto spoke \(k) Chinese sentences")
    }
}
