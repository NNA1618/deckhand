import CoreAudio
import Foundation

/// Mute of the default output device through CoreAudio.
///
/// AppleScript's `output muted` goes through the same property but needs an Apple Event round trip
/// and can stall; CoreAudio answers in microseconds and tells us when anything else changes it.
/// Some outputs (HDMI, some USB interfaces) have no mute control; then `isMuted` is nil.
@MainActor
final class SystemMute {
    /// Called on the main actor when the output device or its mute state changes.
    var onChange: () -> Void = {}

    private var device: AudioObjectID = kAudioObjectUnknown
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    /// The element that carries mute on the current device: main, or the first channel on devices without a main control.
    private var muteElement: AudioObjectPropertyElement = kAudioObjectPropertyElementMain

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    /// Starts following the default output device. Safe to call more than once.
    func start() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.attach()
                self?.onChange()
            }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, listener)
        attach()
    }

    /// Whether the output is muted, or nil when the device has no mute control.
    var isMuted: Bool? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = Self.muteAddress(muteElement)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    /// Mutes or unmutes. Returns false when the device refuses or can't be muted.
    func setMuted(_ muted: Bool) -> Bool {
        if device == kAudioObjectUnknown { attach() }
        guard device != kAudioObjectUnknown else { return false }
        var ok = false
        // Devices without a main mute control have one per channel; set them all
        for element in elements() {
            var address = Self.muteAddress(element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            ok = ok || status == noErr
            if element == kAudioObjectPropertyElementMain && status == noErr { break }
        }
        return ok
    }

    /// Follows the current default output device and listens to its mute property.
    private func attach() {
        detachMute()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, 0, nil, &size, &id)
        device = status == noErr ? id : kAudioObjectUnknown
        guard device != kAudioObjectUnknown else { return }
        muteElement = elements().first { element in
            var address = Self.muteAddress(element)
            return AudioObjectHasProperty(device, &address)
        } ?? kAudioObjectPropertyElementMain
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange() }
        }
        muteListener = listener
        var address = Self.muteAddress(muteElement)
        AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
    }

    private func detachMute() {
        guard let muteListener, device != kAudioObjectUnknown else { return }
        var address = Self.muteAddress(muteElement)
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, muteListener)
        self.muteListener = nil
    }

    /// Main first, then the first two channels (left and right).
    private func elements() -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain, 1, 2]
    }
}
