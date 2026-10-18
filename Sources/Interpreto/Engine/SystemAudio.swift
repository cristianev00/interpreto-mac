import AppKit
import AVFoundation
import CoreAudio

/// What Interpreto listens to.
enum ListenSource: Hashable {
    case microphone
    case allApps                 // everything playing on the Mac, except Interpreto's own voice
    case app(String)             // one app, by bundle identifier (Zoom, Safari…)

    /// Stored in settings as "mic", "all" or "app:<bundle id>".
    init(_ raw: String?) {
        switch raw ?? "mic" {
        case "all": self = .allApps
        case let s where s.hasPrefix("app:"): self = .app(String(s.dropFirst(4)))
        default: self = .microphone
        }
    }
    var raw: String {
        switch self {
        case .microphone: "mic"
        case .allApps: "all"
        case .app(let id): "app:\(id)"
        }
    }
}

/// An app that can be listened to.
struct AudioApp: Identifiable, Hashable {
    let id: String               // bundle identifier
    let name: String
    let playing: Bool            // producing sound right now
}

/// Captures sound from other apps with a Core Audio process tap (macOS 14.4+; "Audio Recording"
/// permission). Interpreto's own process is always excluded, so the spoken translation is never
/// heard and translated again.
final class SystemAudio {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "interpreto.system-audio")

    /// Apps known to Core Audio, those playing sound first.
    static func apps() -> [AudioApp] {
        var seen = Set<String>()
        var out: [AudioApp] = []
        for obj in processObjects() {
            guard let bundle = stringProperty(obj, kAudioProcessPropertyBundleID), !bundle.isEmpty,
                  bundle != Bundle.main.bundleIdentifier, !seen.contains(bundle) else { continue }
            let pid: pid_t = scalarProperty(obj, kAudioProcessPropertyPID) ?? 0
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let name = app.localizedName else { continue }
            seen.insert(bundle)
            let playing: UInt32 = scalarProperty(obj, kAudioProcessPropertyIsRunningOutput) ?? 0
            out.append(AudioApp(id: bundle, name: name, playing: playing != 0))
        }
        return out.sorted { ($0.playing ? 0 : 1, $0.name) < ($1.playing ? 0 : 1, $1.name) }
    }

    /// Starts capturing; hands mono-or-stereo float buffers (the tap's own format) to `onBuffer`.
    func start(_ source: ListenSource, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description: CATapDescription
        switch source {
        case .microphone:
            return
        case .allApps:
            let me = Self.processObject(pid: getpid()).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
        case .app(let bundle):
            let objects = Self.processObjects().filter { Self.stringProperty($0, kAudioProcessPropertyBundleID) == bundle }
            guard !objects.isEmpty else { throw Self.error("That app isn’t running or hasn’t played sound yet.") }
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted          // the user keeps hearing the original
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            throw Self.error("Interpreto needs permission to record the Mac’s sound (System Settings → Privacy & Security → Screen & System Audio Recording). [\(status)]")
        }
        tapID = tap

        // A private aggregate device that contains the tap, clocked by the default output.
        let outputUID = AudioDevices.defaultUID(input: false) ?? ""
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Interpreto Listen",
            kAudioAggregateDeviceUIDKey: "com.interpreto.listen.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                              kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw Self.error("Couldn’t start listening to the Mac’s sound. [\(status)]") }

        guard var asbd: AudioStreamBasicDescription = Self.scalarProperty(tapID, kAudioTapPropertyFormat),
              let format = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw Self.error("Couldn’t read the sound format.")
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            let frames = AVAudioFrameCount(input.pointee.mBuffers.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame)
            guard frames > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            pcm.frameLength = frames
            copy.frameLength = frames
            // Copy out of the real-time buffer, deinterleaving to channel 0 if needed.
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (s, d) in zip(src, dst) where s.mData != nil && d.mData != nil {
                memcpy(d.mData!, s.mData!, Int(min(s.mDataByteSize, d.mDataByteSize)))
            }
            onBuffer(copy)
        }
        guard status == noErr else { stop(); throw Self.error("Couldn’t start listening to the Mac’s sound. [\(status)]") }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw Self.error("Couldn’t start listening to the Mac’s sound. [\(status)]") }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Core Audio helpers

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Interpreto", code: 30, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var p = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
        return status == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    private static func stringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func scalarProperty<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.pointee
    }
}
