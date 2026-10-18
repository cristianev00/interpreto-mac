import Foundation
import Translation

/// Apple's on-device translation. Glossary terms are swapped for their translation and marked
/// "don't translate", so they come out exactly as the user wrote them.
@MainActor
final class Translator {
    private var sessions: [Direction: TranslationSession] = [:]

    private func session(_ d: Direction) -> TranslationSession {
        if let s = sessions[d] { return s }
        let s = TranslationSession(installedSource: d.sourceLanguage, target: d.targetLanguage,
                                   preferredStrategy: .lowLatency)
        sessions[d] = s
        return s
    }

    func translate(_ text: String, _ d: Direction, glossary: Glossary) async throws -> String {
        let input = Self.applyGlossary(text, terms: glossary.terms(for: d))
        let response = try await session(d).translate(input)
        var out = response.targetText
        // Apple's translator occasionally answers in Traditional characters; keep Simplified.
        if d == .enToZh { out = out.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? out }
        return tidy(out)
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
