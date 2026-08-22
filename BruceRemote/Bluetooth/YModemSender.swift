import Foundation

/// Uploads an arbitrary file to the device with `storage ymodem`.
///
/// This is the binary path. `storage write` streams text line by line and stops
/// at the first byte that is not valid UTF-8 — fine for `.ir`/`.sub`/`.rfid`
/// captures, useless for images, fonts or compiled scripts. Y-modem carries bytes
/// and checks every block with a CRC, so it is also the more trustworthy of the
/// two whenever both would work.
///
/// The exchange, as this firmware implements it:
///
/// ```
/// app                                     Bruce
///  │  storage ymodem /path                  │
///  │ ───────────────────────────────────►   │
///  │   "Starting Y-modem receive to: …"     │
///  │   "Send file using Y-modem protocol…"  │
///  │ ◄───────────────────────────────────   │
///  │              'C'  (every second)       │
///  │ ◄───────────────────────────────────   │
///  │  block 0  (name + size)          ──►   │
///  │ ◄── ACK                                │
///  │  block 1…N  (128 bytes + CRC)    ──►   │
///  │ ◄── ACK / NAK per block                │
///  │  EOT                             ──►   │
///  │ ◄── ACK, "Y-modem transfer complete"   │
/// ```
extension BLEManager {

    /// Progress of a binary upload, from 0 to 1.
    typealias TransferProgress = @MainActor (Double) -> Void

    /// Send `data` to `path` over Y-modem. Returns nil on success, or a message
    /// describing where it stopped.
    ///
    /// Failures are reported rather than thrown so callers can show them as-is;
    /// there is nothing to recover from at this layer.
    func sendFileYModem(
        path: String,
        data: Data,
        progress: TransferProgress? = nil
    ) async -> String? {
        guard state == .ready else { return L10n.t("Conecte-se ao Bruce para enviar.") }

        let stream = ByteStream()
        guard beginRawByteMode({ [weak stream] chunk in stream?.ingest(chunk) }) else {
            return L10n.t("Outra transferência está em andamento.")
        }
        defer { endRawByteMode() }

        send(StorageCommand.ymodem(path: path))

        // 1) Wait for the banner. Its last line is fixed, which makes it a
        //    reliable divider between text and protocol — the path echoed in the
        //    line above can itself contain a 'C', so scanning for the handshake
        //    byte before this point would match the wrong one.
        guard await stream.waitForMarker("128-byte blocks only", timeout: 8) else {
            cancelYModemSession()
            return L10n.t("O device não entrou em modo Y-modem.")
        }
        // 2) The receiver asks for CRC mode once a second until data arrives.
        guard await stream.waitForByte(YModem.crcRequest, timeout: 12) else {
            cancelYModemSession()
            return L10n.t("O device não pediu o início da transferência (sem 'C').")
        }

        // 3) Header block: the size in it is what lets the receiver trim the last
        //    block exactly instead of stripping padding bytes that may be real.
        let header = YModem.headerBlock(fileName: path, size: data.count)
        guard await sendBlock(header, stream: stream, label: "header") else {
            cancelYModemSession()
            return L10n.t("O device recusou o cabeçalho Y-modem.")
        }

        // 4) Data blocks, pipelined.
        //
        // The receiver is classic stop-and-wait YMODEM: one ACK per 128-byte block,
        // each ACK sent only *after* the block is written to flash. Sending one block
        // and waiting for its ACK spends a whole BLE round trip (~30–60 ms) per 128
        // bytes — a few KB/s, which is minutes for anything large.
        //
        // Instead, keep a window of blocks in flight: prime `windowSize` of them, then
        // send one more each time an ACK comes back. This is safe against the firmware's
        // 16 KB RX buffer *because* the ACK gates it — the ACK follows the flash write,
        // so the device can never fall more than `windowSize` blocks (≈2 KB) behind, far
        // under the buffer limit, no matter how slow the flash is.
        //
        // The catch is the receiver's strict sequencing: a NAK does not advance its
        // expected block number, so once blocks N+1…N+W are already in its buffer a
        // single NAK cascades into unrecoverable desync. The BLE link delivers reliably
        // and in order and `writeRaw` respects flow control, so a NAK should not happen;
        // if one does, abort rather than pretend we can resync.
        if let failure = await sendDataBlocks(YModem.payloads(for: data),
                                              stream: stream, progress: progress) {
            return failure
        }

        // 5) End of transmission. The receiver ACKs, closes the file and reports.
        writeBytes(Data([YModem.eot]))
        _ = await stream.waitForByte(YModem.ack, timeout: 8)

        let closing = await stream.collectText(until: "transfer complete", timeout: 6)
        for line in closing where !line.isEmpty { log(line) }

        if closing.contains(where: { $0.contains("transfer complete") }) { return nil }
        // The firmware also finishes by inactivity timeout, printing "transfer
        // completed" — a successful path with a different word, worth accepting.
        if closing.contains(where: { $0.contains("transfer completed") }) { return nil }
        return L10n.t("O device não confirmou o fim da transferência.")
    }

