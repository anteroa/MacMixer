import CoreAudio
import Foundation

/// Thin, typed wrappers around the C-style Core Audio property API.
enum CA {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(id, &addr)
    }

    static func isSettable(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Reads a fixed-size value (UInt32, Float32, pid_t, AudioObjectID, ...).
    static func get<T>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        initial: T
    ) -> T? {
        var addr = address(selector, scope: scope, element: element)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return err == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        value: T
    ) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        var v = value
        let err = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
        return err == noErr
    }

    static func objectIDs(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    static func string(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: - Devices

    static var defaultOutputDevice: AudioDeviceID? {
        let id = get(AudioObjectID(kAudioObjectSystemObject),
                     kAudioHardwarePropertyDefaultOutputDevice,
                     initial: AudioDeviceID(kAudioObjectUnknown))
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioDeviceID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    static func streamCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        objectIDs(device, kAudioDevicePropertyStreams, scope: scope).count
    }
}

/// Owns a property listener block so it can be removed later.
final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init?(objectID: AudioObjectID,
          address: AudioObjectPropertyAddress,
          queue: DispatchQueue = .main,
          handler: @escaping () -> Void) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        let err = AudioObjectAddPropertyListenerBlock(objectID, &self.address, queue, block)
        if err != noErr { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}
