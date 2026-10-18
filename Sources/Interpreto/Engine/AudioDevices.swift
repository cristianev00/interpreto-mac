import AVFoundation
import CoreAudio

/// A microphone or speaker, identified by its stable Core Audio UID (saved in settings).
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func list(input: Bool) -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard channels(id, input: input) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func id(forUID uid: String?, input: Bool) -> AudioDeviceID? {
        guard let uid, !uid.isEmpty else { return nil }
        return list(input: input).first { $0.uid == uid }?.id
    }

    /// Points an AVAudioEngine input or output node at a specific device (nil = system default).
    static func route(_ node: AVAudioIONode, to device: AudioDeviceID?) {
        guard var dev = device, let unit = node.audioUnit else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    // MARK: what kind of device is it

    static func defaultUID(input: Bool) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return list(input: input).first { $0.id == id }?.uid
    }

    private static func transport(_ uid: String, input: Bool) -> UInt32? {
        guard let id = self.id(forUID: uid, input: input) else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var t = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr ? t : nil
    }

    private static func name(_ uid: String, input: Bool) -> String {
        list(input: input).first { $0.uid == uid }?.name.lowercased() ?? ""
    }

    /// True if sound from this output fills the room (so a microphone hears it): the Mac's
    /// speakers or a display's / external speakers; not headphones, AirPods or a virtual cable.
    static func isLoudspeaker(_ uid: String?) -> Bool {
        guard let uid else { return false }
        let n = name(uid, input: false)
        if ["headphone", "airpods", "headset", "earphone", "buds", "blackhole", "teams", "zoom", "virtual", "loopback"]
            .contains(where: n.contains) { return false }
        switch transport(uid, input: false) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return false
        default: return true
        }
    }

    /// True for microphones worn close to the mouth (AirPods, Bluetooth or USB headsets).
    static func isHeadset(_ uid: String?) -> Bool {
        guard let uid else { return false }
        let n = name(uid, input: true)
        if ["airpods", "headset", "headphone", "earphone", "buds"].contains(where: n.contains) { return true }
        let t = transport(uid, input: true)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Whether a spoken translation is playing (or just finished: the room still echoes for a
/// moment). Read from the audio threads, so it's lock-protected.
final class PlaybackState: @unchecked Sendable {
    static let shared = PlaybackState()
    private let lock = NSLock()
    private var playingUntil = Date.distantPast

    /// Called while audio is queued; `remaining` seconds are still to play.
    func playing(remaining: Double) {
        lock.withLock { playingUntil = max(playingUntil, Date().addingTimeInterval(remaining + 0.35)) }
    }
    func stopped() { lock.withLock { playingUntil = Date().addingTimeInterval(0.35) } }
    var isActive: Bool { lock.withLock { Date() < playingUntil } }
}
