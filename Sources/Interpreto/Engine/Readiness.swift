import Foundation
import Observation
import Speech

/// First-run check: Apple's speech models and translation languages for English and Chinese.
/// Both are downloaded by macOS itself (once), never bundled with the app.
@MainActor
@Observable
final class Readiness {
    private(set) var checked = false
    private(set) var speechReady = false
    private(set) var translationReady = false
    private(set) var speechProgress: Double?
    private(set) var downloadingSpeech = false
    var error: String?

    var ready: Bool { speechReady && translationReady }

    func check() async {
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        var speech = true
        for d in Direction.allCases {
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: d.speechLocale) else { speech = false; continue }
            if !installed.contains(loc.identifier(.bcp47)) { speech = false }
        }
        speechReady = speech
        translationReady = await Translator.isInstalled()
        checked = true
    }

    func downloadSpeech() async {
        guard !downloadingSpeech else { return }
        downloadingSpeech = true
        error = nil
        defer { downloadingSpeech = false; speechProgress = nil }
        do {
            let modules = Direction.allCases.map {
                SpeechTranscriber(locale: $0.speechLocale, preset: .transcription)
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                let progress = request.progress
                let poll = Task { @MainActor in
                    while !Task.isCancelled {
                        speechProgress = progress.fractionCompleted
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
                defer { poll.cancel() }
                try await request.downloadAndInstall()
            }
        } catch {
            self.error = error.localizedDescription
        }
        await check()
    }
}
