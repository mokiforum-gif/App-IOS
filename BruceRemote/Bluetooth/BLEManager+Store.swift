import Foundation

/// App Store installation over BLE: write each app file to the device, launch a
/// script, and remove an app's files.
///
/// Text scripts (`.js`) take the reliable `storage write` path; any file that is
/// not valid UTF-8 (icons, fonts, `.bin`) goes over Y-modem. Both create the parent
/// directory first, because LittleFS will not open a file in a folder that does not
/// exist yet.
extension BLEManager {

    /// Write one app file to `path`. Returns nil on success, or a message to show.
    ///
    /// `progress` only reports for the binary (Y-modem) path; text uploads are a
    /// single short write and finish before a bar would help.
    func installStoreFile(
        path: String,
        data: Data,
        progress: TransferProgress? = nil
    ) async -> String? {
        guard state == .ready else { return L10n.t("Conecte-se ao Bruce para instalar.") }

        if let text = String(data: data, encoding: .utf8) {
            let ok = await saveTextFileVerified(path: path, content: text)
            return ok ? nil : L10n.t("O device não confirmou a gravação de \(path).")
        }

        // Binary asset: ensure the folder exists, then hand off to Y-modem.
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty, dir != "/" { _ = await request(StorageCommand.mkdir(path: dir)) }
        return await sendFileYModem(path: path, data: data, progress: progress)
    }

    /// Launch an installed script. The device takes over its own screen; there is
    /// no reply to await, so this is fire-and-forget.
    func runScript(at path: String) {
        guard state == .ready else { return }
        send(JSCommand.runFromFile(path: path))
    }

    /// Delete an app's files from the device. Best-effort: a file already gone is
    /// not an error, so failures are not surfaced per file.
    func removeStoreFiles(_ paths: [String]) async {
        for path in paths {
            _ = await request(StorageCommand.remove(path: path))
        }
    }
}
