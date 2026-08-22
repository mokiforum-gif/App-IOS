import Foundation

/// A user-built IR remote: a named grid of buttons that emit IR commands.
struct IRRemote: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var buttons: [IRButton] = []
}

/// One button on a remote.
struct IRButton: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String
    var systemImage: String
    var action: IRButtonAction
}

/// What a button does when pressed.
enum IRButtonAction: Codable, Hashable {
    /// A decoded frame: `ir tx <protocol> <address> <command>` (8-hex args).
    /// Only expresses simple protocols (NEC, RC5…), never A/C `state` signals.
    case decoded(protocol: String, address: String, command: String)
    /// Replay a `.ir` file already on the device: `ir tx_from_file <path>`.
    case file(path: String)
    /// A self-contained `.ir` capture replayed via `ir tx_from_buffer`. Works for
    /// any signal — air conditioners (`state`), raw, and simple alike.
    case buffer(irContent: String)
}

/// A single captured signal parsed from `ir rx` output (Flipper `.ir` block).
///
/// The device prints a full `.ir` file. Simple frames carry `address`/`command`;
/// air-conditioner frames carry a `state:` line instead — those cannot be sent
/// with `ir tx` and must be replayed from the whole block via `tx_from_buffer`.
/// ```
/// Filetype: IR signals file
/// Version: 1
/// #
/// name: Unknown
/// type: parsed
/// protocol: GREE
/// address: 00 00 00 00
/// command: 00 00 00 00
/// bits: 64
/// state: 39 08 D0 50 00 01 00 B0
/// #
/// ```
struct IRCapture: Equatable {
    var type: String?
    var protocolName: String?
    var address: String?
    var command: String?
    var state: String?
    var value: String?
    var bits: Int?
    var frequency: Int?
    var dutyCycle: String?
    var rawData: String?
    /// The reconstructed `.ir` file block, ready for `tx_from_buffer` (empty if
    /// no signal was captured).
    var fileContent = ""

    /// A signal was captured (of any kind).
    var hasSignal: Bool { !fileContent.isEmpty }

    /// True when the capture carries an air-conditioner `state` line.
    var hasState: Bool { !(state ?? "").isEmpty }

    /// True when the parsed block looks like a complete, usable `.ir` signal.
    ///
    /// This rejects partial captures / truncated dumps and ensures the expected
    /// fields are present for each capture type:
    /// - `raw`: frequency, duty_cycle and non-empty data.
    /// - `parsed`: protocol, address/command or a state payload.
    var isValid: Bool {
        guard hasSignal,
              fileContent.hasPrefix("Filetype: IR signals file"),
              fileContent.contains("Version: 1"),
              let type = type else { return false }

        switch type {
        case "raw":
            guard let frequency = frequency, frequency > 0,
                  let data = rawData, !data.isEmpty else { return false }
            return true
        case "parsed":
            guard let protocolName = protocolName, !protocolName.isEmpty else { return false }
            // Simple decoded frame (NEC, RC5, Samsung32...)
            if let address = address, address.count == 8,
               let command = command, command.count == 8 {
                return true
            }
            // A/C or other state-based frame
            if hasState { return true }
            return false
        default:
            return false
        }
    }

    /// True when the capture is a simple decoded frame usable with `ir tx`.
    var isSimpleDecoded: Bool {
        type == "parsed" && !hasState
            && !(protocolName ?? "").isEmpty
            && (address?.count == 8) && (command?.count == 8)
    }

    static func parse(_ lines: [String]) -> IRCapture {
        var capture = IRCapture()

        // Isolate the `.ir` block: from "Filetype:" until the first line that is
        // neither a `key: value` field nor a `#` comment (e.g. "Turning off IR LED").
        var block: [String] = []
        var inBlock = false
        for line in lines {
            if !inBlock {
                if line.hasPrefix("Filetype:") { inBlock = true; block.append(line) }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "#" || line.contains(":") {
                block.append(line)
            } else {
                break
            }
        }
        capture.fileContent = block.joined(separator: "\n")

        for line in block {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "type":       capture.type = value.lowercased()
            case "protocol":   capture.protocolName = value
            case "address":    capture.address = hex8(value)
            case "command":    capture.command = hex8(value)
            case "state":      capture.state = value.uppercased()
            case "value":      capture.value = value.uppercased()
            case "bits":       capture.bits = Int(value)
            case "frequency":  capture.frequency = Int(value)
            case "duty_cycle": capture.dutyCycle = value
            case "data":       capture.rawData = value
            default:           break
            }
        }
        return capture
    }

    /// A line signalling the captured block is complete (its terminal field).
    static func isTerminalField(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasPrefix("state:") || l.hasPrefix("value:") || l.hasPrefix("data:")
    }

    /// Normalize "04 00 00 00" → "04000000" (uppercase, no separators).
    private static func hex8(_ raw: String) -> String {
        raw.filter { $0.isHexDigit }.uppercased()
    }
}
