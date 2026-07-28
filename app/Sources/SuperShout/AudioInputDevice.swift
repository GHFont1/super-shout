import AVFoundation
import CoreAudio

/// A microphone Super Shout can bind directly instead of silently following
/// macOS's system default (which is often a webcam even when a USB mic is in
/// front of the user).
struct AudioInputDevice: Identifiable, Hashable {
    let id: String       // Core Audio device UID
    let name: String

    static func available() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func systemDefaultName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return name(for: deviceID)
    }

    /// Applies a saved Core Audio UID to this engine. Returns the device name
    /// for logging, or nil when the UID disappeared (unplugged USB mic).
    static func apply(uid: String, to engine: AVAudioEngine) -> String? {
        guard !uid.isEmpty, let deviceID = deviceID(for: uid) else { return nil }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
            return name(for: deviceID)
        } catch {
            Log.write("microphone selection failed uid=\(uid): \(error.localizedDescription)")
            return nil
        }
    }

    private static func deviceID(for uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: CFString = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uidRef) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID
            )
        }
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func name(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, valuePointer)
        }
        guard status == noErr, let value else {
            return nil
        }
        // Core Audio documents kAudioObjectPropertyName as caller-released.
        return value.takeRetainedValue() as String
    }
}
