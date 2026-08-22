import Foundation

/// The official folders the Bruce firmware creates on its storage (SD or LittleFS).
///
/// Each module reads and writes its captures in exactly one of these, so they are
/// the paths the app uses for uploads, `tx_from_file` replays and the library's
/// "synced" check. Kept in one place because several views build paths by hand.
enum BruceFolder {
    /// Infrared captures (`.ir`).
    static let ir = "/BruceIR"
    /// Sub-GHz / RF captures (`.sub`).
    static let rf = "/BruceRF"
    /// NFC / RFID dumps (`.nfc`, `.rfid`, `.picc`).
    static let rfid = "/BruceRFID"
    /// Sniffer captures (`.pcap`).
    static let pcap = "/BrucePCAP"
    /// JavaScript apps (`.js`).
    static let js = "/BruceJS"
    /// App Store bookkeeping — what the store installed and where.
    static let appStore = "/BruceAppStore"

    static let all = [ir, rf, rfid, pcap, js, appStore]

    /// Join a folder and a file name into an absolute device path.
    static func path(_ folder: String, _ name: String) -> String {
        "\(folder)/\(name)"
    }
}
