import Foundation
import SherpaOnnxC

/// Neural text-to-speech voices run by sherpa-onnx on the CPU.
struct NeuralVoiceSpec: Hashable, Identifiable {
    enum Kind: String { case matcha, kokoro, melo, supertonic, piper, kitten }
    let id: String               // e.g. "kokoro-zh-3"
    let kind: Kind
    let folder: String           // model folder name
    let sid: Int
    let language: String         // "zh" or "en"
    let name: String
}

final class NeuralVoice {
    let spec: NeuralVoiceSpec
    private let tts: SherpaOnnxOfflineTtsWrapper
    var sampleRate: Int { Int(tts.sampleRate) }

    /// `root`: the folder that holds the model folders (and vocos-16khz-univ.onnx for Matcha).
    init?(_ spec: NeuralVoiceSpec, root: URL) {
        self.spec = spec
        let d = root.appending(path: spec.folder).path
        func f(_ name: String) -> String { d + "/" + name }
        var model: SherpaOnnxOfflineTtsModelConfig
        var rules = ""
        switch spec.kind {
        case .matcha:
            model = sherpaOnnxOfflineTtsModelConfig(
                matcha: sherpaOnnxOfflineTtsMatchaModelConfig(
                    acousticModel: f("model-steps-3.onnx"), vocoder: root.appending(path: "vocos-16khz-univ.onnx").path,
                    lexicon: f("lexicon.txt"), tokens: f("tokens.txt"), dataDir: f("espeak-ng-data")),
                numThreads: 4)
            rules = ["date-zh.fst", "phone-zh.fst", "number-zh.fst"].map(f).joined(separator: ",")
        case .kokoro:
            model = sherpaOnnxOfflineTtsModelConfig(
                kokoro: sherpaOnnxOfflineTtsKokoroModelConfig(
                    model: f("model.int8.onnx"), voices: f("voices.bin"), tokens: f("tokens.txt"),
                    dataDir: f("espeak-ng-data"), dictDir: f("dict"),
                    lexicon: f("lexicon-us-en.txt") + "," + f("lexicon-zh.txt")),
                numThreads: 4)
            if spec.language == "zh" { rules = ["date-zh.fst", "phone-zh.fst", "number-zh.fst"].map(f).joined(separator: ",") }
        case .melo:
            model = sherpaOnnxOfflineTtsModelConfig(
                vits: sherpaOnnxOfflineTtsVitsModelConfig(model: f("model.onnx"), lexicon: f("lexicon.txt"),
                                                          tokens: f("tokens.txt"), dictDir: f("dict")),
                numThreads: 4)
            rules = ["date.fst", "phone.fst", "number.fst"].map(f).joined(separator: ",")
        case .supertonic:
            model = sherpaOnnxOfflineTtsModelConfig(
                numThreads: 4,
                supertonic: sherpaOnnxOfflineTtsSupertonicModelConfig(
                    durationPredictor: f("duration_predictor.int8.onnx"), textEncoder: f("text_encoder.int8.onnx"),
                    vectorEstimator: f("vector_estimator.int8.onnx"), vocoder: f("vocoder.int8.onnx"),
                    ttsJson: f("tts.json"), unicodeIndexer: f("unicode_indexer.bin"), voiceStyle: f("voice.bin")))
        case .piper:
            let onnx = (try? FileManager.default.contentsOfDirectory(atPath: d))?.first { $0.hasSuffix(".onnx") } ?? "model.onnx"
            model = sherpaOnnxOfflineTtsModelConfig(
                vits: sherpaOnnxOfflineTtsVitsModelConfig(model: f(onnx), tokens: f("tokens.txt"), dataDir: f("espeak-ng-data")),
                numThreads: 4)
        case .kitten:
            model = sherpaOnnxOfflineTtsModelConfig(
                numThreads: 4,
                kitten: sherpaOnnxOfflineTtsKittenModelConfig(model: f("model.onnx"), voices: f("voices.bin"),
                                                              tokens: f("tokens.txt"), dataDir: f("espeak-ng-data")))
        }
        if let provider = ProcessInfo.processInfo.environment["TTS_PROVIDER"] {   // benchmarking: "coreml"
            model.provider = toCPointer(provider)
        }
        var config = sherpaOnnxOfflineTtsConfig(model: model, ruleFsts: rules)
        let tts = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard tts.tts != nil else { return nil }
        self.tts = tts
    }

