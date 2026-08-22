import SwiftUI

/// The kind of a stored capture, derived from its file extension.
///
/// Drives the library's grouping, the colored badge on each card, and — through
/// `deviceFolder` — where an item is expected to live on the Bruce, which is what
/// the "synced" indicator checks against.
enum LibraryCategory: String, CaseIterable, Identifiable {
    case subghz
    case infrared
    case nfc
    case sniffer
    case script
    case other

    var id: String { rawValue }

    static func of(_ item: LibraryItem) -> LibraryCategory { of(extension: item.ext) }

    static func of(extension ext: String) -> LibraryCategory {
        switch ext {
        case "sub":                 return .subghz
        case "ir":                  return .infrared
        case "nfc", "rfid", "picc": return .nfc
        case "pcap":                return .sniffer
        case "js":                  return .script
        default:                    return .other
        }
    }

    var title: String {
        switch self {
        case .subghz:   return "Sub-GHz"
        case .infrared: return L10n.t("Infravermelho")
        case .nfc:      return "NFC / RFID"
        case .sniffer:  return "Sniffer"
        case .script:   return L10n.t("Scripts")
        case .other:    return L10n.t("Outros")
        }
    }

    var systemImage: String {
        switch self {
        case .subghz:   return "antenna.radiowaves.left.and.right"
        case .infrared: return "dot.radiowaves.left.and.right"
        case .nfc:      return "wave.3.right"
        case .sniffer:  return "network"
        case .script:   return "curlybraces"
        case .other:    return "doc"
        }
    }

    /// Badge color, kept distinct per type while staying inside the app's palette.
    var color: Color {
        switch self {
        case .subghz:   return Color(hex: 0x3DDC84)   // green
        case .infrared: return Color(hex: 0xFF7A5C)   // coral
        case .nfc:      return BruceColor.azure        // blue
        case .sniffer:  return Color(hex: 0xFFC53D)   // amber
        case .script:   return BruceColor.lilac        // violet
        case .other:    return Color(hex: 0x8E8E93)   // gray
        }
    }

    /// The official Bruce folder for this type, or `nil` when there is no
    /// well-known location (so its sync state stays "unknown").
    var deviceFolder: String? {
        switch self {
        case .subghz:   return BruceFolder.rf
        case .infrared: return BruceFolder.ir
        case .nfc:      return BruceFolder.rfid
        case .sniffer:  return BruceFolder.pcap
        case .script:   return BruceFolder.js
        case .other:    return nil
        }
    }
}

/// Whether a library item also exists on the connected device.
enum SyncState {
    /// Present on the device (a file of the same name lives in its folder).
    case synced
    /// Not on the device — its folder was listed and the file was absent.
    case notSynced
    /// Can't tell: disconnected, or the type has no known device folder.
    case unknown

    var systemImage: String {
        switch self {
        case .synced:    return "checkmark.icloud.fill"
        case .notSynced: return "icloud.slash"
        case .unknown:   return "icloud"
        }
    }

    var color: Color {
        switch self {
        case .synced:    return BruceColor.azure
        case .notSynced: return Color(hex: 0x8E8E93)
        case .unknown:   return Color(hex: 0x8E8E93).opacity(0.5)
        }
    }

    var label: String {
        switch self {
        case .synced:    return L10n.t("Sincronizado")
        case .notSynced: return L10n.t("Não sincronizado")
        case .unknown:   return L10n.t("Estado desconhecido")
        }
    }
}
