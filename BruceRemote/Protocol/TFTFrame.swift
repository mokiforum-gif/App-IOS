import CoreGraphics
import Foundation

/// Decoding of Bruce's TFT draw log — the transport behind the screen mirror.
///
/// The firmware wraps its display driver in a logger (`include/tftLogger.h`) that
/// records every draw call as a compact binary packet instead of shipping a
/// framebuffer. `display start` pushes packets as the UI paints them; `display
/// dump` re-sends the whole current screen. Because the logger drops entries that
/// later draws paint over (`removeLogEntriesInsideRect`), a dump reconstructs the
/// complete screen rather than a delta.
///
/// Packet layout, all multi-byte fields big-endian:
///
///     0xAA │ size │ fn │ args…
///
/// `size` counts the whole packet including the three header bytes, so the
/// argument block is `size - 3` bytes long.

// MARK: - Functions

/// Draw calls the firmware logs, matching `enum tftFuncs` in `include/tftLogger.h`.
///
/// The firmware comment reads "DO NOT CHANGE THE ORDER, ADD NEW FUNCTIONS TO THE
/// END", so these raw values are a stable wire contract.
enum TFTFunc: UInt8 {
    case fillScreen = 0
    case drawRect = 1
    case fillRect = 2
    case drawRoundRect = 3
    case fillRoundRect = 4
    case drawCircle = 5
    case fillCircle = 6
    case drawTriangle = 7
    case fillTriangle = 8
    case drawEllipse = 9
    case fillEllipse = 10
    case drawLine = 11
    case drawArc = 12
    case drawWideLine = 13
    case drawCentreString = 14
    case drawRightString = 15
    case drawString = 16
    case print = 17
    case drawImage = 18
    case drawPixel = 19
    case drawFastVLine = 20
    case drawFastHLine = 21
    case screenInfo = 99

    /// One argument slot in the packet body.
    enum Field {
        case word    // big-endian uint16
        case byte
        case rest    // string filling whatever is left of the packet
    }

    /// Argument layout, in declaration order.
    ///
    /// Mirrors the `keysMap` table in the firmware's own reference renderer,
    /// `sd_files/esp32_serial_navigator.html`, cross-checked against the
    /// `checkAndLog` call sites in `src/core/tftLogger/tftLogger.cpp`.
    var layout: [Field] {
        switch self {
        case .fillScreen:                              return [.word]                          // fg
        case .drawPixel:                               return [.word, .word, .word]            // x y fg
        case .drawCircle, .fillCircle:                 return Array(repeating: .word, count: 4) // x y r fg
        case .drawFastVLine:                           return Array(repeating: .word, count: 4) // x y h fg
        case .drawFastHLine:                           return Array(repeating: .word, count: 4) // x y w fg
        case .drawRect, .fillRect:                     return Array(repeating: .word, count: 5) // x y w h fg
        case .drawEllipse, .fillEllipse:               return Array(repeating: .word, count: 5) // x y rx ry fg
        case .drawLine:                                return Array(repeating: .word, count: 5) // x y x1 y1 fg
        case .drawRoundRect, .fillRoundRect:           return Array(repeating: .word, count: 6) // x y w h r fg
        case .drawTriangle, .fillTriangle:             return Array(repeating: .word, count: 7) // x y x2 y2 x3 y3 fg
        case .drawWideLine:                            return Array(repeating: .word, count: 7) // x y bx by wd fg bg
        case .drawArc:                                 return Array(repeating: .word, count: 8) // x y r ir start end fg bg
        case .drawCentreString, .drawRightString,
             .drawString, .print:                      return [.word, .word, .word, .word, .word, .rest] // x y size fg bg txt
        case .drawImage:                               return [.word, .word, .word, .word, .byte, .rest] // x y center ms fs path
        case .screenInfo:                              return [.word, .word, .byte]            // w h rotation
        }
    }
}

// MARK: - Raw packet

/// A framed packet with its arguments pulled apart, before they gain meaning.
struct TFTPacket {
    let function: TFTFunc
    /// Numeric arguments in declaration order.
    let values: [Int]
    /// Trailing string argument, for the text and image calls.
    let text: String?

    /// Decodes one complete `0xAA` packet. Returns `nil` if the opcode is unknown
    /// or the body is shorter than its layout requires.
    init?(packet: [UInt8]) {
        guard packet.count >= 3,
              packet[0] == TFTStreamDemuxer.header,
              let function = TFTFunc(rawValue: packet[2])
        else { return nil }

        var values: [Int] = []
        var text: String?
        var index = 3

        for field in function.layout {
            switch field {
            case .word:
                guard index + 1 < packet.count else { return nil }
                values.append(Int(packet[index]) << 8 | Int(packet[index + 1]))
                index += 2
            case .byte:
                guard index < packet.count else { return nil }
                values.append(Int(packet[index]))
                index += 1
            case .rest:
                // Firmware payloads are ASCII; decode leniently so a stray byte
                // costs one glyph instead of the whole label.
                text = String(decoding: packet[index...], as: UTF8.self)
                index = packet.count
            }
        }

        self.function = function
        self.values = values
        self.text = text
    }