    /// Abort a session the app is about to walk away from.
    ///
    /// `ymodemReceiveCallback` blocks the firmware's normal command parser for
    /// up to its own 60-second handshake window while it waits for blocks that
    /// are never coming. Without this, a retry's `storage ymodem` command lands
    /// while the old call is still reading — read as bogus block data instead
    /// of a new command — so the retry times out waiting for a banner that
    /// will never be printed. One CAN byte makes the firmware drop the session
    /// and reprint its banner immediately, ready for the next attempt.
    private func cancelYModemSession() {
        writeBytes(Data([YModem.can]))
    }

    /// How many blocks may be in flight at once (unacknowledged).
    ///
    /// 16 is a measured sweet spot, not a safety ceiling — the firmware's 16 KB RX
    /// buffer would allow far more (16 blocks is only ≈2 KB), and the ACK gates the
    /// window against overflow regardless. Bigger is *slower* here: a BLE connection
    /// event carries only so many packets in each direction, so flooding the TX side
    /// with a large window starves the return path and the ACKs — which clock the
    /// whole transfer — come back later. Measured ~11 KB/s at 16 and ~4 KB/s at 32.
    /// Turn this *down* (e.g. 8), never up, if you ever need to trade throughput for
    /// an even gentler footprint.
    private var windowSize: Int { 16 }

    /// Stream `payloads` as blocks 1…N with a sliding, ACK-clocked window.
    ///
    /// Returns nil on success, or a localized message naming where it stopped. On any
    /// failure it cancels the firmware's receive session (except when the firmware is
    /// the one that cancelled — then it has already torn the session down itself).
    private func sendDataBlocks(
        _ payloads: [[UInt8]],
        stream: ByteStream,
        progress: TransferProgress?
    ) async -> String? {
        let total = payloads.count

        // Y-modem sequence numbers are a byte and wrap at 256 — that is why the frame
        // uses `index + 1` truncated, not the raw index.
        func frame(_ index: Int) -> Data {
            YModem.block(sequence: UInt8(truncatingIfNeeded: index + 1), payload: payloads[index])
        }

        var nextToSend = 0
        var acked = 0

        // Prime the window.
        while nextToSend < min(windowSize, total) {
            writeBytes(frame(nextToSend))
            nextToSend += 1
        }

        // One ACK == one more block done, and licenses one more onto the wire.
        while acked < total {
            switch await stream.waitForAcknowledgement(timeout: 10) {
            case .acknowledged:
                acked += 1
                progress?(Double(acked) / Double(total))
                if nextToSend < total {
                    writeBytes(frame(nextToSend))
                    nextToSend += 1
                }
            case .rejected:
                // A NAK here means the window is already desynced (see the caller's
                // note); there is no clean resume, so abort the session.
                cancelYModemSession()
                return L10n.t("Transferência dessincronizou (NAK no bloco \(acked + 1) de \(total)).")
            case .cancelled:
                // The firmware itself gave up (e.g. a failed flash write) and has
                // already closed the session — do not send it another CAN.
                return L10n.t("O device cancelou a transferência no bloco \(acked + 1) de \(total).")
            case .timedOut:
                cancelYModemSession()
                return L10n.t("Sem resposta do device no bloco \(acked + 1) de \(total).")
            }
        }
        return nil
    }

