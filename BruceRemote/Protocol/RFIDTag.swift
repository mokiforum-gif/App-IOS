import Foundation

/// A tag as the firmware reports it, and as a `.rfid` file.
///
/// `rfid read` / `rfid info` / `rfid loadfile` all print the same block
/// (`_printTagInfo` in `rfid_commands.cpp`):
///
/// ```
/// UID:   CD 8A 74 24
/// Type:  MIFARE 1KB
/// SAK:   08
/// ATQA:  00 04
/// Pages: 64
/// --- data ---
/// Page 0: CD 8A 74 24 …
/// ------------
/// ```
///
/// The dump is rebuilt into the Bruce `.rfid` format here rather than downloaded
/// from the device: the fields the file needs are exactly the ones printed, so a
/// capture can be saved to the phone with no connection round trip — and the
/// result is byte-identical in shape to what `rfid save` writes on the device
/// (`RFID2::save`).
struct RFIDTag: Equatable {
    var uid: String?
    var type: String?
    var sak: String?
    var atqa: String?
    var pages: Int?
    /// The `--- data ---` block, one `Page n: …` line per entry.
    var dataLines: [String] = []

    /// A tag was actually identified. The UID is the one field every module
    /// reports for every tag type, so it is what "there is a tag" means here.
    var isValid: Bool { !(uid ?? "").isEmpty }

    /// True when the read also brought the memory contents back, which is what
    /// separates a clonable dump from a bare UID sighting.
    var hasDump: Bool { !dataLines.isEmpty }

    /// Short description for headers: "MIFARE 1KB · CD 8A 74 24".
    var summary: String {
        [type, uid].compactMap { $0 }.joined(separator: " · ")
    }

    /// The UID without separators, usable as a filename.
    var fileNameStem: String {
        let compact = (uid ?? "").filter { $0.isHexDigit }
        return compact.isEmpty ? "tag" : compact
    }

    /// The dump as a Bruce `.rfid` file, mirroring `RFID2::save`.
    var fileContent: String {
        var lines = [
            "Filetype: Bruce RFID File",
            "Version 1",
            "Device type: \(type ?? "Unknown")",
            "# UID, ATQA and SAK are common for all formats",
            "UID: \(uid ?? "")",
            "SAK: \(sak ?? "")",
            "ATQA: \(atqa ?? "")",
            "# Memory dump",
            "Pages total: \(pages ?? dataLines.count)",
        ]
        lines.append(contentsOf: dataLines)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parse the block printed by `rfid read` / `info` / `loadfile`.
    ///
    /// Tolerant by design: a module that omits SAK/ATQA, or a read that returned
    /// no pages, still yields a usable tag as long as a UID came back.
    static func parse(_ lines: [String]) -> RFIDTag {
        var tag = RFIDTag()
        var inData = false

        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)

            if text.hasPrefix("--- data ---") { inData = true; continue }
            if text.hasPrefix("------------") { inData = false; continue }
            if inData {
                if !text.isEmpty { tag.dataLines.append(text) }
                continue
            }

            if let value = text.value(afterLabel: "UID:")   { tag.uid = value }
            else if let value = text.value(afterLabel: "Type:")  { tag.type = value }
            else if let value = text.value(afterLabel: "SAK:")   { tag.sak = value }
            else if let value = text.value(afterLabel: "ATQA:")  { tag.atqa = value }
            else if let value = text.value(afterLabel: "Pages:") { tag.pages = Int(value) }
        }
        return tag
    }

    /// Whether a reply line means the firmware finished (successfully or not),
    /// so a request can stop waiting instead of running out its timeout.
    ///
    /// `_printTagInfo` only emits the `--- data ---` block when the driver has
    /// pages to show, so `Pages: 0` is itself the end of the reply — without this
    /// a UID-only tag (FeliCa, ISO14443-4) would leave the read waiting for a
    /// terminator that is never printed.
    static func isTerminalLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("Pages:"),
           Int(text.dropFirst("Pages:".count).trimmingCharacters(in: .whitespaces)) == 0 {
            return true
        }
        return text.hasPrefix("------------")
            || text.hasPrefix("Read failed:")
            || text.hasPrefix("ERROR:")
            || text.hasPrefix("No tag data")
    }
}

private extension String {
    /// Value after a `Label:` prefix, trimmed — nil when the line starts otherwise.
    func value(afterLabel label: String) -> String? {
        guard hasPrefix(label) else { return nil }
        let value = dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
