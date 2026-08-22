import SwiftUI

/// The Bruce wordmark + shark, used as the header of the app's top-level screens.
struct BruceLogoHeader: View {
    var height: CGFloat = 68

    var body: some View {
        Image("BruceLogo")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .accessibilityLabel("Bruce")
    }
}

/// The device's battery level, with an icon that empties as the charge drops.
///
/// The Bruce reports a percentage over the Battery Service and nothing else — no
/// charging flag — so the symbol is picked purely from the level, rounded to the
/// nearest quarter the SF Symbols set provides. The colour only departs from the
/// brand accent when the reading is worth acting on.
struct BatteryBadge: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            Text("\(level)%")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Bateria"))
        .accessibilityValue(Text("\(level)%"))
    }

    /// SF Symbols only ships quarter steps, so the level is snapped to the nearest.
    private var symbol: String {
        switch level {
        case ..<13:  return "battery.0percent"
        case ..<38:  return "battery.25percent"
        case ..<63:  return "battery.50percent"
        case ..<88:  return "battery.75percent"
        default:     return "battery.100percent"
        }
    }

    private var tint: Color {
        switch level {
        case ..<11: return .red
        case ..<26: return Color(hex: 0xFFC53D)   // amber, as used by the sniffer badge
        default:    return BruceColor.lilac
        }
    }
}

/// A small tinted capsule: icon + short text. Used for the device's health and
/// library-sync summaries on the "Meu Bruce" card.
struct StatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        // Tinted fill rather than a solid one: two pills side by side should read
        // as status, not as two buttons competing with the card's own surface.
        .background(tint.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        BruceLogoHeader()
        ForEach([100, 80, 55, 30, 20, 5], id: \.self) { BatteryBadge(level: $0) }
        HStack {
            StatusPill(text: "Tudo certo", systemImage: "checkmark.seal.fill",
                       tint: Color(hex: 0x3DDC84))
            StatusPill(text: "12/14 sincronizados", systemImage: "checkmark.icloud.fill",
                       tint: BruceColor.azure)
        }
    }
    .padding()
    .background(BruceColor.backdrop)
    .preferredColorScheme(.dark)
}
