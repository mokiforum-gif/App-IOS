import SwiftUI

/// The connect / disconnect toolbar button, shared by every tab so the link is
/// always one tap away regardless of where the user is.
struct ConnectionButton: View {
    @EnvironmentObject private var ble: BLEManager

    var body: some View {
        switch ble.state {
        case .ready, .discovering, .connecting:
            Button("Desconectar", role: .destructive) { ble.disconnect() }
        case .scanning:
            Button("Parar") { ble.stopScan() }
        default:
            Button("Conectar") { ble.startScan() }
        }
    }
}

/// A one-line connection summary: a status dot, the state label, and the battery
/// reading when the device reports one.
struct ConnectionStatusBar: View {
    @EnvironmentObject private var ble: BLEManager

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(ble.state.label)
                .font(.subheadline)
            Spacer()
            if let battery = ble.batteryLevel {
                BatteryBadge(level: battery)
                    .font(.subheadline)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch ble.state {
        case .ready:                        return .green
        case .connecting, .discovering,
             .scanning:                     return .orange
        case .poweredOff, .unauthorized:    return .red
        default:                            return .secondary
        }
    }
}

/// Applies the connect/disconnect button to a tab's navigation bar.
extension View {
    func connectionToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) { ConnectionButton() }
        }
    }
}
