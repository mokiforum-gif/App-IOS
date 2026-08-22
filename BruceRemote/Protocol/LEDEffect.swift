import SwiftUI

/// The RGB LED animations the firmware ships, numbered exactly as
/// `led effect <n>` expects (`LED_EFFECT_*` in `src/core/led_control.h`).
///
/// The two traits below are not decoration — they are the difference between a
/// picker that lies and one that does not. Half of these effects generate their
/// own hues and ignore the configured color entirely, and two of them are
/// compiled out on boards with a single LED, where selecting them does nothing
/// visible.
enum LEDEffect: Int, CaseIterable, Identifiable {
    case solid = 0
    case breathe = 1
    case colorCycle = 2
    case colorWheel = 3
    case chase = 4
    case chaseTail = 5
    case rainbowChase = 6
    case rainbowBreathe = 7
    case disco = 8
    case fire = 9

    var id: Int { rawValue }

    /// The device's own menu wording, translated (`setLedEffectConfig`).
    var name: LocalizedStringKey {
        switch self {
        case .solid:          return "Cor sólida"
        case .breathe:        return "Respiração"
        case .colorCycle:     return "Ciclo de cores"
        case .colorWheel:     return "Roda de cores"
        case .chase:          return "Perseguição"
        case .chaseTail:      return "Perseguição com rastro"
        case .rainbowChase:   return "Arco-íris em movimento"
        case .rainbowBreathe: return "Arco-íris pulsante"
        case .disco:          return "Discoteca"
        case .fire:           return "Fogo"
        }
    }

    var systemImage: String {
        switch self {
        case .solid:          return "lightbulb.fill"
        case .breathe:        return "lungs.fill"
        case .colorCycle:     return "arrow.triangle.2.circlepath"
        case .colorWheel:     return "circle.hexagongrid.fill"
        case .chase:          return "arrow.right.circle.fill"
        case .chaseTail:      return "paintbrush.pointed.fill"
        case .rainbowChase:   return "rainbow"
        case .rainbowBreathe: return "sun.haze.fill"
        case .disco:          return "sparkles"
        case .fire:           return "flame.fill"
        }
    }

    /// Whether the effect paints with the chosen color.
    ///
    /// `ledEffectTask` builds its own hues for the cycle, wheel, rainbow, disco and
    /// fire modes, so picking a color changes nothing while one of them is running —
    /// the picker says so rather than leaving the user to figure it out.
    var usesColor: Bool {
        switch self {
        case .solid, .breathe, .chase, .chaseTail: return true
        default:                                   return false
        }
    }

    /// Effects whose branch in `ledEffectTask` sits inside `#if LED_COUNT > 1`.
    ///
    /// On a board with a single LED the command is still accepted and stored, but
    /// nothing animates — the LED simply keeps whatever it was showing.
    var needsMultipleLEDs: Bool {
        switch self {
        case .chase, .chaseTail: return true
        default:                 return false
        }
    }

    /// Short caveat shown under the effect's name, when it has one.
    var caveat: LocalizedStringKey? {
        if needsMultipleLEDs { return "vários LEDs" }
        if !usesColor { return "cores próprias" }
        return nil
    }
}
