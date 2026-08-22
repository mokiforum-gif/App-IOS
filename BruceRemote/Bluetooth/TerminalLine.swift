import Foundation

/// A single line in the raw terminal, tagged by direction.
struct TerminalLine: Identifiable, Equatable {
    enum Kind {
        case sent      // command written to RX
        case received  // notification received on TX
    }

    let id = UUID()
    let text: String
    let kind: Kind
}