    /// Argument at `index`, reinterpreted as signed.
    ///
    /// The firmware truncates `int32_t` coordinates to 16 bits (`writeUint16`), so
    /// anything drawn at a negative offset — a label scrolled past the left edge,
    /// say — arrives wrapped around 65536 and has to be folded back.
    func coordinate(_ index: Int) -> CGFloat {
        guard index < values.count else { return 0 }
        return CGFloat(Int16(bitPattern: UInt16(truncatingIfNeeded: values[index])))
    }

    /// Argument at `index` as an unsigned value — colors, text size, arc angles.
    func raw(_ index: Int) -> Int {
        index < values.count ? values[index] : 0
    }

    /// Argument at `index` as an RGB565 color.
    func color(_ index: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: raw(index))
    }
}

// MARK: - Semantic operations

/// Where a string sits relative to its anchor point.
enum TFTTextAlign {
    case leading, center, trailing
}

/// A decoded draw call, in the terms the renderer needs.
enum TFTOp {
    /// Device resolution. The firmware emits this ahead of every dump and when the
    /// live stream starts, so the mirror never has to guess the panel size.
    case screenInfo(size: CGSize, rotation: Int)
    case fillScreen(color: UInt16)
    case rect(CGRect, color: UInt16, filled: Bool)
    case roundRect(CGRect, radius: CGFloat, color: UInt16, filled: Bool)
    case ellipse(in: CGRect, color: UInt16, filled: Bool)
    case triangle(CGPoint, CGPoint, CGPoint, color: UInt16, filled: Bool)
    case line(from: CGPoint, to: CGPoint, width: CGFloat, color: UInt16)
    case arc(center: CGPoint, radius: CGFloat, width: CGFloat,
             start: Double, end: Double, color: UInt16)
    case text(String, at: CGPoint, textSize: Int,
              color: UInt16, background: UInt16, align: TFTTextAlign)

    /// Builds the drawable form of a framed packet, or `nil` when there is nothing
    /// to draw — an unknown opcode, a truncated body, or `drawImage`, which
    /// references a file on the device's own storage that the app cannot resolve.
    init?(packet raw: [UInt8]) {
        guard let p = TFTPacket(packet: raw) else { return nil }

        /// Rectangle from an `x, y, w, h` run starting at `index`.
        func rect(_ index: Int) -> CGRect {
            CGRect(x: p.coordinate(index), y: p.coordinate(index + 1),
                   width: p.coordinate(index + 2), height: p.coordinate(index + 3))
        }
        func point(_ index: Int) -> CGPoint {
            CGPoint(x: p.coordinate(index), y: p.coordinate(index + 1))
        }

        switch p.function {
        case .screenInfo:
            self = .screenInfo(
                size: CGSize(width: p.coordinate(0), height: p.coordinate(1)),
                rotation: p.raw(2)
            )

        case .fillScreen:
            self = .fillScreen(color: p.color(0))

        case .drawRect, .fillRect:
            self = .rect(rect(0), color: p.color(4), filled: p.function == .fillRect)

        case .drawRoundRect, .fillRoundRect:
            self = .roundRect(rect(0), radius: p.coordinate(4),
                              color: p.color(5), filled: p.function == .fillRoundRect)

        case .drawCircle, .fillCircle:
            let r = p.coordinate(2)
            let box = CGRect(x: p.coordinate(0) - r, y: p.coordinate(1) - r,
                             width: r * 2, height: r * 2)
            self = .ellipse(in: box, color: p.color(3), filled: p.function == .fillCircle)

        case .drawEllipse, .fillEllipse:
            let (rx, ry) = (p.coordinate(2), p.coordinate(3))
            let box = CGRect(x: p.coordinate(0) - rx, y: p.coordinate(1) - ry,
                             width: rx * 2, height: ry * 2)
            self = .ellipse(in: box, color: p.color(4), filled: p.function == .fillEllipse)

        case .drawTriangle, .fillTriangle:
            self = .triangle(point(0), point(2), point(4),
                             color: p.color(6), filled: p.function == .fillTriangle)

        case .drawLine:
            self = .line(from: point(0), to: point(2), width: 1, color: p.color(4))

        case .drawWideLine:
            self = .line(from: point(0), to: point(2),
                         width: max(1, p.coordinate(4)), color: p.color(5))

        case .drawArc:
            // TFT_eSPI draws arcs "clockwise from 6 o'clock" (see `drawArc` in
            // `lib/TFT_eSPI/TFT_eSPI.cpp`), whereas the renderer's zero is at 3
            // o'clock. Both sweep clockwise on screen, so the only correction is a
            // quarter turn forward. Getting this sign wrong rotates every arc by a
            // half turn, which reads as a mirrored icon: the WiFi fan (130°–230°,
            // opening up) flips down, and the IR and Bluetooth waves (220°–320°,
            // pointing right) flip to the left.
            let (outer, inner) = (p.coordinate(2), p.coordinate(3))
            self = .arc(
                center: point(0),
                radius: (outer + inner) / 2,
                width: max(1, outer - inner),
                start: Double(p.raw(4)) + 90,
                end: Double(p.raw(5)) + 90,
                color: p.color(6)
            )

        // 1-pixel primitives are filled rectangles rather than hairline strokes, so
        // they land on exact pixel boundaries when the mirror is scaled up.
        case .drawPixel:
            self = .rect(CGRect(x: p.coordinate(0), y: p.coordinate(1), width: 1, height: 1),
                         color: p.color(2), filled: true)

        case .drawFastVLine:
            self = .rect(CGRect(x: p.coordinate(0), y: p.coordinate(1),
                                width: 1, height: p.coordinate(2)),
                         color: p.color(3), filled: true)

        case .drawFastHLine:
            self = .rect(CGRect(x: p.coordinate(0), y: p.coordinate(1),
                                width: p.coordinate(2), height: 1),
                         color: p.color(3), filled: true)

        case .drawCentreString, .drawRightString, .drawString, .print:
            guard let string = p.text, !string.isEmpty else { return nil }
            let align: TFTTextAlign =
                p.function == .drawCentreString ? .center
                : p.function == .drawRightString ? .trailing
                : .leading
            self = .text(
                string.replacingOccurrences(of: "\n", with: ""),
                at: point(0),
                textSize: max(1, p.raw(2)),
                color: p.color(3),
                background: p.color(4),
                align: align
            )

        case .drawImage:
            return nil
        }
    }
}

