import SwiftUI

/// A named color offered as a one-tap swatch.
///
/// The list below walks the hue wheel in even steps and then adds the neutrals a
/// single LED is actually used for — it is meant to cover "the colors people ask
/// for by name", with the color picker sitting next to it for everything else.
struct ColorSwatch: Identifiable, Hashable {
    /// Already localized: swatches are labels for the eye, and the name only shows
    /// up in the accessibility label and the long-press tooltip.
    let name: String
    let hex: UInt32

    var id: UInt32 { hex }
    var color: Color { Color(hex: hex) }
}

/// A complete look, applied in one tap: what the LED shows, how it animates, and
/// what color the device's interface takes.
///
/// Brightness is deliberately not part of a template. It is the one setting whose
/// wrong value makes the device hard to use (or hard to find in the dark), so it
/// stays where the user left it.
struct LightingTemplate: Identifiable {
    let name: String
    let systemImage: String
    let led: Color
    let effect: LEDEffect
    let screen: Color

    var id: String { name }
}

/// The presets behind the LED & screen screen.
///
/// Computed rather than stored: the names are localized, and a stored value would
/// freeze them in whatever language was current the first time they were touched.
enum LightingPalette {
    static var swatches: [ColorSwatch] {
        [
            ColorSwatch(name: L10n.t("Vermelho"), hex: 0xFF0000),
            ColorSwatch(name: L10n.t("Coral"), hex: 0xFF4000),
            ColorSwatch(name: L10n.t("Laranja"), hex: 0xFF8000),
            ColorSwatch(name: L10n.t("Âmbar"), hex: 0xFFB000),
            ColorSwatch(name: L10n.t("Amarelo"), hex: 0xFFFF00),
            ColorSwatch(name: L10n.t("Lima"), hex: 0xBFFF00),
            ColorSwatch(name: L10n.t("Verde"), hex: 0x00FF00),
            ColorSwatch(name: L10n.t("Esmeralda"), hex: 0x00FF80),
            ColorSwatch(name: L10n.t("Turquesa"), hex: 0x00FFC0),
            ColorSwatch(name: L10n.t("Ciano"), hex: 0x00FFFF),
            ColorSwatch(name: L10n.t("Azul-céu"), hex: 0x00A0FF),
            ColorSwatch(name: L10n.t("Azul"), hex: 0x0040FF),
            ColorSwatch(name: L10n.t("Índigo"), hex: 0x4000FF),
            ColorSwatch(name: L10n.t("Violeta"), hex: 0x8000FF),
            ColorSwatch(name: L10n.t("Roxo Bruce"), hex: 0x9B51E0),
            ColorSwatch(name: L10n.t("Lilás"), hex: 0xC07EFF),
            ColorSwatch(name: L10n.t("Magenta"), hex: 0xFF00FF),
            ColorSwatch(name: L10n.t("Rosa"), hex: 0xFF0080),
            ColorSwatch(name: L10n.t("Branco"), hex: 0xFFFFFF),
            ColorSwatch(name: L10n.t("Branco quente"), hex: 0xFFC98C),
        ]
    }

    static var templates: [LightingTemplate] {
        [
            LightingTemplate(name: L10n.t("Bruce"), systemImage: "sparkle",
                             led: Color(hex: 0x9B51E0), effect: .solid,
                             screen: Color(hex: 0x9B51E0)),
            LightingTemplate(name: L10n.t("Cyberpunk"), systemImage: "bolt.horizontal.fill",
                             led: Color(hex: 0xFF00A0), effect: .breathe,
                             screen: Color(hex: 0x00F0FF)),
            LightingTemplate(name: L10n.t("Matrix"), systemImage: "terminal.fill",
                             led: Color(hex: 0x00FF41), effect: .solid,
                             screen: Color(hex: 0x00FF41)),
            LightingTemplate(name: L10n.t("Fogo"), systemImage: "flame.fill",
                             led: Color(hex: 0xFF4000), effect: .fire,
                             screen: Color(hex: 0xFF7A00)),
            LightingTemplate(name: L10n.t("Gelo"), systemImage: "snowflake",
                             led: Color(hex: 0x00CFFF), effect: .breathe,
                             screen: Color(hex: 0x7FE9FF)),
            LightingTemplate(name: L10n.t("Discoteca"), systemImage: "music.note",
                             led: Color(hex: 0xFFFFFF), effect: .disco,
                             screen: Color(hex: 0xFF00FF)),
            LightingTemplate(name: L10n.t("Vaporwave"), systemImage: "sunset.fill",
                             led: Color(hex: 0xFF66CC), effect: .colorCycle,
                             screen: Color(hex: 0xB86BFF)),
            LightingTemplate(name: L10n.t("Arco-íris"), systemImage: "rainbow",
                             led: Color(hex: 0xFFFFFF), effect: .rainbowBreathe,
                             screen: Color(hex: 0x54A2FF)),
            LightingTemplate(name: L10n.t("Alerta"), systemImage: "exclamationmark.triangle.fill",
                             led: Color(hex: 0xFF0000), effect: .breathe,
                             screen: Color(hex: 0xFF3B30)),
            // The one template that turns the LED off: black is exactly what
            // `led off` writes, so it needs no special case.
            LightingTemplate(name: L10n.t("Furtivo"), systemImage: "moon.zzz.fill",
                             led: .black, effect: .solid,
                             screen: Color(hex: 0x8B0000)),
        ]
    }
}
