import SwiftUI
import Translation

/// First run: macOS downloads its English and Chinese speech and translation models (once).
struct SetupView: View {
    @Environment(Readiness.self) private var readiness
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var working = false

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Welcome to Interpreto").font(.largeTitle.weight(.bold))
                Text("Live English ⇄ Chinese translation, entirely on your Mac.\nmacOS needs to download its English and Chinese models once.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                row("Speech recognition", detail: "English and Chinese", ready: readiness.speechReady,
                    progress: readiness.speechProgress, busy: readiness.downloadingSpeech)
                Divider().padding(.leading, 44)
                row("Translation languages", detail: "English and Chinese (Simplified)", ready: readiness.translationReady,
                    progress: nil, busy: translationConfig != nil && !readiness.translationReady)
            }
            .background(.background, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
            .frame(width: 440)

            if let e = readiness.error {
                Text(e).font(.callout).foregroundStyle(.red).frame(width: 440)
            }
            Button {
                Task { await download() }
            } label: {
                Text(working ? "Downloading…" : "Download").frame(minWidth: 140)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(working)
            Text("Downloads come from Apple and stay on this Mac. Nothing you say leaves it.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .translationTask(translationConfig) { session in
            do { try await session.prepareTranslation() }
            catch { readiness.error = "Translation languages: \(error.localizedDescription)" }
            await readiness.check()
            if !readiness.translationReady, translationConfig?.source == Direction.enToZh.sourceLanguage {
                translationConfig = .init(source: Direction.zhToEn.sourceLanguage, target: Direction.zhToEn.targetLanguage)
            } else {
                working = false
            }
        }
    }

    private func download() async {
        working = true
        readiness.error = nil
        if !readiness.speechReady { await readiness.downloadSpeech() }
        if !readiness.translationReady {
            translationConfig = .init(source: Direction.enToZh.sourceLanguage, target: Direction.enToZh.targetLanguage)
        } else {
            working = false
        }
    }

    private func row(_ title: String, detail: String, ready: Bool, progress: Double?, busy: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if ready {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let p = progress, busy {
                    ProgressView(value: p).progressViewStyle(.linear)
                } else {
                    Text(ready ? "Ready" : detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
