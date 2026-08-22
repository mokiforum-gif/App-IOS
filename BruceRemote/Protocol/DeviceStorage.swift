import Foundation

/// One of the two filesystems a Bruce keeps files on.
///
/// The app never *chooses* between them: no `storage` subcommand takes a
/// filesystem argument. Every callback in the firmware's `storage_commands.cpp`
/// resolves the target through `getFsStorage()` (`core/sd_functions.cpp`):
///
/// ```cpp
/// if (sdcardMounted) fs = &SD;
/// else if (checkLittleFsSize()) fs = &LittleFS;
/// else return false;
/// ```
///
/// So `storage list/read/write/remove/mkdir/rename` all hit the SD card when one
/// is mounted and LittleFS otherwise — and with a card in, the internal memory is
/// unreachable over the CLI (no serial command unmounts it; `ToggleSDCard()` is
/// only wired to the on-device menu). This enum exists to *name* the filesystem
/// the browser and the library's sync badge are actually looking at, so a listing
/// is never silently attributed to the wrong one.
enum DeviceStorage: String, CaseIterable, Identifiable {
    case sd
    case littleFS

    var id: String { rawValue }

    /// The token `storage free` expects.
    var commandArgument: String {
        switch self {
        case .sd:       return "sd"
        case .littleFS: return "littlefs"
        }
    }

    var label: String {
        switch self {
        case .sd:       return L10n.t("Cartão SD")
        case .littleFS: return L10n.t("Memória interna")
        }
    }

    /// Compact form for chips and inline annotations.
    var shortLabel: String {
        switch self {
        case .sd:       return "SD"
        case .littleFS: return "LittleFS"
        }
    }

    var systemImage: String {
        switch self {
        case .sd:       return "sdcard"
        case .littleFS: return "internaldrive"
        }
    }

    /// The prefix the firmware puts on each `storage free` line ("SD Total space: …").
    var outputPrefix: String {
        switch self {
        case .sd:       return "SD"
        case .littleFS: return "LittleFS"
        }
    }
}

/// Space figures for one filesystem, as reported by `storage free <sd|littlefs>`.
struct StorageSpace: Equatable {
    let total: Int64
    let used: Int64

    var free: Int64 { max(0, total - used) }

    var freeLabel: String { Self.format(free) }
    var totalLabel: String { Self.format(total) }

    /// "12,4 GB livres de 32 GB".
    var summary: String { L10n.t("\(freeLabel) livres de \(totalLabel)") }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Parse the three `<prefix> Total/Used/Free space: <n> Bytes` lines.
    ///
    /// Returns nil when the reply carries no figures for this filesystem — which is
    /// how "No SD card installed" and an unanswered request both look.
    static func parse(_ lines: [String], for storage: DeviceStorage) -> StorageSpace? {
        func value(_ keyword: String) -> Int64? {
            for line in lines
            where line.localizedCaseInsensitiveContains("\(storage.outputPrefix) \(keyword) space") {
                let digits = line.drop { !$0.isNumber }.prefix { $0.isNumber }
                if let parsed = Int64(digits) { return parsed }
            }
            return nil
        }
        guard let total = value("Total"), total > 0 else { return nil }
        return StorageSpace(total: total, used: value("Used") ?? 0)
    }
}

/// What the device answered when asked about both filesystems.
///
/// `sd` is non-nil exactly when a card is mounted, because the firmware's
/// `storage free sd` calls `setupSdCard()` and prints "No SD card installed" when
/// that fails — which also makes this probe the app's mount check.
struct DeviceStorageReport: Equatable {
    let sd: StorageSpace?
    let littleFS: StorageSpace?

    /// The filesystem every `storage` command currently operates on — the same
    /// choice `getFsStorage()` makes: SD when mounted, LittleFS otherwise.
    var active: DeviceStorage? {
        if sd != nil { return .sd }
        if littleFS != nil { return .littleFS }
        return nil
    }

    /// The other filesystem, which the CLI cannot reach while `active` is mounted.
    var inactive: DeviceStorage? {
        switch active {
        case .sd:       return .littleFS
        case .littleFS: return .sd
        case nil:       return nil
        }
    }

    func space(for storage: DeviceStorage) -> StorageSpace? {
        switch storage {
        case .sd:       return sd
        case .littleFS: return littleFS
        }
    }

    /// One line explaining why only one of the two is being listed.
    var explanation: String {
        switch active {
        case .sd:
            return L10n.t("O firmware envia todo comando storage para o cartão SD enquanto ele está montado; a memória interna só fica acessível sem cartão.")
        case .littleFS:
            return L10n.t("Nenhum cartão SD montado — o Bruce lê e grava tudo na memória interna (LittleFS).")
        case nil:
            return L10n.t("Não foi possível determinar o armazenamento do dispositivo.")
        }
    }
}
