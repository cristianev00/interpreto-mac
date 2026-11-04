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
        if let i = args.firstIndex(of: "--ttsbench") {       // --ttsbench <models root> <out dir with zh.txt, en.txt>
            Task { @MainActor in await TTSBench.run(root: URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2])); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--speakfile") {      // --speakfile en|zh lines.txt outdir: one wav per line
            Task { @MainActor in
                let zh = args[i + 1] == "zh"
                let spec = VoicePack.spec(for: zh ? "neural:matcha" : "neural:paradee:0")!
                let lines = ((try? String(contentsOfFile: args[i + 2], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                for (k, line) in lines.enumerated() {
                    guard let out = await VoiceEngine.shared.synthesize(line, spec) else { continue }
                    TTSBench.save(out.samples, rate: out.rate, to: URL(fileURLWithPath: args[i + 3]).appending(path: String(format: "%02d.wav", k)))
                }
                print("wrote", lines.count)
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--fixterms") {        // --fixterms en|zh "text"
            let zh = args[i + 1] == "zh"
            let g = Glossary(text: TermPacks.cProgramming)
            print(TermFixer.fix(args[i + 2], terms: g.vocabulary(for: zh ? .zhToEn : .enToZh), chinese: zh))
            exit(0)
        }
        if let i = args.firstIndex(of: "--systemtest") {     // --systemtest all|<bundle id> en|zh seconds [--engine e]
            let source = args[i + 1] == "all" ? ListenSource.allApps : .app(args[i + 1])
            let d: Direction = args[i + 2] == "zh" ? .zhToEn : .enToZh
            let seconds = Double(args[i + 3]) ?? 30
            let engine = args.firstIndex(of: "--engine").flatMap { SpeechEngine(rawValue: args[$0 + 1]) } ?? .apple
            // When launched by Finder (`open --args`), output goes to a file on the Desktop too.
            let log = URL.desktopDirectory.appending(path: "Interpreto Diagnostics/systemtest.txt")
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: log)
            func print(_ items: Any...) {
                let line = items.map { "\($0)" }.joined(separator: " ")
                Swift.print(line)
                if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
            }
            Task { @MainActor in
                let mic = Microphone()
                var peak: Float = 0
                mic.onLevel = { peak = max(peak, $0) }
                let rec: SpeechRecognizing = engine == .apple ? Recognizer() : ModelRecognizer(engine: engine)
                let t0 = Date()
                do {
                    try await rec.start(direction: d, vocabulary: [], input: { f in
                        try mic.start(uid: nil, format: f, echoCancellation: false, source: source)
                    }, onPartial: { _ in }, onCommit: { _, text, _, _ in
                        print(String(format: "[%.1fs] %@", Date().timeIntervalSince(t0), text))
                    }, onRevise: { _, text in print("  revised:", text) }, onError: { print("error:", $0) })
                } catch { print("start failed:", error.localizedDescription); exit(1) }
                print("listening to:", source.raw, "— apps:", SystemAudio.apps().prefix(6).map { "\($0.name)\($0.playing ? "*" : "")" })
                try? await Task.sleep(for: .seconds(seconds))
                print("buffers received:", mic.buffersReceived, "loudest level:", peak)
                mic.stop(); await rec.stop()
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--voicepack"), let pack = VoicePack(rawValue: args[i + 1]) {
            Task { @MainActor in
                ModelStore.shared.download(pack)
                while true {
                    switch ModelStore.shared.state(pack) {
                    case .installed: print("installed", pack.rawValue); exit(0)
                    case .failed(let m): print("failed:", m); exit(1)
                    default: try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
            RunLoop.main.run()
        }
        if args.contains("--voicefirst") {                  // time to the first spoken clause, and memory
            Task { @MainActor in
                func rss() -> Double {
                    var info = mach_task_basic_info(); var n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
                    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) } }
                    return Double(info.resident_size) / 1e6
                }
                print(String(format: "memory at start: %.0f MB", rss()))
                let tests: [(String, String)] = [
                    ("neural:matcha", "在目睹了第一次世界大战期间的恐怖与暴行之后，各国都希望在未来避免再发生类似的情况。"),
                    ("neural:paradee:0", "After seeing the horrors and atrocities of war during World War One, nations desired to avoid such a situation again in the future."),
                ]
                for (id, text) in tests {
                    guard let spec = VoicePack.spec(for: id) else { continue }
                    _ = await VoiceEngine.shared.synthesize("你好。", spec)          // load
                    let clauses = Speaker.clauses(text)
                    let t = Date()
                    let first = await VoiceEngine.shared.synthesize(clauses[0], spec)
                    let firstTime = Date().timeIntervalSince(t)
                    let whole = Date()
                    _ = await VoiceEngine.shared.synthesize(text, spec)
                    print(String(format: "%@: %d clauses; first clause ready in %.2fs (%.1fs of audio); whole sentence at once %.2fs",
                                 id, clauses.count, firstTime, Double(first?.samples.count ?? 0) / Double(first?.rate ?? 1), Date().timeIntervalSince(whole)))
                }
                print(String(format: "memory with voices loaded: %.0f MB", rss()))
                await VoiceEngine.shared.unload()
                try? await Task.sleep(for: .seconds(1))
                print(String(format: "memory after unloading: %.0f MB", rss()))
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
        let engine = args.firstIndex(of: "--engine").flatMap { SpeechEngine(rawValue: args[$0 + 1]) } ?? .apple
        let files = args[(i + 2)...].filter { $0.hasSuffix(".wav") }.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            await SelfTest.run(dir, files, engine: engine)
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
    static func run(_ d: Direction, _ files: [URL], engine: SpeechEngine = .apple) async {
        let recognizer: SpeechRecognizing = engine == .apple ? Recognizer() : ModelRecognizer(engine: engine)
        print("engine:", engine.rawValue)
        let translator = Translator()
        let t0 = Date()
        var clipEnds: [Double] = []
        var pending: [Task<Void, Never>] = []
        func now() -> Double { Date().timeIntervalSince(t0) }

        do {
            try await recognizer.start(direction: d, vocabulary: [], input: { format in
                let (stream, cont) = AudioStream.makeStream()
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

    nonisolated static func feed(_ file: AVAudioFile, to target: AVAudioFormat, _ cont: AudioStream.Continuation) async {
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
            cont.yield(out)
            FedClock.shared.add(Double(buf.frameLength) / src.sampleRate)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    nonisolated static func feedSilence(_ seconds: Double, _ format: AVAudioFormat, _ cont: AudioStream.Continuation) async {
        for _ in 0..<Int(seconds * 10) {
            let n = AVAudioFrameCount(format.sampleRate / 10)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            b.frameLength = n
            // Room tone, like a real microphone between sentences (not digital silence).
            if let p = b.int16ChannelData?[0] { for i in 0..<Int(n) { p[i] = Int16.random(in: -60...60) } }
            else if let p = b.floatChannelData?[0] { for i in 0..<Int(n) { p[i] = Float.random(in: -0.002...0.002) } }
            cont.yield(b)
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
                    let live = try mic.start(uid: nil, format: f, echoCancellation: echo)
                    // Also save exactly what the recognizer hears.
                    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "interpreto-heard-\(echo ? "on" : "off").caf")
                    let file = try AVAudioFile(forWriting: url, settings: f.settings, commonFormat: f.commonFormat, interleaved: f.isInterleaved)
                    print("saving heard audio to", url.path)
                    return AsyncStream { cont in
                        Task.detached { for await x in live { try? file.write(from: x); cont.yield(x) }; cont.finish() }
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


/// Times each candidate voice and saves its audio, for intelligibility scoring and listening.
@MainActor
enum TTSBench {
    static let candidates: [NeuralVoiceSpec] = [
        .init(id: "matcha-zh", kind: .matcha, folder: "matcha-icefall-zh-en", sid: 0, language: "zh", name: "Matcha"),
        .init(id: "kokoro11-zh-3", kind: .kokoro, folder: "kokoro-int8-multi-lang-v1_1", sid: 3, language: "zh", name: "Kokoro 1.1 #3"),
        .init(id: "kokoro11-zh-50", kind: .kokoro, folder: "kokoro-int8-multi-lang-v1_1", sid: 50, language: "zh", name: "Kokoro 1.1 #50"),
        .init(id: "kokoro10-zh-45", kind: .kokoro, folder: "kokoro-int8-multi-lang-v1_0", sid: 45, language: "zh", name: "Kokoro 1.0 xiaobei"),
        .init(id: "melo-zh", kind: .melo, folder: "vits-melo-tts-zh_en", sid: 0, language: "zh", name: "MeloTTS"),
        .init(id: "supertonic-en-0", kind: .supertonic, folder: "sherpa-onnx-supertonic-3-tts-int8-2026-05-11", sid: 0, language: "en", name: "Supertonic 3 #0"),
        .init(id: "supertonic-en-5", kind: .supertonic, folder: "sherpa-onnx-supertonic-3-tts-int8-2026-05-11", sid: 5, language: "en", name: "Supertonic 3 #5"),
        .init(id: "kokoro10-en-heart", kind: .kokoro, folder: "kokoro-int8-multi-lang-v1_0", sid: 3, language: "en", name: "Kokoro af_heart"),
        .init(id: "piper-en-lessac", kind: .piper, folder: "vits-piper-en_US-lessac-high-int8", sid: 0, language: "en", name: "Piper lessac"),
        .init(id: "kitten-en-0", kind: .kitten, folder: "kitten-mini-en-v0_8", sid: 0, language: "en", name: "Kitten mini"),
    ]

    static func run(root: URL, out: URL) async {
        var summary: [[String: Any]] = []
        for lang in ["zh", "en"] {
            let lines = ((try? String(contentsOf: out.appending(path: "\(lang).txt"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            if lines.isEmpty { continue }
            // Apple baseline
            summary.append(await apple(lang, lines, out))
            let only = ProcessInfo.processInfo.environment["TTS_ONLY"]
            let list = ProcessInfo.processInfo.environment["TTS_SUPERTONIC_ALL"] == nil ? candidates
                : (0..<10).map { NeuralVoiceSpec(id: "supertonic-en-voice\($0 + 1)", kind: .supertonic,
                                                 folder: "sherpa-onnx-supertonic-3-tts-int8-2026-05-11", sid: $0, language: "en", name: "") }
            for spec in list where spec.language == lang && (only == nil || spec.id.contains(only!)) {
                let t0 = Date()
                guard let voice = NeuralVoice(spec, root: root) else { print("could not load", spec.id); continue }
                let load = Date().timeIntervalSince(t0)
                var times: [Double] = [], durs: [Double] = []
                for (k, line) in lines.enumerated() {
                    let t = Date()
                    let audio = voice.synthesize(line)
                    times.append(Date().timeIntervalSince(t))
                    durs.append(Double(audio.count) / Double(voice.sampleRate))
                    save(audio, rate: voice.sampleRate, to: out.appending(path: "\(spec.id)_\(k).wav"))
                }
                let rtf = times.reduce(0, +) / max(0.001, durs.reduce(0, +))
                print(String(format: "%-20@ load %.2fs  median synth %.2fs  RTF %.3f", spec.id as NSString, load, times.sorted()[times.count / 2], rtf))
                summary.append(["id": spec.id, "lang": lang, "load": load, "times": times, "durations": durs])
            }
        }
        try? JSONSerialization.data(withJSONObject: summary).write(to: out.appending(path: "summary.json"))
    }

    static func apple(_ lang: String, _ lines: [String], _ out: URL) async -> [String: Any] {
        let voice = Speaker.voices(for: lang == "zh" ? "zh-CN" : "en-US").first
        let synth = AVSpeechSynthesizer()
        var times: [Double] = [], durs: [Double] = []
        for (k, line) in lines.enumerated() {
            let u = AVSpeechUtterance(string: line); u.voice = voice
            var samples: [Float] = []; var rate = 22050
            let t = Date()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                synth.write(u) { buf in
                    guard let pcm = buf as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 { done.resume(); return }
                    rate = Int(pcm.format.sampleRate)
                    if let c = pcm.floatChannelData?[0] { samples += UnsafeBufferPointer(start: c, count: Int(pcm.frameLength)) }
                }
            }
            times.append(Date().timeIntervalSince(t)); durs.append(Double(samples.count) / Double(rate))
            save(samples, rate: rate, to: out.appending(path: "apple-\(lang)_\(k).wav"))
        }
        print(String(format: "%-20@ median synth %.2fs", "apple-\(lang)" as NSString, times.sorted()[times.count / 2]))
        return ["id": "apple-\(lang)", "lang": lang, "load": 0, "times": times, "durations": durs]
    }

    static func save(_ samples: [Float], rate: Int, to url: URL) {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                                      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buf)
    }
}