// MARK: - Framing

/// Separates Bruce's mixed serial output into text and TFT draw packets.
///
/// With the screen stream running, the device interleaves binary packets with
/// ordinary command output on the same characteristic. Splitting has to happen at
/// the byte level: decoding a chunk as UTF-8 first would fail outright the moment
/// it contains packet bytes, taking the text with it.
struct TFTStreamDemuxer {
    /// Marks the start of a draw packet (`LOG_PACKET_HEADER` in the firmware).
    static let header: UInt8 = 0xAA

    private var buffer: [UInt8] = []

    /// Accepts received bytes and returns whatever is now complete.
    ///
    /// A partial packet stays buffered until the rest of it arrives. A `0xAA` that
    /// turns out not to start a valid packet — it is also a UTF-8 continuation
    /// byte, so ordinary text can contain one — is released as text.
    mutating func consume(_ data: Data) -> (text: [UInt8], packets: [[UInt8]]) {
        buffer.append(contentsOf: data)

        var text: [UInt8] = []
        var packets: [[UInt8]] = []

        loop: while let first = buffer.first {
            guard first == Self.header else {
                let run = buffer.firstIndex(of: Self.header) ?? buffer.count
                text.append(contentsOf: buffer[..<run])
                buffer.removeFirst(run)
                continue
            }

            // Judge the candidate from its size and opcode alone, before waiting for
            // the body: a packet spans at least a header plus an opcode, and that
            // opcode has to be one the firmware actually emits. Anything else is
            // text that merely contains 0xAA — a UTF-8 continuation byte, as in
            // "1ª" — so release the byte and resynchronise on the next one. Waiting
            // for `size` bytes first would strand the rest of the line behind a
            // packet that was never going to arrive.
            guard buffer.count >= 3 else { break loop }
            let size = Int(buffer[1])
            guard size >= 3, TFTFunc(rawValue: buffer[2]) != nil else {
                text.append(buffer.removeFirst())
                continue
            }
            guard buffer.count >= size else { break loop } // body still in flight

            packets.append(Array(buffer[..<size]))
            buffer.removeFirst(size)
        }

        return (text, packets)
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

// Note: the firmware's other route to the screen, `display dump`, is deliberately
// unused. Its callback allocates a `MAX_LOG_ENTRIES * MAX_LOG_SIZE` buffer on the
// stack — 8192 bytes on a PSRAM board, the whole of `SERIAL_CMDS_TASK_STACK_SIZE`
// — and resets the device. The live stream carries the same information.
