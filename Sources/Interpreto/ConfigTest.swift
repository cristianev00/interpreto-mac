import AVFoundation
import Foundation

/// `--configtest` (run inside the app so it has the microphone permission): goes through every
/// microphone × output × voice on/off combination connected to this Mac, plus switching devices
/// while listening and quick start/stop cycles. Writes
/// ~/Desktop/Interpreto Diagnostics/configtest.txt. Settings are restored afterwards.
@MainActor
enum ConfigTest {
    static let report = URL.desktopDirectory.appending(path: "Interpreto Diagnostics/configtest.txt")
    private static var failures = 0

    private static func note(_ t: String) {
        print(t)
        try? FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((t + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: report) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: report) }
    }

    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        note("    \(ok ? "✓" : "✗ FAIL") \(what)")
    }

    /// Waits until `condition` holds (or the timeout passes); returns the seconds it took.
    private static func wait(_ timeout: Double, _ condition: () -> Bool) async -> Double? {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if condition() { return Date().timeIntervalSince(t0) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition() ? timeout : nil
    }

    private(set) static var running = false

    static func run(_ live: LiveController) async {
        guard !running else { return }
        running = true
        failures = 0
        if live.isListening { live.stop(); _ = await wait(4, { !live.isListening }) }
        try? FileManager.default.removeItem(at: report)
        let d = UserDefaults.standard
        let saved = [Pref.micUID, Pref.outputUID, Pref.speak, Pref.listenSource, "micName", "outputName"]
            .map { ($0, d.object(forKey: $0)) }
        defer {
            for (k, v) in saved { d.set(v, forKey: k) }
        }
        let monitor = DeviceMonitor.shared
        monitor.refresh()
        note("Interpreto configuration test — \(Date().formatted())")
        note("Direction \(live.direction.label), speech engine \(live.engineName)")
        note("Inputs:  " + monitor.inputs.map { "\($0.name) [\(AudioDevices.kind($0))]" }.joined(separator: ", "))
        note("Outputs: " + monitor.outputs.map { "\($0.name) [\(AudioDevices.kind($0))]" }.joined(separator: ", "))
        note("Default: \(monitor.name(monitor.defaultInput, input: true) ?? "-") → \(monitor.name(monitor.defaultOutput, input: false) ?? "-")")
        note("Please stay quiet during the test: any sentence heard while the voice plays counts as an echo.\n")

        Diagnostics.begin()
        defer { Diagnostics.end() }
        // Warm up: the first start after installing a new build compiles the speech model.
        UserDefaults.standard.set(false, forKey: Pref.speak)
        live.listen(to: .microphone, mic: "")
        let t0 = Date()
        live.start()
        _ = await wait(120, { live.isListening })
        note(String(format: "Warm-up start: %.1f s (includes loading the speech model)\n", Date().timeIntervalSince(t0)))
        live.stop()
        _ = await wait(4, { !live.isListening })
        try? await Task.sleep(for: .seconds(1))

        let inputs = [""] + monitor.inputs.map(\.uid)
        let outputs = [""] + monitor.outputs.map(\.uid)
        for mic in inputs {
            for out in outputs {
                for speak in [false, true] where speak || out == "" {   // the output only matters with the voice on
                    await single(live, mic: mic, out: out, speak: speak)
                }
            }
        }
        await switching(live, inputs: inputs, outputs: outputs)
        await macSound(live)
        await cycles(live)
        note("\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED CHECK(S)")")
        running = false
    }

    private static func name(_ uid: String, input: Bool) -> String {
        uid.isEmpty ? "Default" : DeviceMonitor.shared.name(uid, input: input) ?? uid
    }

    /// Starts listening and checks that sound arrives; returns false if listening didn't start.
    private static func startAndCheck(_ live: LiveController) async -> Bool {
        live.start()
        guard let took = await wait(10, { live.isListening && !live.isStarting }) else {
            check(false, "listening started (\(live.message ?? "no error shown"))")
            live.message = nil
            _ = await wait(30, { !live.isStarting })      // don't let a late start leak into the next case
            if live.isListening { live.stop(); _ = await wait(4, { !live.isListening }) }
            return false
        }
        check(true, String(format: "listening started in %.2f s", took))
        let before = live.mic.buffersReceived
        try? await Task.sleep(for: .seconds(1.5))
        let got = live.mic.buffersReceived - before
        check(got > 10 && live.isListening, "sound arrives (\(got) buffers in 1.5 s)")
        return true
    }

    private static func stopAndCheck(_ live: LiveController) async {
        live.stop()
        let took = await wait(4, { !live.isListening && !live.mic.engine.isRunning })
        check(took != nil, took.map { String(format: "stopped in %.2f s", $0) } ?? "stopped (engine still running)")
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func single(_ live: LiveController, mic: String, out: String, speak: Bool) async {
        UserDefaults.standard.set(speak, forKey: Pref.speak)
        live.listen(to: .microphone, mic: mic)
        live.setOutput(out)
        let plan = live.audioPlan()
        note("• \(name(mic, input: true)) → \(speak ? name(out, input: false) : "voice off")")
        note("    plan: protection \(plan.protection), echo cancellation \(plan.echo)")
        guard await startAndCheck(live) else { return }
        if speak {
            let items = live.session.items.count
            let muted = live.mic.buffersMuted
            let zh = live.direction.targetVoiceLanguage == "zh-CN"
            let text = zh ? "这是一个测试句子，用来检查麦克风会不会听到翻译的声音。"
                          : "This is a test sentence, to check whether the microphone hears the spoken translation."
            // Room level with the voice silent, then while it plays.
            func average(_ seconds: Double) async -> Double {
                var sum = 0.0, n = 0.0
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { sum += Double(live.level); n += 1; try? await Task.sleep(for: .milliseconds(40)) }
                return sum / max(n, 1)
            }
            let baseline = await average(1)
            var started = false
            _ = live.speaker.speak(text, language: live.direction.targetVoiceLanguage,
                                   voiceID: UserDefaults.standard.string(forKey: zh ? Pref.voiceZH : Pref.voiceEN),
                                   outputUID: out, onStart: { started = true })
            let began = await wait(6, { started })
            check(began != nil, began.map { String(format: "voice played (started after %.2f s)", $0) } ?? "voice played")
            var during = 0.0, samples = 0.0
            while live.speaker.isSpeaking, samples < 400 {
                during += Double(live.level); samples += 1
                try? await Task.sleep(for: .milliseconds(40))
            }
            during /= max(samples, 1)
            note(String(format: "    · mic level: room %.4f, while the voice plays %.4f", baseline, during))
            try? await Task.sleep(for: .seconds(1.5))     // let a sentence the mic might have heard finish
            let heard = live.session.items.dropFirst(items).map(\.source)
            // (People talking in the room are heard too, so sentences alone don't prove an echo.)
            note("    · sentences heard during the voice: \(heard.isEmpty ? "none" : heard.joined(separator: " / "))")
            if plan.protection && plan.echo {
                // The voice reaches this Mac's microphone at about 0.04; what's left after echo
                // cancellation must be far below that (too quiet to be recognized).
                check(during < max(baseline * 3, 0.012),
                      String(format: "echo cancellation keeps the voice out of the microphone (left: %.4f)", during))
            } else if plan.protection {
                check(live.mic.buffersMuted > muted, "microphone paused while the voice played (\(live.mic.buffersMuted - muted) buffers)")
            }
            check(live.isListening, "still listening after the voice")
        }
        await stopAndCheck(live)
    }

    /// Changing devices and the voice while listening.
    private static func switching(_ live: LiveController, inputs: [String], outputs: [String]) async {
        note("\n• Switching while listening")
        UserDefaults.standard.set(false, forKey: Pref.speak)
        live.listen(to: .microphone, mic: "")
        live.setOutput("")
        guard await startAndCheck(live) else { return }
        for mic in inputs.dropFirst() + [""] {
            live.listen(to: .microphone, mic: mic)
            try? await Task.sleep(for: .milliseconds(200))
            let ok = await wait(8, { live.isListening && live.activePlan == live.audioPlan() }) != nil
            let before = live.mic.buffersReceived
            try? await Task.sleep(for: .seconds(1))
            check(ok && live.mic.buffersReceived > before, "switched microphone to \(name(mic, input: true)), sound arrives")
        }
        UserDefaults.standard.set(true, forKey: Pref.speak)
        live.speakingChanged(true)
        let on = await wait(8, { live.isListening && live.activePlan == live.audioPlan() }) != nil
        check(on, "voice turned on while listening (plan: protection \(live.audioPlan().protection))")
        for out in outputs.dropFirst() + [""] {
            live.setOutput(out)
            try? await Task.sleep(for: .milliseconds(200))
            let ok = await wait(8, { live.isListening && live.activePlan == live.audioPlan() }) != nil
            check(ok, "switched output to \(name(out, input: false)) (protection \(live.audioPlan().protection), echo \(live.audioPlan().echo))")
        }
        UserDefaults.standard.set(false, forKey: Pref.speak)
        live.speakingChanged(false)
        let off = await wait(8, { live.isListening && live.activePlan == live.audioPlan() }) != nil
        check(off, "voice turned off while listening")
        await stopAndCheck(live)
    }

    private static func macSound(_ live: LiveController) async {
        note("\n• This Mac’s sound")
        live.listen(to: .allApps)
        live.start()
        if await wait(10, { live.isListening && !live.isStarting }) != nil {
            // Core Audio only delivers the Mac's sound while something plays: play a sentence.
            let items = live.session.items.count
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["Testing what Interpreto hears from this Mac."]
            try? say.run()
            say.waitUntilExit()
            try? await Task.sleep(for: .seconds(2))
            let heard = live.session.items.dropFirst(items).map(\.source).joined(separator: " ")
            check(live.mic.buffersReceived > 50, "sound arrives (\(live.mic.buffersReceived) buffers)")
            check(heard.lowercased().contains("interpreto") || heard.lowercased().contains("this mac"),
                  "heard the Mac’s sound: “\(heard)”")
            live.listen(to: .microphone)
            let back = await wait(8, { live.isListening && live.activePlan?.source == .microphone }) != nil
            check(back, "switched back to the microphone while listening")
            await stopAndCheck(live)
        } else {
            check(false, "listening to the Mac’s sound started")
            live.listen(to: .microphone)
        }
    }

    private static func cycles(_ live: LiveController) async {
        note("\n• Start/stop 5 times quickly")
        live.listen(to: .microphone, mic: "")
        for i in 1...5 {
            live.start()
            let up = await wait(8, { live.isListening })
            try? await Task.sleep(for: .milliseconds(500))
            let flowing = live.mic.buffersReceived > 0
            live.stop()
            let down = await wait(4, { !live.isListening && !live.mic.engine.isRunning })
            check(up != nil && flowing && down != nil,
                  String(format: "cycle %d: start %.2f s, sound %@, stop %.2f s", i, up ?? -1, flowing ? "yes" : "no", down ?? -1))
        }
        // Pressing start twice, and stop twice, must not break anything.
        live.start(); live.start()
        _ = await wait(8, { live.isListening })
        live.stop(); live.stop()
        _ = await wait(4, { !live.isListening })
        live.start()
        let again = await wait(8, { live.isListening }) != nil
        try? await Task.sleep(for: .seconds(1))
        check(again && live.mic.buffersReceived > 10, "double start / double stop, then start works")
        await stopAndCheck(live)
    }
}
