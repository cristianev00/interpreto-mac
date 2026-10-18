import AppKit
import Observation
import UniformTypeIdentifiers

/// Saved sessions, one JSON file each in ~/Library/Application Support/Interpreto/History.
@MainActor
@Observable
final class HistoryStore {
    private(set) var sessions: [Session] = []
    private let folder: URL

    init() {
        folder = URL.applicationSupportDirectory.appending(path: "Interpreto/History", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        sessions = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Session.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    func save(_ s: Session) {
        guard !s.items.isEmpty else { return }
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.insert(s, at: 0) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(s).write(to: file(s), options: .atomic)
    }

    func delete(_ s: Session) {
        sessions.removeAll { $0.id == s.id }
        try? FileManager.default.trashItem(at: file(s), resultingItemURL: nil)
    }

    private func file(_ s: Session) -> URL { folder.appending(path: "\(s.id.uuidString).json") }
}

/// Word, plain text and subtitle exports.
enum ExportFormat: String, CaseIterable, Identifiable {
    case docx, txt, srt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .docx: "Word Document"
        case .txt: "Plain Text"
        case .srt: "Subtitles (SRT)"
        }
    }
    var type: UTType { UTType(filenameExtension: rawValue) ?? .data }
}

@MainActor
enum Exporter {
    static func title(_ s: Session) -> String {
        "Interpreto " + s.started.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
    }

    static func data(_ s: Session, _ f: ExportFormat) -> Data? {
        switch f {
        case .txt:
            let body = s.items.map { "\($0.source)\n\($0.translation)" }.joined(separator: "\n\n")
            return Data("\(title(s))\n\(s.direction.label)\n\n\(body)\n".utf8)
        case .srt:
            func ts(_ t: Double) -> String {
                let ms = Int((t * 1000).rounded())
                return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
            }
            let body = s.items.enumerated().map { i, u in
                "\(i + 1)\n\(ts(u.start)) --> \(ts(max(u.end, u.start + 1)))\n\(u.translation)\n\(u.source)"
            }.joined(separator: "\n\n")
            return Data((body + "\n").utf8)
        case .docx:
            let doc = NSMutableAttributedString()
            let titleFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
            doc.append(NSAttributedString(string: title(s) + "\n", attributes: [.font: titleFont]))
            doc.append(NSAttributedString(string: s.direction.label + "\n\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.gray]))
            for u in s.items {
                doc.append(NSAttributedString(string: u.source + "\n",
                                              attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray]))
                doc.append(NSAttributedString(string: u.translation + "\n\n",
                                              attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            }
            return try? doc.data(from: NSRange(location: 0, length: doc.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        }
    }

    /// Asks where to save, like any Mac app.
    static func export(_ s: Session, as f: ExportFormat) {
        guard !s.items.isEmpty, let data = data(s, f) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title(s)).\(f.rawValue)"
        panel.allowedContentTypes = [f.type]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}
