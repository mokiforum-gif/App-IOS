import CoreGraphics
import Foundation

/// The mirrored state of the Bruce display.
///
/// Bruce streams draw calls rather than pixels, so the current screen *is* the
/// list of calls needed to paint it. Ops accumulate in order and are replayed on
/// every render; a full-screen fill starts a new frame and discards what came
/// before, which is also what keeps the list from growing without bound.
///
/// This is a separate observable from `BLEManager` so that a burst of draw calls
/// only invalidates the mirror, not every view bound to the connection.
@MainActor
final class TFTScreen: ObservableObject {

    /// Draw calls to replay, oldest first.
    @Published private(set) var ops: [TFTOp] = []

    /// Panel resolution, replaced by the first `SCREEN_INFO` packet.
    ///
    /// The seed is the T-Embed CC1101's 320×170 in landscape; the firmware reports
    /// `width()`/`height()` after rotation, so no correction is needed here.
    @Published private(set) var size = CGSize(width: 320, height: 170)

    /// Whether the device is pushing draw calls (`display start`).
    @Published var isStreaming = false

    /// When the last draw call landed — drives the "no signal" placeholder.
    @Published private(set) var lastUpdate: Date?

    /// Ceiling on the replay list, for the pathological case of a screen that
    /// paints continuously without ever clearing. Oldest calls are dropped first.
    private static let maxOps = 4000

    /// How long draw calls are gathered before the view is invalidated. A menu
    /// repaint arrives as dozens of packets back to back; publishing each one
    /// separately would re-render the canvas dozens of times for a single frame.
    private static let coalesceInterval: TimeInterval = 0.05

    private var pending: [TFTOp] = []
    private var pendingSize: CGSize?
    /// Set when a fill lands mid-burst: the pending run replaces `ops` outright.
    private var pendingClearsFrame = false
    private var flushWork: DispatchWorkItem?

    // MARK: - Ingest

    /// Decodes a framed packet from the live stream and queues it for display.
    func ingest(packet: [UInt8]) {
        guard let op = TFTOp(packet: packet) else { return }
        apply(op)
    }

    /// Drops everything, for a disconnect or a fresh session.
    func clear() {
        flushWork?.cancel()
        flushWork = nil
        pending.removeAll()
        pendingSize = nil
        pendingClearsFrame = false
        ops.removeAll()
        lastUpdate = nil
        isStreaming = false
    }

    /// Whether an operation is one of the main menu's `<` `>` hints.
    ///
    /// `MenuItemInterface::drawArrows()` draws them as four 45° `drawWideLine`
    /// strokes pinned to the left and right margins, level with the icon. They say
    /// "there are more items sideways", which is exactly what the D-pad's left and
    /// right buttons already offer, so the mirror drops them. This is the one place
    /// it deliberately shows less than the device.
    ///
    /// The test stays narrow on purpose: the status bar's Bluetooth rune is also
    /// built from short 45° wide lines near an edge, and it has to survive. What
    /// separates them is height — the arrows sit below the status bar — and the
    /// stroke width, since `drawLine` never produces more than a hairline.
    private func isMainMenuArrow(_ op: TFTOp) -> Bool {
        guard case let .line(from, to, width, _) = op, width > 1 else { return false }

        let margin = size.width / 8
        let statusBarHeight: CGFloat = 30
        func nearSideEdge(_ x: CGFloat) -> Bool { x <= margin || x >= size.width - margin }

        guard nearSideEdge(from.x), nearSideEdge(to.x) else { return false }
        guard from.y > statusBarHeight, to.y > statusBarHeight else { return false }

        let (dx, dy) = (abs(to.x - from.x), abs(to.y - from.y))
        return dx > 0 && dx == dy
    }

    private func apply(_ op: TFTOp) {
        guard !isMainMenuArrow(op) else { return }

        switch op {
        case let .screenInfo(size, _):
            guard size.width > 0, size.height > 0 else { return }
            pendingSize = size

        case .fillScreen:
            // Everything already on screen is now covered, so the frame restarts
            // here instead of replaying calls that are no longer visible.
            pending = [op]
            pendingClearsFrame = true

        default:
            pending.append(op)
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: work)
    }

    private func flush() {
        flushWork = nil

        if let pendingSize {
            size = pendingSize
            self.pendingSize = nil
        }

        guard !pending.isEmpty else { return }

        if pendingClearsFrame {
            ops = pending
        } else {
            ops.append(contentsOf: pending)
            if ops.count > Self.maxOps {
                ops.removeFirst(ops.count - Self.maxOps)
            }
        }

        pending.removeAll(keepingCapacity: true)
        pendingClearsFrame = false
        lastUpdate = .now
    }
}
