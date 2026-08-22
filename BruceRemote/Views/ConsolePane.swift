import SwiftUI

/// Read-only view over the shared TX/command stream, auto-scrolling to the tail.
///
/// Module screens (IR, Sub-GHz) embed this to show live device output without
/// duplicating the raw Terminal's scrolling logic.
struct ConsolePane: View {
    @EnvironmentObject private var ble: BLEManager
    var maxLines: Int = 200

    private var visibleLines: [TerminalLine] {
        ble.lines.suffix(maxLines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleLines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.kind == .sent ? Color.accentColor : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            // Darker than the surface it sits on, so the log reads as a well
            // rather than as more of the card around it.
            .background(BruceColor.bg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onChange(of: ble.lines.count) { _, _ in
                if let last = ble.lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}
