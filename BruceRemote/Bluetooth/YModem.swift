import Foundation

/// Y-modem framing, as the Bruce firmware's receiver expects it.
///
/// The firmware (`ymodemReceiveCallback` in `storage_commands.cpp`) implements a
/// deliberately narrow subset, and the encoder matches it exactly:
///
/// - **128-byte blocks only.** `STX` (1024-byte blocks) is read and discarded —
///   "Reject STX and other headers" — so every block is `SOH`.
/// - **CRC-16/XMODEM**, polynomial `0x1021` seeded with `0x0000`, sent high byte
///   first. There is no checksum mode: the receiver only ever asks for `C`.
/// - **Header block (sequence 0)** carries `filename\0size\0`. The receiver
///   ignores the name (the path came from the command line) but uses the size to
///   trim the last block exactly, instead of guessing at `0x1A` padding.
/// - **No trailing null header.** Standard Y-modem ends a batch with a second
///   header block after `EOT`; this receiver closes the file and returns on
///   `EOT`, so sending one would land on a parser that is no longer listening.
enum YModem {
    static let soh: UInt8 = 0x01   // start of a 128-byte block
    static let eot: UInt8 = 0x04   // end of transmission
    static let ack: UInt8 = 0x06
    static let nak: UInt8 = 0x15
    static let can: UInt8 = 0x18   // cancel
    static let crcRequest: UInt8 = 0x43   // 'C', the receiver's "send me CRC mode"
    static let padding: UInt8 = 0x1A

    static let blockSize = 128

    /// CRC-16/XMODEM over `bytes`.
    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0x0000
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// One framed block: `SOH`, sequence, its complement, 128 bytes, CRC.
    ///
    /// `payload` is padded to the block size; short blocks only happen at the end
    /// of a file, where the receiver trims by the size from the header anyway.
    static func block(sequence: UInt8, payload: [UInt8]) -> Data {
        var body = payload
        if body.count < blockSize {
            body.append(contentsOf: [UInt8](repeating: padding, count: blockSize - body.count))
        }
        let checksum = crc16(body)

        var frame = Data([soh, sequence, sequence ^ 0xFF])
        frame.append(contentsOf: body)
        frame.append(UInt8(truncatingIfNeeded: checksum >> 8))
        frame.append(UInt8(truncatingIfNeeded: checksum))
        return frame
    }

    /// The sequence-0 block announcing name and size.
    ///
    /// The name is reduced to its last path component: Y-modem carries a bare
    /// filename, and the receiver already knows where the file goes.
    static func headerBlock(fileName: String, size: Int) -> Data {
        let name = (fileName as NSString).lastPathComponent
        var payload = Array(name.utf8)
        payload.append(0)
        payload.append(contentsOf: Array(String(size).utf8))
        payload.append(0)
        // The rest of a header block is zero-filled, not 0x1A-padded.
        if payload.count < blockSize {
            payload.append(contentsOf: [UInt8](repeating: 0, count: blockSize - payload.count))
        }
        return block(sequence: 0, payload: Array(payload.prefix(blockSize)))
    }

    /// Split `data` into the payloads of blocks 1…N.
    static func payloads(for data: Data) -> [[UInt8]] {
        stride(from: 0, to: max(data.count, 1), by: blockSize).map { offset in
            Array(data[offset..<min(offset + blockSize, data.count)])
        }
    }
}
