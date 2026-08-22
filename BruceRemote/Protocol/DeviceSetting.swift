import SwiftUI

/// A field of the device's config, as named by `BruceConfig::toJson`.
///
/// `settings <name>` answers `name = value` on the active serial device, which is
/// the only way to read the device's current state back: the firmware has no
/// getter for the LED or the interface color, and the LED menu is not reflected in
/// any other output. Reading these is what lets a screen show what the Bruce is
/// actually set to instead of what the app happens to remember.
enum DeviceSetting: String {
    /// LED color, `RRGGBB` in hex (`String(ledColor, HEX)`, leading zeros dropped).
    case ledColor
    /// LED brightness, 0–100.
    case ledBright
    /// LED effect index — see `LEDEffect`.
    case ledEffect
    /// Interface accent color, hex, in the display's own **RGB565** packing.
    case priColor
    /// Backlight, 0–100. Note `screen brightness` changes the backlight without
    /// saving, so this reads the stored value, not necessarily the live one.
    case bright

    /// The raw text after `name = `, or nil when the reply did not carry the field
    /// (an older firmware, or a field name it rejected as invalid).
    func value(in lines: [String]) -> String? {
        let prefix = "\(rawValue) ="
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(prefix) else { continue }
            let value = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    func intValue(in lines: [String]) -> Int? {
        value(in: lines).flatMap(Int.init)
    }

    /// True when the device answered that the field does not exist.
    ///
    /// This is how missing hardware announces itself: `BruceConfig::toJson` only
    /// carries the `led*` fields inside `#ifdef HAS_RGB_LED`, so a board without an
    /// RGB LED rejects the name outright. Worth telling apart from "no answer",
    /// which is just a dropped reply.
    func isRejected(in lines: [String]) -> Bool {
        let rejection = "Invalid field name: \(rawValue)"
        return lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(rejection) }
    }

    /// The value read as hex. Both color fields are serialized with Arduino's
    /// `String(value, HEX)`, which drops leading zeros — harmless, since what is
    /// parsed is the number, not a fixed-width digit pair per channel.
    func hexValue(in lines: [String]) -> UInt32? {
        value(in: lines).flatMap { UInt32($0, radix: 16) }
    }
}
