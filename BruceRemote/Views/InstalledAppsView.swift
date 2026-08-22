import SwiftUI

/// Apps installed on the connected device, from the local ledger merged with the
/// device's own `/BruceAppStore/installed.json`. Each can be run or removed.
///
/// Removal deletes the app's files from the device and drops it from both ledgers.
/// Running and removing resolve the app's paths from the catalog on demand when
/// this phone didn't install it (so it only knows the version/commit).
struct InstalledAppsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ble: BLEManager

    @State private var status: String?
    @State private var pendingRemoval: String?

    private var isReady: Bool { ble.state == .ready }
    private var items: [(slug: String, record: InstalledApp)] { store.installedList }

    var body: some View {
        ZStack {
            BruceColor.backdrop.ignoresSafeArea()
            content
        }
        .navigationTitle("Instalados")
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar()
        .task(id: ble.state) {
            if ble.state == .ready { await store.syncInstalledFromDevice(using: ble) }
        }
        .confirmationDialog(
            pendingRemoval.map { L10n.t("Remover \(store.displayName(forSlug: $0))?") } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover do Bruce", role: .destructive) {
                if let slug = pendingRemoval { remove(slug) }
                pendingRemoval = nil
            }
            Button("Cancelar", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Apaga os arquivos do app no armazenamento do device.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            ContentUnavailableView(
                "Nada instalado",
                systemImage: "shippingbox",
                description: Text(isReady
                    ? "Instale apps pela loja para vê-los aqui."
                    : "Conecte-se ao Bruce para ver o que está instalado.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if let status {
                Section {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                .listRowBackground(BruceColor.surface)
            }

            Section {
                ForEach(items, id: \.slug) { item in
                    row(slug: item.slug, record: item.record)
                }
            } footer: {
                Text("O que este app e a loja do próprio Bruce registraram como instalado.")
                    .font(.caption)
            }
            .listRowBackground(BruceColor.surface)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await store.syncInstalledFromDevice(using: ble) }
    }

    private func row(slug: String, record: InstalledApp) -> some View {
        let busy = store.isBusy(slug: slug)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(store.displayName(forSlug: slug))
                    .font(.headline)
                Spacer()
                if busy { ProgressView() }
                Text("v\(record.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(slug)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 12) {
                Button {
                    run(slug)
                } label: {
                    Label("Rodar", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)
                .tint(BruceColor.purple)
                .disabled(!isReady || busy)

                Button(role: .destructive) {
                    pendingRemoval = slug
                } label: {
                    Label("Remover", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!isReady || busy)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func run(_ slug: String) {
        status = nil
        Task {
            let failure = await store.runInstalled(slug: slug, using: ble)
            status = failure ?? L10n.t("Rodando \(store.displayName(forSlug: slug)) no Bruce.")
        }
    }

    private func remove(_ slug: String) {
        status = nil
        let name = store.displayName(forSlug: slug)
        Task {
            let failure = await store.removeInstalled(slug: slug, using: ble)
            status = failure ?? L10n.t("\(name) removido do device.")
        }
    }
}

#Preview {
    NavigationStack { InstalledAppsView() }
        .environmentObject(BLEManager())
        .environmentObject(AppStore())
        .preferredColorScheme(.dark)
}
