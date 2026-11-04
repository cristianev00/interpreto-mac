import AVFoundation
import Foundation
import Speech

/// Help → Start Recording for Analysis: saves exactly what the speech recognizer hears (heard.caf),
/// a timeline of events (pauses, recognizer results, sentences, translations and their delay, when
/// the voice speaks, memory) and the transcript (session.json) to a folder on the Desktop.
/// `scripts/analyze-recording.sh <folder>` turns it into a report.
enum Diagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: FileHandle?
    nonisolated(unsafe) private static var audio: AVAudioFile?
    nonisolated(unsafe) private static var t0 = Date()
    nonisolated(unsafe) private(set) static var folder: URL?

    static var isRecording: Bool { lock.withLock { log != nil } }

    static func begin() {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let dir = URL.desktopDirectory.appending(path: "Interpreto Diagnostics/\(stamp)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appending(path: "events.log").path, contents: nil)
        lock.withLock {
            folder = dir
            log = try? FileHandle(forWritingTo: dir.appending(path: "events.log"))
            t0 = Date()
        }
        event("diagnostics started")
        event("input: \(AudioDevices.list(input: true).map(\.name)), output: \(AudioDevices.list(input: false).map(\.name))")
    }

    /// Resident memory of the app, in MB.
    static func memoryMB() -> Double {
        var info = mach_task_basic_info()
        var n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) }
        }
        return Double(info.resident_size) / 1e6
    }

    /// Saves what was heard and translated during the recording.
    static func saveTranscript(_ items: [Utterance], direction: Direction) {
        guard let dir = lock.withLock({ folder }) else { return }
        let rows: [[String: Any]] = items.map {
            ["source": $0.source, "translation": $0.translation, "start": $0.start, "end": $0.end, "notSpoken": $0.notSpoken]
        }
        let doc: [String: Any] = ["direction": direction.rawValue, "items": rows]
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appending(path: "session.json"))
        }
    }

    static func end() {
        event("diagnostics ended")
        lock.withLock {
            try? log?.close()
            log = nil
            audio = nil
        }
    }

    static func event(_ text: String) {
        lock.withLock {
            guard let log else { return }
            let line = String(format: "%7.2f  ", Date().timeIntervalSince(t0)) + text + "\n"
            log.write(Data(line.utf8))
        }
    }

    /// Wraps the recognizer's input so it is also saved to heard.caf while recording.
    static func tap(_ input: AudioStream, format: AVAudioFormat) -> AudioStream {
        guard isRecording, let dir = lock.withLock({ folder }) else { return input }
        let file = try? AVAudioFile(forWriting: dir.appending(path: "heard.caf"), settings: format.settings,
                                    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        lock.withLock { audio = file }
        return AsyncStream { cont in
            let task = Task.detached {
                for await x in input {
                    lock.withLock { try? audio?.write(from: x) }
                    cont.yield(x)
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
