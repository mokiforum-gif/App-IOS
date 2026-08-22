import SwiftUI

/// Bruce brand palette, sampled from bruce.computer.
///
/// The site is dark-first with a purple identity: a violet accent (`#9B51E0`)
/// over near-black backgrounds, with brighter violets for highlights and a cool
/// blue as a secondary accent.
enum BruceColor {
    // Purples
    static let purple = Color(hex: 0x9B51E0)      // primary accent (matches AccentColor)
    static let violet = Color(hex: 0xAC4BFF)      // brighter highlight
    static let lilac  = Color(hex: 0xC07EFF)      // soft highlight
    static let deep   = Color(hex: 0x8033C7)      // pressed / deep accent
    static let indigo = Color(hex: 0x4B0082)      // gradient midpoint
    static let plum   = Color(hex: 0x3D0664)      // gradient
    static let grape  = Color(hex: 0x2A0036)      // darkest purple

    // Blues (secondary accent)
    static let azure  = Color(hex: 0x54A2FF)
    static let blue   = Color(hex: 0x3080FF)

    // Neutrals (dark surfaces)
    static let bg      = Color(hex: 0x0F0F14)      // app background
    static let surface = Color(hex: 0x111111)      // cards / panels
    static let surfaceHi = Color(hex: 0x222222)    // raised surface

    /// Signature diagonal background gradient used on the brand site.
    static let backdrop = LinearGradient(
        colors: [grape, plum, bg],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension View {
    /// Dresses a `List`/`Form` screen in the brand chrome: the diagonal gradient
    /// behind the content instead of the system's grouped background.
    ///
    /// Rows still need `.listRowBackground(BruceColor.surface)` — SwiftUI has no
    /// single knob for both, and keeping them separate lets a section opt out
    /// (cards that draw their own background, for instance).
    func bruceScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(BruceColor.backdrop.ignoresSafeArea())
    }
}

extension Color {
    /// RGB components as 0–255 integers — the scale every device color command takes.
    ///
    /// Clamped, because it has to be: the system color picker hands back colors in
    /// the display's wide gamut, and a saturated P3 color converts to *extended*
    /// sRGB, where a component legitimately lands outside 0…1. Sent as-is, the
    /// firmware answers `Invalid value: 262 (expected 0-255)` and changes nothing.
    var rgb255: (r: Int, g: Int, b: Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> Int { min(max(Int((value * 255).rounded()), 0), 255) }
        return (byte(r), byte(g), byte(b))
    }

    /// The same components packed as `0xRRGGBB`.
    ///
    /// Colors are not `Equatable` in any useful way across color spaces, so this is
    /// what the LED screen compares against to tell "the device already has this"
    /// from "this is a change worth sending".
    var hex24: UInt32 {
        let (r, g, b) = rgb255
        return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    /// The color as the display packs it: 5 bits of red, 6 of green, 5 of blue.
    ///
    /// The device's interface color (`priColor`) has exactly this precision, so two
    /// colors that differ only below it are the same color to the Bruce — which is
    /// why the screen section compares here rather than in `hex24`.
    var rgb565: UInt16 {
        let (r, g, b) = rgb255
        return UInt16(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3))
    }

    /// Build a `Color` from a 24-bit RGB hex literal (e.g. `0x9B51E0`).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
