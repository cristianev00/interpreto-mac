import Foundation

/// The only two directions Interpreto translates.
enum Direction: String, Codable, CaseIterable, Identifiable {
    case enToZh = "en"
    case zhToEn = "zh"

    var id: String { rawValue }
    var reversed: Direction { self == .enToZh ? .zhToEn : .enToZh }

    /// Locale for speech recognition.
    var speechLocale: Locale { Locale(identifier: self == .enToZh ? "en_US" : "zh_CN") }
    var sourceLanguage: Locale.Language { Locale.Language(identifier: self == .enToZh ? "en" : "zh-Hans") }
    var targetLanguage: Locale.Language { Locale.Language(identifier: self == .enToZh ? "zh-Hans" : "en") }
    /// BCP-47 code of the spoken translation's language.
    var targetVoiceLanguage: String { self == .enToZh ? "zh-CN" : "en-US" }

    var sourceName: String { self == .enToZh ? "English" : "中文" }
    var targetName: String { self == .enToZh ? "中文" : "English" }
    var label: String { "\(sourceName) → \(targetName)" }
}

/// One finished sentence of a live session.
struct Utterance: Identifiable, Codable, Hashable {
    var id = UUID()
    var source: String
    var translation: String = ""
    var start: Double            // seconds since the session started
    var end: Double
    var isTranslating = true
    var notSpoken = false
}

/// A saved live session.
struct Session: Identifiable, Codable, Hashable {
    var id = UUID()
    var started = Date()
    var direction: Direction
    var items: [Utterance] = []

    var duration: Double { items.last?.end ?? 0 }
}

/// Glossary: one `English = 中文` pair per line, used in both directions.
struct Glossary {
    var pairs: [(en: String, zh: String)]

    init(text: String) {
        pairs = text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: { "=→\t".contains($0) })
            guard parts.count == 2 else { return nil }
            let en = parts[0].trimmingCharacters(in: .whitespaces)
            let zh = parts[1].trimmingCharacters(in: .whitespaces)
            return en.isEmpty || zh.isEmpty ? nil : (en, zh)
        }
    }

    /// (source term, its translation) for a direction, longest source first so phrases win.
    func terms(for d: Direction) -> [(String, String)] {
        pairs.map { d == .enToZh ? ($0.en, $0.zh) : ($0.zh, $0.en) }
            .sorted { $0.0.count > $1.0.count }
    }

    /// Words the speech recognizer should expect.
    func vocabulary(for d: Direction) -> [String] {
        pairs.map { d == .enToZh ? $0.en : $0.zh }
    }
}

/// Settings keys, shared by the settings window (@AppStorage) and the engines (UserDefaults).
enum Pref {
    static let direction = "direction"
    static let micUID = "micUID"
    static let speak = "speak"
    static let voiceZH = "voiceZH"
    static let voiceEN = "voiceEN"
    static let outputUID = "outputUID"
    static let textSize = "textSize"
    static let showOriginal = "showOriginal"
    static let livePreview = "livePreview"
    static let glossary = "glossary"

    static func register() {
        UserDefaults.standard.register(defaults: [
            direction: Direction.enToZh.rawValue, speak: false, textSize: 24.0,
            showOriginal: true, livePreview: true, glossary: "",
        ])
    }
}

/// Tidies Apple's Chinese output: no spaces between Chinese characters or before Chinese punctuation.
func tidy(_ s: String) -> String {
    var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let re = try? NSRegularExpression(pattern: "(?<=[\\p{Han}，。！？、；：“‘（])\\s+(?=[\\p{Han}“‘（])|\\s+(?=[，。！？、；：”’）])") {
        out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
    }
    return out
}