    /// Send one framed block and settle its acknowledgement, retrying on NAK.
    ///
    /// Used for the header block, where stop-and-wait is the right shape: the data
    /// blocks that follow are pipelined in `sendDataBlocks`.
    private func sendBlock(_ frame: Data, stream: ByteStream, label: String) async -> Bool {
        for attempt in 1...5 {
            writeBytes(frame)
            switch await stream.waitForAcknowledgement(timeout: 6) {
            case .acknowledged:
                return true
            case .rejected:
                continue                        // NAK: the receiver wants it again
            case .cancelled:
                return false                    // CAN: the receiver gave up
            case .timedOut:
                if attempt == 5 { return false }
                continue
            }
        }
        return false
    }
}

/// The device's side of a raw transfer, as bytes.
///
/// A plain buffer with `await`-able reads: the BLE delegate pushes chunks in from
/// the main actor, and the transfer pulls the bytes it expects. Waits are polled
/// rather than continuation-driven because every wait here is bounded and short,
/// and polling keeps the two sides from having to agree on cancellation.
@MainActor
final class ByteStream {
    private var buffer: [UInt8] = []

    enum Acknowledgement {
        case acknowledged
        case rejected
        case cancelled
        case timedOut
    }

    /// Called straight from `handleTX`, which already runs on the main actor.
    ///
    /// Deliberately synchronous: hopping through a `Task` per chunk would put the
    /// appends at the mercy of task scheduling order, and bytes that arrive out of
    /// order are indistinguishable from a corrupt block.
    func ingest(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Wait for ACK, NAK or CAN, ignoring the `C` bytes the receiver keeps
    /// emitting until the first data block lands.
    func waitForAcknowledgement(timeout: TimeInterval) async -> Acknowledgement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            while !buffer.isEmpty {
                let byte = buffer.removeFirst()
                switch byte {
                case YModem.ack: return .acknowledged
                case YModem.nak: return .rejected
                case YModem.can: return .cancelled
                default: continue                 // 'C' and any stray text
                }
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return .timedOut
    }

    /// Wait for one specific byte, discarding everything before it.
    func waitForByte(_ byte: UInt8, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = buffer.firstIndex(of: byte) {
                buffer.removeFirst(index + 1)
                return true
            }
            buffer.removeAll(keepingCapacity: true)   // nothing here matches; don't grow
            try? await Task.sleep(for: .milliseconds(15))
        }
        return false
    }

    /// Wait for a text marker, consuming everything through the end of its line.
    func waitForMarker(_ marker: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [UInt8] = []
        while Date() < deadline {
            if !buffer.isEmpty {
                seen.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                let text = String(decoding: seen, as: UTF8.self)
                if let range = text.range(of: marker) {
                    // Drop everything up to the newline that ends the banner, so the
                    // protocol phase starts on a clean stream. The firmware ends its
                    // lines with Arduino's `println`, i.e. CRLF — and Swift folds
                    // "\r\n" into a *single* Character, so a `== "\n"` test never
                    // matches it and the marker is found but never accepted. Match on
                    // `isNewline`, which sees the CRLF grapheme (and a lone CR or LF).
                    let rest = text[range.upperBound...]
                    if let newline = rest.firstIndex(where: { $0.isNewline }) {
                        let tail = rest[rest.index(after: newline)...]
                        buffer = Array(tail.utf8)
                        return true
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return false
    }

    /// Read text lines until one contains `marker` (or the timeout expires).
    func collectText(until marker: String, timeout: TimeInterval) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [UInt8] = []
        while Date() < deadline {
            if !buffer.isEmpty {
                seen.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if String(decoding: seen, as: UTF8.self).contains(marker) { break }
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return String(decoding: seen, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
