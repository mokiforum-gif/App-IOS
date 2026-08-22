import SwiftUI

/// What the device reports about itself: `info`, `free`, `uptime` and `date`,
/// parsed out of their serial output.
///
/// The firmware prints these as loose `Label: value` lines (`util_commands.cpp`),
/// one command at a time. Parsing them here keeps "My Bruce" a plain data screen
/// instead of a second terminal, and every field is optional because an older
/// build — or a board without PSRAM, WiFi or a clock — simply omits its line.
struct DeviceStatus: Equatable {
    var info = DeviceInfo()
    var memory = DeviceMemory()
    /// Formatted by the device as `HH:MM:SS`.
    var uptime: String?
    /// Device clock, or nil when it was never set (`Clock not set`).
    var clock: String?
}

/// One round trip of the device overview read, in the order they run.
///
/// Ordered (`Comparable`) so the loading screen can tell done from pending
/// without tracking a separate set.
enum DeviceProbeStep: Int, CaseIterable, Identifiable, Comparable {
    case info
    case memory
    case uptime
    case clock
    case storage
    /// Which library captures are already on the device. Skipped when the phone's
    /// library is empty — there would be nothing to compare against.
    case library

    var id: Int { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// What the app is asking the device for, in the user's words.
    var label: LocalizedStringKey {
        switch self {
        case .info:    return "Informações do dispositivo"
        case .memory:  return "Memória"
        case .uptime:  return "Tempo ligado"
        case .clock:   return "Relógio"
        case .storage: return "Armazenamento"
        case .library: return "Biblioteca no device"
        }
    }

    /// The serial command behind the step, shown as a hint while it runs.
    var command: String {
        switch self {
        case .info:    return SystemCommand.info.serialLine
        case .memory:  return SystemCommand.free.serialLine
        case .uptime:  return SystemCommand.uptime.serialLine
        case .clock:   return SystemCommand.date.serialLine
        case .storage: return StorageCommand.free(storage: .sd).serialLine
        case .library: return "storage list"
        }
    }
}

/// A one-glance verdict on the device, built from the readings already taken.
///
/// Deliberately narrow: it only claims what the app measured — the firmware
/// answered, there is headroom in the heap, and there is somewhere to write. It
/// is not a health check of the radios or the hardware.
struct DeviceHealth: Equatable {
    enum Level { case ok, attention, unknown }

    let level: Level
    let label: String

    /// Below this share of free heap, the device starts failing large captures.
    private static let lowHeapThreshold = 0.15

    static func evaluate(status: DeviceStatus?, storage: DeviceStorageReport?) -> DeviceHealth {
        guard let status, !status.info.isEmpty else {
            return DeviceHealth(level: .unknown, label: L10n.t("Sem leitura"))
        }
        if let used = status.memory.heapUsedFraction, 1 - used < lowHeapThreshold {
            return DeviceHealth(level: .attention, label: L10n.t("Heap baixa"))
        }
        if let storage, storage.active == nil {
            return DeviceHealth(level: .attention, label: L10n.t("Sem armazenamento"))
        }
        return DeviceHealth(level: .ok, label: L10n.t("Tudo certo"))
    }

    var systemImage: String {
        switch level {
        case .ok:        return "checkmark.seal.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .unknown:   return "questionmark.circle"
        }
    }
}

struct DeviceInfo: Equatable {
    var version: String?
    /// The firmware's git commit, printed bare on its own line.
    var commit: String?
    var sdk: String?
    var mac: String?
    var wifiConnected: Bool?
    var ip: String?
    /// The board the firmware was built for (`DEVICE_NAME`).
    var device: String?

    /// True when the device answered nothing usable — used to retry the read.
    var isEmpty: Bool {
        version == nil && commit == nil && sdk == nil && mac == nil
            && wifiConnected == nil && ip == nil && device == nil
    }

    static func parse(_ lines: [String]) -> DeviceInfo {
        var info = DeviceInfo()
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let value = text.value(after: "Bruce v") {
                info.version = value
            } else if let value = text.value(after: "SDK:") {
                info.sdk = value
            } else if let value = text.value(after: "MAC addr:") {
                info.mac = value
            } else if let value = text.value(after: "Wifi:") {
                info.wifiConnected = value.localizedCaseInsensitiveContains("not") == false
            } else if let value = text.value(after: "Ip:") {
                info.ip = value
            } else if let value = text.value(after: "Device:") {
                info.device = value
            } else if info.commit == nil, text.isCommitHash {
                // The hash is printed with no label, right after the version.
                info.commit = text
            }
        }
        return info
    }
}

struct DeviceMemory: Equatable {
    var totalHeap: Int?
    var freeHeap: Int?
    var totalPSRAM: Int?
    var freePSRAM: Int?

    /// Heap in use, as a fraction — nil unless both figures arrived.
    var heapUsedFraction: Double? {
        guard let totalHeap, totalHeap > 0, let freeHeap else { return nil }
        return Double(totalHeap - freeHeap) / Double(totalHeap)
    }

    var hasPSRAM: Bool { totalPSRAM != nil }

    static func parse(_ lines: [String]) -> DeviceMemory {
        var memory = DeviceMemory()
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let value = text.value(after: "Total heap:") { memory.totalHeap = Int(value) }
            else if let value = text.value(after: "Free heap:") { memory.freeHeap = Int(value) }
            else if let value = text.value(after: "Total PSRAM:") { memory.totalPSRAM = Int(value) }
            else if let value = text.value(after: "Free PSRAM:") { memory.freePSRAM = Int(value) }
        }
        return memory
    }
}

extension DeviceStatus {
    /// `Uptime: 01:23:45` → `01:23:45`.
    static func parseUptime(_ lines: [String]) -> String? {
        lines.compactMap { $0.trimmingCharacters(in: .whitespaces).value(after: "Uptime:") }.last
    }

    /// `Current time: …`, or nil when the device answered `Clock not set`.
    static func parseClock(_ lines: [String]) -> String? {
        lines.compactMap { $0.trimmingCharacters(in: .whitespaces).value(after: "Current time:") }.last
    }
}

private extension String {
    /// The remainder after `prefix`, trimmed — nil when the line starts otherwise.
    func value(after prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let value = dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// A bare git hash: hex, and long enough not to be a stray word.
    var isCommitHash: Bool {
        count >= 7 && count <= 40 && allSatisfy(\.isHexDigit)
    }
}

/// Byte counts as the device reports them, formatted for display.
extension Int {
    var byteSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .memory)
    }
}
