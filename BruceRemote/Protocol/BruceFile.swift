import Foundation

/// A single entry returned by `storage list`.
///
/// The firmware prints one entry per line as `name\t<DIR>` for directories or
/// `name\t<size>` for files (see `storage_commands.cpp`).
struct BruceFile: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: Int?
    /// Absolute path on the device, e.g. `/BruceRF/gate.sub`.
    let path: String

    var id: String { path }

    /// Lowercased extension without the dot (empty for directories / no extension).
    var ext: String {
        guard !isDirectory, let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// SF Symbol suited to the entry type.
    var systemImage: String {
        if isDirectory { return "folder.fill" }
        switch ext {
        case "sub":                 return "antenna.radiowaves.left.and.right"
        case "ir":                  return "dot.radiowaves.left.and.right"
        case "nfc", "rfid", "picc": return "wave.3.right"
        case "txt", "log", "json":  return "doc.text"
        case "js":                  return "curlybraces"
        default:                    return "doc"
        }
    }

    /// Whether this file can be replayed by a module directly from storage.
    var isReplayable: Bool { ext == "sub" || ext == "ir" }
}

extension BruceFile {
    /// Join a parent directory and a leaf name into a normalized absolute path.
    static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    /// Parse `storage list` output into entries under `parent`.
    ///
    /// Lines without a tab (errors, stray output) are ignored so a bad listing
    /// yields an empty result rather than junk entries.
    static func parseListing(_ lines: [String], parent: String) -> [BruceFile] {
        lines.compactMap { line -> BruceFile? in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let name = String(line[..<tab]).trimmingCharacters(in: .whitespaces)
            let marker = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }

            if marker == "<DIR>" {
                return BruceFile(name: name, isDirectory: true, size: nil, path: join(parent, name))
            }
            return BruceFile(name: name, isDirectory: false, size: Int(marker), path: join(parent, name))
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }  // folders first
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Human-readable size, e.g. "1.2 KB".
    var sizeLabel: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
