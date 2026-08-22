import SwiftUI

/// One filesystem line: how full it is, and whether it is the one the device is
/// actually using. Shared by the file browser and "Meu Bruce" so both describe the
/// storage the same way.
struct DeviceStorageRow: View {
    let storage: DeviceStorage
    let report: DeviceStorageReport

    private var isActive: Bool { report.active == storage }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: storage.systemImage)
                .foregroundStyle(isActive ? BruceColor.lilac : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(storage.label)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("em uso")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(BruceColor.lilac, in: Capsule())
            }
        }
    }

    private var detail: String {
        if let space = report.space(for: storage) { return space.summary }
        return storage == .sd ? L10n.t("Nenhum cartão montado") : L10n.t("Indisponível")
    }
}
