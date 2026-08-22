import SwiftUI

/// Replays Bruce's logged draw calls, reconstructing the device screen.
///
/// The device sends vector operations rather than pixels (see `TFTFrame.swift`),
/// so the mirror is resolution independent: the canvas scales the device's
/// coordinate space up to whatever space the layout gives it, and text stays sharp
/// instead of turning into magnified 6×8 blocks.
struct TFTCanvas: View {

    let ops: [TFTOp]
    /// Device resolution the operations are expressed in.
    let deviceSize: CGSize

    /// TFT_eSPI's built-in GLCD font occupies a 6×8 cell per glyph at text size 1.
    /// Placing characters on that pitch, rather than trusting the host font's own
    /// advance, is what keeps mirrored labels aligned with the device — it matters
    /// most for centred and right-aligned strings, where accumulated drift moves
    /// the whole run.
    private static let glyphWidth: CGFloat = 6
    private static let glyphHeight: CGFloat = 8

    /// Point size that fills the 6×8 cell. A monospaced face renders roughly 0.7
    /// of its point size as cap height and advances 0.6 of it, so 10 points per
    /// unit of text size matches the device's ink height and its 6-pixel pitch at
    /// the same time.
    private static let glyphPointSize: CGFloat = 10

    /// Identifies a glyph that can be resolved once and stamped repeatedly.
    private struct GlyphKey: Hashable {
        let character: Character
        let size: Int
        let color: UInt16
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard deviceSize.width > 0, deviceSize.height > 0 else { return }

            let bounds = CGRect(origin: .zero, size: deviceSize)
            let scale = min(size.width / deviceSize.width, size.height / deviceSize.height)
            context.scaleBy(x: scale, y: scale)
            context.clip(to: Path(bounds))

            // The panel is never transparent, and this also covers the case of a
            // mirror that has not received its first frame yet.
            context.fill(Path(bounds), with: .color(.black))

            var glyphs: [GlyphKey: GraphicsContext.ResolvedText] = [:]
            for op in ops {
                draw(op, in: &context, glyphs: &glyphs)
            }
        }
        .aspectRatio(deviceSize.width / deviceSize.height, contentMode: .fit)
    }

    private func draw(
        _ op: TFTOp,
        in context: inout GraphicsContext,
        glyphs: inout [GlyphKey: GraphicsContext.ResolvedText]
    ) {
        switch op {
        case .screenInfo:
            break   // resolution is handled by the model, not the canvas

        case let .fillScreen(color):
            context.fill(Path(CGRect(origin: .zero, size: deviceSize)),
                         with: .color(Color(rgb565: color)))

        case let .rect(rect, color, filled):
            paint(Path(rect.standardized), color: color, filled: filled, in: &context)

        case let .roundRect(rect, radius, color, filled):
            paint(Path(roundedRect: rect.standardized, cornerRadius: max(0, radius)),
                  color: color, filled: filled, in: &context)

        case let .ellipse(box, color, filled):
            paint(Path(ellipseIn: box.standardized), color: color, filled: filled, in: &context)

        case let .triangle(a, b, c, color, filled):
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
            path.closeSubpath()
            paint(path, color: color, filled: filled, in: &context)

        case let .line(from, to, width, color):
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            context.stroke(path, with: .color(Color(rgb565: color)), lineWidth: width)

        case let .arc(center, radius, width, start, end, color):
            var path = Path()
            path.addArc(center: center, radius: max(0, radius),
                        startAngle: .degrees(start), endAngle: .degrees(end),
                        clockwise: false)
            context.stroke(path, with: .color(Color(rgb565: color)), lineWidth: width)

        case let .text(string, origin, textSize, color, background, align):
            drawText(string, at: origin, textSize: textSize, color: color,
                     background: background, align: align, in: &context, glyphs: &glyphs)
        }
    }

    private func paint(_ path: Path, color: UInt16, filled: Bool, in context: inout GraphicsContext) {
        let style = GraphicsContext.Shading.color(Color(rgb565: color))
        if filled {
            context.fill(path, with: style)
        } else {
            context.stroke(path, with: style, lineWidth: 1)
        }
    }

    private func drawText(
        _ string: String,
        at origin: CGPoint,
        textSize: Int,
        color: UInt16,
        background: UInt16,
        align: TFTTextAlign,
        in context: inout GraphicsContext,
        glyphs: inout [GlyphKey: GraphicsContext.ResolvedText]
    ) {
        let scale = CGFloat(textSize)
        let advance = Self.glyphWidth * scale
        let lineHeight = Self.glyphHeight * scale
        let runWidth = advance * CGFloat(string.count)

        // The logged point is the string's leading, centre or trailing edge
        // depending on which draw call produced it; glyphs always run left to right
        // from the resulting left edge.
        let startX: CGFloat
        switch align {
        case .leading:  startX = origin.x
        case .center:   startX = origin.x - runWidth / 2
        case .trailing: startX = origin.x - runWidth
        }

        // The firmware carries the same value in both colors when text is drawn
        // without an explicit background. Bruce's UI assumes black there, and its
        // own reference renderer resolves it the same way.
        let fill = background == color ? 0 : background
        context.fill(
            Path(CGRect(x: startX, y: origin.y, width: runWidth, height: lineHeight)),
            with: .color(Color(rgb565: fill))
        )

        let font = Font.system(size: Self.glyphPointSize * scale, design: .monospaced)
        let foreground = Color(rgb565: color)

        for (index, character) in string.enumerated() {
            guard !character.isWhitespace else { continue }
            let key = GlyphKey(character: character, size: textSize, color: color)
            let glyph: GraphicsContext.ResolvedText
            if let cached = glyphs[key] {
                glyph = cached
            } else {
                glyph = context.resolve(
                    Text(String(character)).font(font).foregroundStyle(foreground)
                )
                glyphs[key] = glyph
            }
            context.draw(
                glyph,
                at: CGPoint(x: startX + advance * (CGFloat(index) + 0.5),
                            y: origin.y + lineHeight / 2),
                anchor: .center
            )
        }
    }
}

extension Color {
    /// Expands a 16-bit RGB565 value — the color format the display driver, and so
    /// the draw log, works in natively.
    init(rgb565: UInt16) {
        self.init(
            .sRGB,
            red: Double((rgb565 >> 11) & 0x1F) / 31,
            green: Double((rgb565 >> 5) & 0x3F) / 63,
            blue: Double(rgb565 & 0x1F) / 31,
            opacity: 1
        )
    }
}
