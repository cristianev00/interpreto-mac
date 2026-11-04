import Testing
@testable import Interpreto

@Suite struct VoiceTests {
    @Test func paradeeIdsMapToItsFourVoices() {
        for i in 0..<4 {
            let s = VoicePack.spec(for: "neural:paradee:\(i)")
            #expect(s?.kind == .paradee)
            #expect(s.map(VoicePack.pack(of:)) == .paradee)
        }
        #expect(VoicePack.spec(for: "neural:paradee:4") == nil)
    }

    @Test func removedSupertonicIdsAreNotNaturalVoices() {
        #expect(VoicePack.spec(for: "neural:supertonic:0") == nil)
    }

    @Test func matchaStaysChinese() {
        #expect(VoicePack.spec(for: "neural:matcha")?.language == "zh")
        #expect(VoicePack.spec(for: "com.apple.voice.compact.en-US.Samantha") == nil)
    }
}
