import Foundation

/// A capture stored locally on the phone (the app-side "Archive").
///
/// Backed by a real file under the app's `Documents/Library` directory; metadata
/// is derived from the filesystem plus a favorites flag persisted separately.
struct LibraryItem: Identifiable, Hashable {
    let url: URL
    let size: Int
    let modified: Date
    var isFavorite: Bool

    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    var systemImage: String {
        switch ext {
        case "sub":                 return "antenna.radiowaves.left.and.right"
        case "ir":                  return "dot.radiowaves.left.and.right"
        case "nfc", "rfid", "picc": return "wave.3.right"
        case "pcap":                return "network"
        case "txt", "log", "json":  return "doc.text"
        case "js":                  return "curlybraces"
        default:                    return "doc"
        }
    }

    /// Can be replayed by a module once uploaded to the device.
    var isReplayable: Bool { ext == "sub" || ext == "ir" }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
