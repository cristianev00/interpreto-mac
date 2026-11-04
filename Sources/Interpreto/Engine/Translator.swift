import Foundation
import Translation

/// Apple's on-device translation. Glossary terms are swapped for their translation and marked
/// "don't translate", so they come out exactly as the user wrote them.
@MainActor
final class Translator {
    private var sessions: [Direction: TranslationSession] = [:]

    /// Low latency when its model is on this Mac, otherwise high fidelity. The language packs can be
    /// "installed" while the low-latency model is only "supported": a low-latency session then fails
    /// every sentence with "Unable to Translate" (TranslationError.notInstalled).
    private func session(_ d: Direction) async -> TranslationSession {
        if let s = sessions[d] { return s }
        let fast = await LanguageAvailability(preferredStrategy: .lowLatency)
            .status(from: d.sourceLanguage, to: d.targetLanguage) == .installed
        let s = TranslationSession(installedSource: d.sourceLanguage, target: d.targetLanguage,
                                   preferredStrategy: fast ? .lowLatency : .highFidelity)
        sessions[d] = s
        return s
    }

    private func appleTranslate(_ input: AttributedString, _ d: Direction) async throws -> String {
        do {
            return try await session(d).translate(input).targetText
        } catch TranslationError.notInstalled where sessions[d]?.preferredStrategy == .lowLatency {
            let s = TranslationSession(installedSource: d.sourceLanguage, target: d.targetLanguage,
                                       preferredStrategy: .highFidelity)
            sessions[d] = s
            return try await s.translate(input).targetText
        }
    }

    /// - context: the previous sentences (used by HY-MT2 for consistent wording)
    /// - quick: the live preview while someone is still speaking; always Apple's, the fastest
    func translate(_ text: String, _ d: Direction, glossary: Glossary,
                   context: [String] = [], quick: Bool = false) async throws -> String {
        if d == .enToZh, !quick, Self.usesHYMT2 {
            let terms = glossary.terms(for: d).filter { text.range(of: $0.0, options: .caseInsensitive) != nil }
            if let out = try? await HYMT2.shared.translate(text, d, context: context, terms: terms), !out.isEmpty {
                return tidy(out.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? out)
            }
        }
        let input = Self.applyGlossary(text, terms: glossary.terms(for: d))
        var out = try await appleTranslate(input, d)
        // Apple's translator occasionally answers in Traditional characters; keep Simplified.
        if d == .enToZh { out = out.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? out }
        return tidy(out)
    }

    /// English → Chinese with HY-MT2, if chosen in Settings and downloaded.
    static var usesHYMT2: Bool {
        UserDefaults.standard.string(forKey: Pref.translatorZH) == "hymt2" && HYMT2.isInstalled
    }

    static func applyGlossary(_ text: String, terms: [(String, String)]) -> AttributedString {
        var out = AttributedString(text)
        guard !terms.isEmpty else { return out }
        for (term, replacement) in terms {
            var searchFrom = out.startIndex
            while let r = out[searchFrom...].range(of: term, options: [.caseInsensitive]) {
                if out[r].translation.skipsTranslation == true { searchFrom = r.upperBound; continue }
                var rep = AttributedString(replacement)
                rep.translation.skipsTranslation = true
                let offset = out.characters.distance(from: out.startIndex, to: r.lowerBound)
                out.replaceSubrange(r, with: rep)
                searchFrom = out.characters.index(out.startIndex, offsetBy: offset + replacement.count)
            }
        }
        return out
    }

    /// True when both language packs are on this Mac.
    static func isInstalled() async -> Bool {
        let a = LanguageAvailability()
        for d in Direction.allCases where await a.status(from: d.sourceLanguage, to: d.targetLanguage) != .installed {
            return false
        }
        return true
    }
}
