import CryptoKit
import FluidAudio
import Foundation
import Observation

/// Speech-recognition engines. Apple's is built in; the others are downloaded once and measured to
/// be more accurate: Parakeet made ~30% fewer errors than Apple on accented English (22 accents),
/// SenseVoice ~25% fewer on Mandarin.
enum SpeechEngine: String, CaseIterable, Identifiable {
    case apple, parakeet, sensevoice
    var id: String { rawValue }

    static func options(for d: Direction) -> [SpeechEngine] {
        d == .enToZh ? [.apple, .parakeet] : [.apple, .sensevoice]
    }

    static func chosen(for d: Direction) -> SpeechEngine {
        let key = d == .enToZh ? Pref.engineEN : Pref.engineZH
        return SpeechEngine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .apple
    }

    var title: String {
        switch self {
        case .apple: "Apple (built in)"
        case .parakeet: "Parakeet — best with accents"
        case .sensevoice: "SenseVoice — most accurate Chinese"
        }
    }

    var downloadSize: String {
        switch self {
        case .apple: ""
        case .parakeet: "about 480 MB"
        case .sensevoice: "about 230 MB"
        }
    }
}

/// Downloads and keeps the optional speech models in ~/Library/Application Support/Interpreto/Models.
@MainActor
@Observable
final class ModelStore {
    static let shared = ModelStore()

    enum State: Equatable { case notInstalled, downloading(Double), installed, failed(String) }
    private(set) var states: [SpeechEngine: State] = [:]
    /// The optional English → Chinese translation model (HY-MT2).
    private(set) var hymt2: State = .notInstalled
    private(set) var voiceStates: [VoicePack: State] = [:]

    func state(_ p: VoicePack) -> State {
        if case .downloading = voiceStates[p] ?? .notInstalled { return voiceStates[p]! }
        if case .failed = voiceStates[p] ?? .notInstalled { return voiceStates[p]! }
        return p.isInstalled ? .installed : .notInstalled
    }

