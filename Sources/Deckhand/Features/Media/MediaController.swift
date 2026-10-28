import Foundation
import AppKit
import CoreGraphics

/// Media control through the system media keys,
/// which every player that uses system audio playback responds to:
///
/// Apple Music, Spotify, browsers (YouTube Music, YouTube, SoundCloud), VLC,
/// Yandex Music and so on.
enum MediaKey: Int32 {
    case playPause = 16  // NX_KEYTYPE_PLAY
    case next = 17       // NX_KEYTYPE_NEXT
    case previous = 18   // NX_KEYTYPE_PREVIOUS
    case fast = 19       // NX_KEYTYPE_FAST
    case rewind = 20     // NX_KEYTYPE_REWIND
}

enum MediaController {
    /// Sends a media key press as a low-level system event.
    static func send(_ key: MediaKey) {
        postMediaKey(key: key.rawValue, isDown: true)
        postMediaKey(key: key.rawValue, isDown: false)
    }

    private static func postMediaKey(key: Int32, isDown: Bool) {
        let flags: NSEvent.ModifierFlags = isDown ? [.init(rawValue: 0xa00)] : [.init(rawValue: 0xb00)]
        let data1 = (Int(key) << 16) | ((isDown ? 0xA : 0xB) << 8)
        if let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) {
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