    /// Synthesizes `text`; returns mono float samples at `sampleRate`.
    func synthesize(_ text: String, speed: Float = 1.0) -> [Float] {
        var cfg = SherpaOnnxGenerationConfigSwift(speed: speed, sid: spec.sid)
        if spec.kind == .supertonic {
            cfg.numSteps = 5
            cfg.extra = ["lang": "en"]
        }
        let audio = tts.generateWithConfig(text: text, config: cfg, callback: nil, arg: nil)
        return audio.samples
    }
}

// MARK: - Voice packs and the voice engine

/// The natural voices Interpreto offers (measured: fast enough to speak live, as clear as Apple's).
enum VoicePack: String, CaseIterable, Identifiable {
    case matcha        // Chinese, 0.19 s per sentence
    case supertonic    // English, 10 voices, ~1 s per sentence (spoken clause by clause)
    var id: String { rawValue }

    var title: String { self == .matcha ? "Natural Chinese voice (Matcha)" : "Natural English voices (Supertonic)" }
    var size: String { self == .matcha ? "about 130 MB" : "about 130 MB" }
    var folder: String { self == .matcha ? "matcha-icefall-zh-en" : "sherpa-onnx-supertonic-3-tts-int8-2026-05-11" }

    /// (file name, sha256): archives are unpacked into the voices folder.
    var files: [(String, String)] {
        switch self {
        case .matcha: [("matcha-icefall-zh-en.tar.bz2", "271b804af570400d3bcdcb53bf6e53cc9f75180ee763b9f13eb5eaf2b0d086ef"),
                       ("vocos-16khz-univ.onnx", "b599142a1fb8ff03de3e84ac35ff537c619e56f4267a6fe894851a42844acf9e")]
        case .supertonic: [("sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2",
                            "82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427")]
        }
    }

    static func url(_ file: String) -> URL {
        let release = file.hasPrefix("vocos") ? "vocoder-models" : "tts-models"
        return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/\(release)/\(file)")!
    }

    nonisolated static var folderURL: URL { ModelStore.folder.appending(path: "voices", directoryHint: .isDirectory) }

    var isInstalled: Bool {
        let d = Self.folderURL.appending(path: folder)
        switch self {
        case .matcha: return FileManager.default.fileExists(atPath: d.appending(path: "model-steps-3.onnx").path)
            && FileManager.default.fileExists(atPath: Self.folderURL.appending(path: "vocos-16khz-univ.onnx").path)
        case .supertonic: return FileManager.default.fileExists(atPath: d.appending(path: "voice.bin").path)
        }
    }

    /// Voice choices stored in settings: "neural:matcha" or "neural:supertonic:<0…9>".
    static func spec(for id: String?) -> NeuralVoiceSpec? {
        guard let id, id.hasPrefix("neural:") else { return nil }
        let parts = id.split(separator: ":")
        if parts.count >= 2, parts[1] == "matcha" {
            return NeuralVoiceSpec(id: id, kind: .matcha, folder: VoicePack.matcha.folder, sid: 0, language: "zh", name: "Matcha")
        }
        if parts.count == 3, parts[1] == "supertonic", let sid = Int(parts[2]) {
            return NeuralVoiceSpec(id: id, kind: .supertonic, folder: VoicePack.supertonic.folder, sid: sid,
                                   language: "en", name: supertonicName(sid))
        }
        return nil
    }

    /// Supertonic's voices 0–4 are female, 5–9 male (by measured pitch).
    static func supertonicName(_ sid: Int) -> String { sid < 5 ? "Female \(sid + 1)" : "Male \(sid - 4)" }

    static func pack(of spec: NeuralVoiceSpec) -> VoicePack { spec.kind == .matcha ? .matcha : .supertonic }
}

/// Runs neural voices off the main thread; keeps loaded voices until `unload()`.
actor VoiceEngine {
    static let shared = VoiceEngine()
    private var voices: [String: NeuralVoice] = [:]

    func synthesize(_ text: String, _ spec: NeuralVoiceSpec) -> (samples: [Float], rate: Int)? {
        if voices[spec.id] == nil {
            voices[spec.id] = NeuralVoice(spec, root: VoicePack.folderURL)
        }
        guard let v = voices[spec.id] else { return nil }
        let s = v.synthesize(text)
        return s.isEmpty ? nil : (s, v.sampleRate)
    }

    func unload() { voices.removeAll() }
}
