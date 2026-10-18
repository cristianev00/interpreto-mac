import AVFoundation
import Foundation
import Speech

/// Help → Record Diagnostics: saves 30 seconds of exactly what the speech recognizer hears, plus a
/// timeline of events (pauses, recognizer results, sentences, when the voice speaks), to a folder
/// on the Desktop. Used to see what happens on a real Mac in a real room.
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