    /// Downloads a voice pack from sherpa-onnx's releases, checks it, and unpacks it.
    func download(_ p: VoicePack) {
        if case .downloading = state(p) { return }
        voiceStates[p] = .downloading(0)
        Task {
            do {
                let dir = VoicePack.folderURL
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, (file, sha)) in p.files.enumerated() {
                    let share = 1.0 / Double(p.files.count)
                    let tmp = try await Self.fetch(VoicePack.url(file)) { f in
                        Task { @MainActor in ModelStore.shared.voiceStates[p] = .downloading((Double(i) + f) * share) }
                    }
                    guard try await Self.sha256(tmp) == sha else {
                        throw NSError(domain: "Interpreto", code: 20, userInfo: [NSLocalizedDescriptionKey: "The download was damaged."])
                    }
                    if file.hasSuffix(".tar.bz2") {
                        try await Self.untar(tmp, into: dir)
                        try? FileManager.default.removeItem(at: tmp)
                    } else {
                        try? FileManager.default.removeItem(at: dir.appending(path: file))
                        try FileManager.default.moveItem(at: tmp, to: dir.appending(path: file))
                    }
                }
                voiceStates[p] = p.isInstalled ? .installed : .failed("The voice didn’t install.")
            } catch {
                voiceStates[p] = .failed(error.localizedDescription)
            }
        }
    }

    func remove(_ p: VoicePack) {
        Task { await VoiceEngine.shared.unload() }
        try? FileManager.default.trashItem(at: VoicePack.folderURL.appending(path: p.folder), resultingItemURL: nil)
        voiceStates[p] = nil
    }

    private static func sha256(_ url: URL) async throws -> String {
        try await Task.detached {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try h.read(upToCount: 1 << 22), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func untar(_ archive: URL, into dir: URL) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xjf", archive.path, "-C", dir.path]
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw NSError(domain: "Interpreto", code: 21, userInfo: [NSLocalizedDescriptionKey: "The voice couldn’t be unpacked."])
            }
        }.value
    }

    nonisolated static let folder = URL.applicationSupportDirectory.appending(path: "Interpreto/Models", directoryHint: .isDirectory)
    nonisolated static var parakeetFolder: URL { folder.appending(path: "parakeet", directoryHint: .isDirectory) }
    nonisolated static var senseVoiceFolder: URL { folder.appending(path: "sensevoice", directoryHint: .isDirectory) }
    nonisolated static let senseVoiceFiles = ["model.int8.onnx", "tokens.txt"]
    nonisolated static let senseVoiceRepo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

    init() { refresh() }

    func state(_ e: SpeechEngine) -> State { e == .apple ? .installed : states[e] ?? .notInstalled }

    func refresh() {
        if case .downloading = hymt2 {} else { hymt2 = HYMT2.isInstalled ? .installed : .notInstalled }
        for e in [SpeechEngine.parakeet, .sensevoice] {
            if case .downloading = states[e] { continue }
            states[e] = Self.isInstalled(e) ? .installed : .notInstalled
        }
    }

    nonisolated static func isInstalled(_ e: SpeechEngine) -> Bool {
        switch e {
        case .apple: true
        case .parakeet: AsrModels.modelsExist(at: parakeetFolder, version: .v3)
        case .sensevoice: senseVoiceFiles.allSatisfy {
            FileManager.default.fileExists(atPath: senseVoiceFolder.appending(path: $0).path)
        }
        }
    }

    func download(_ e: SpeechEngine) {
        if case .downloading = state(e) { return }
        states[e] = .downloading(0)
        Task {
            do {
                await Self.chooseMirror()
                switch e {
                case .apple: break
                case .parakeet:
                    _ = try await AsrModels.download(to: Self.parakeetFolder, version: .v3) { p in
                        Task { @MainActor in ModelStore.shared.states[.parakeet] = .downloading(p.fractionCompleted) }
                    }
                case .sensevoice:
                    try await downloadSenseVoice()
                }
                states[e] = Self.isInstalled(e) ? .installed : .failed("The download didn’t complete.")
            } catch {
                states[e] = .failed(error.localizedDescription)
            }
        }
    }

    func remove(_ e: SpeechEngine) {
        // FluidAudio keeps Parakeet in a folder named after its repository, next to ours.
        let dirs = e == .parakeet ? [Self.parakeetFolder, Self.folder.appending(path: "parakeet-tdt-0.6b-v3")]
                                  : [Self.senseVoiceFolder]
        for d in dirs where FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.trashItem(at: d, resultingItemURL: nil)
        }
        refresh()
    }

    func downloadHYMT2() {
        if case .downloading = hymt2 { return }
        hymt2 = .downloading(0)
        Task {
            do {
                try FileManager.default.createDirectory(at: HYMT2.folder, withIntermediateDirectories: true)
                // Hugging Face (or its mirror), then ModelScope (works in mainland China).
                let sources = ["\(Self.hfBase)/tencent/Hy-MT2-1.8B-GGUF/resolve/main/\(HYMT2.fileName)",
                               "https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-1.8B-GGUF/resolve/master/\(HYMT2.fileName)"]
                await Self.chooseMirror()
                var lastError: Error = URLError(.cannotConnectToHost)
                for source in sources {
                    do {
                        let tmp = try await Self.fetch(URL(string: source)!) { p in
                            Task { @MainActor in ModelStore.shared.hymt2 = .downloading(p) }
                        }
                        let magic = try FileHandle(forReadingFrom: tmp).read(upToCount: 4)
                        guard magic == Data("GGUF".utf8) else { throw URLError(.cannotDecodeContentData) }
                        try? FileManager.default.removeItem(at: HYMT2.modelURL)
                        try FileManager.default.moveItem(at: tmp, to: HYMT2.modelURL)
                        hymt2 = .installed
                        return
                    } catch { lastError = error }
                }
                throw lastError
            } catch {
                hymt2 = .failed(error.localizedDescription)
            }
        }
    }

    func removeHYMT2() {
        Task { await HYMT2.shared.unload() }
        try? FileManager.default.trashItem(at: HYMT2.folder, resultingItemURL: nil)
        refresh()
    }

    // MARK: downloads

    private static var hfBase = "https://huggingface.co"

    /// huggingface.co is blocked in mainland China: use its mirror when it can't be reached.
    private static func chooseMirror() async {
        var req = URLRequest(url: URL(string: "https://huggingface.co")!, timeoutInterval: 5)
        req.httpMethod = "HEAD"
        let reachable = (try? await URLSession.shared.data(for: req)) != nil
        hfBase = reachable ? "https://huggingface.co" : "https://hf-mirror.com"
        ModelRegistry.baseURL = hfBase
    }

    private func downloadSenseVoice() async throws {
        let dir = Self.senseVoiceFolder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, name) in Self.senseVoiceFiles.enumerated() {
            let dest = dir.appending(path: name)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            let url = URL(string: "\(Self.hfBase)/\(Self.senseVoiceRepo)/resolve/main/\(name)")!
            let share = 1.0 / Double(Self.senseVoiceFiles.count)
            let tmp = try await Self.fetch(url) { p in
                Task { @MainActor in ModelStore.shared.states[.sensevoice] = .downloading((Double(i) + p) * share) }
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
    }

    /// Downloads to a temporary file, reporting progress (0…1).
    private static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let box = ObservationBox()
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                box.observation?.invalidate()
                if let error { cont.resume(throwing: error); return }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: URLError(.badServerResponse)); return
                }
                // The system deletes `tmp` when this handler returns: move it somewhere we own.
                let keep = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                do { try FileManager.default.moveItem(at: tmp, to: keep); cont.resume(returning: keep) }
                catch { cont.resume(throwing: error) }
            }
            box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }
}

private final class ObservationBox: @unchecked Sendable {
    var observation: NSKeyValueObservation?
}

// MARK: - The models

/// A speech model that transcribes a whole utterance (16 kHz mono samples) at a time.
protocol UtteranceModel: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// NVIDIA Parakeet TDT 0.6B v3 on the Neural Engine (FluidAudio).
actor ParakeetModel: UtteranceModel {
    private let manager = AsrManager(config: .default)

    static func load() async throws -> ParakeetModel {
        let m = ParakeetModel()
        let models = try await AsrModels.load(from: ModelStore.parakeetFolder, version: .v3)
        try await m.manager.loadModels(models)
        return m
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count >= 4_000 else { return "" }               // < 0.25 s
        var state = TdtDecoderState.make()
        return try await manager.transcribe(samples, decoderState: &state, language: .english).text
    }
}

/// Alibaba SenseVoice-Small (int8) on the CPU (sherpa-onnx).
actor SenseVoiceModel: UtteranceModel {
    private let recognizer: SherpaOnnxOfflineRecognizer

    private init(recognizer: SherpaOnnxOfflineRecognizer) { self.recognizer = recognizer }

    static func load() throws -> SenseVoiceModel {
        let dir = ModelStore.senseVoiceFolder
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: dir.appending(path: "model.int8.onnx").path, language: "zh", useInverseTextNormalization: true)
        let model = sherpaOnnxOfflineModelConfig(tokens: dir.appending(path: "tokens.txt").path,
                                                 numThreads: 4, senseVoice: senseVoice)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
                                                       modelConfig: model)
        return SenseVoiceModel(recognizer: SherpaOnnxOfflineRecognizer(config: &config))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count >= 4_000 else { return "" }
        return recognizer.decode(samples: samples, sampleRate: 16_000).text
    }
}
