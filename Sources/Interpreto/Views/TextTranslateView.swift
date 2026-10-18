import SwiftUI

/// Type or paste text; it's translated as you type (Apple's translation takes ~50 ms).
struct TextTranslateView: View {
    @Environment(LiveController.self) private var live
    @State private var input = ""
    @State private var output = ""

    var body: some View {
        HStack(spacing: 14) {
            Card(title: live.direction.sourceName) {
                TextEditor(text: $input)
                    .font(.system(size: 17))
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text("Type or paste text").font(.system(size: 17)).foregroundStyle(.tertiary)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } footer: {
                if !input.isEmpty {
                    Button("Clear") { input = "" }.buttonStyle(.borderless)
                }
            }
            Card(title: live.direction.targetName, accent: true) {
                ScrollView {
                    Text(output.isEmpty ? " " : output)
                        .font(.system(size: 17))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                }
            } footer: {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(output.isEmpty)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: "\(live.direction.rawValue)|\(input)") { await translate() }
    }

    private func translate() async {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { output = ""; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(""); continue }
            guard let t = try? await live.translator.translate(line, live.direction, glossary: live.glossary) else { return }
            lines.append(t)
        }
        if !Task.isCancelled { output = lines.joined(separator: "\n") }
    }
}

private struct Card<Content: View, Footer: View>: View {
    let title: String
    var accent = false
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            content.frame(maxHeight: .infinity)
            HStack { Spacer(); footer }.frame(height: 24)
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}
