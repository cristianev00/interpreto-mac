import Foundation
import Testing
@testable import Interpreto

@Suite struct GlossaryTests {
    @Test func parsesEveryLineFormat() {
        let g = Glossary(text: "pointer = 指针\narray → 数组\nmalloc\t分配内存\nbroken line\n = empty")
        #expect(g.pairs.map(\.en) == ["pointer", "array", "malloc"])
        #expect(g.pairs.map(\.zh) == ["指针", "数组", "分配内存"])
    }

    @Test func longestTermComesFirstInBothDirections() {
        let g = Glossary(text: "pointer = 指针\nnull pointer = 空指针")
        #expect(g.terms(for: .enToZh).first?.0 == "null pointer")
        #expect(g.terms(for: .zhToEn).first?.0 == "空指针")
        #expect(g.vocabulary(for: .zhToEn) == ["指针", "空指针"])
    }

    @Test func cProgrammingPackParses() {
        #expect(Glossary(text: TermPacks.cProgramming).pairs.count >= 60)
    }

    @Test @MainActor func glossaryTermsAreMarkedDoNotTranslate() {
        let out = Translator.applyGlossary("A pointer and a Pointer.", terms: [("pointer", "指针")])
        #expect(String(out.characters) == "A 指针 and a 指针.")
        let kept = out.runs.filter { $0.translation.skipsTranslation == true }
        #expect(kept.count == 2)
    }
}

@Suite struct DirectionTests {
    @Test func languagesAreOpposite() {
        #expect(Direction.enToZh.sourceLanguage.minimalIdentifier == "en")
        #expect(Direction.enToZh.targetLanguage == Direction.zhToEn.sourceLanguage)
        #expect(Direction.zhToEn.targetLanguage == Direction.enToZh.sourceLanguage)
    }
}

@Suite struct TidyTests {
    @Test func removesSpacesInsideChinese() {
        #expect(tidy("  你好 世界 ， 再见 。 ") == "你好世界，再见。")
    }

    @Test func keepsSpacesBetweenLatinWords() {
        #expect(tidy("使用 malloc 函数") == "使用 malloc 函数")
    }
}

@Suite struct TermFixerTests {
    let terms = Glossary(text: TermPacks.cProgramming)

    @Test(arguments: [
        ("I call mal lock to get memory.", "malloc"),
        ("This is a bugger overflow.", "buffer overflow"),
    ])
    func fixesEnglishSoundAlikes(heard: String, term: String) {
        let fixed = TermFixer.fix(heard, terms: terms.vocabulary(for: .enToZh), chinese: false)
        #expect(fixed.localizedCaseInsensitiveContains(term), "\(fixed)")
    }

    @Test func fixesChineseSamePinyin() {
        let fixed = TermFixer.fix("出现了断错误", terms: terms.vocabulary(for: .zhToEn), chinese: true)
        #expect(fixed.contains("段错误"), "\(fixed)")
    }

    @Test(arguments: [
        "Let's meet tomorrow at the station.",
        "The weather is really nice today.",
        "我们明天在车站见面。",
    ])
    func leavesOrdinarySentencesAlone(sentence: String) {
        let chinese = sentence.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let vocab = terms.vocabulary(for: chinese ? .zhToEn : .enToZh)
        #expect(TermFixer.fix(sentence, terms: vocab, chinese: chinese) == sentence)
    }
}
