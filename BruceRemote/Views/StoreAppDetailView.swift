import SwiftUI

/// Detail for a store app: description and provenance, then install / update / run
/// / remove against the connected Bruce.
///
/// Installing downloads the app's files (from `StoreClient`) and writes them under
/// `/BruceJS/<Category>` over BLE; running issues `js run_from_file`. Everything
/// that touches the device is gated on an active connection.
struct StoreAppDetailView: View {
    let app: StoreApp

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ble: BLEManager

    @State private var status: String?
    @State private var confirmRemove = false

    private var isReady: Bool { ble.state == .ready }
    private var isBusy: Bool { store.isBusy(app) }
    private var isInstalled: Bool { store.isInstalled(app) }
    private var updateAvailable: Bool { store.updateAvailable(for: app) }

    var body: some View {
        List {
            Section { header }
                .listRowBackground(BruceColor.surface)

            Section("Ações") {
                actions
                if !isReady {
                    Text("Conecte-se ao Bruce para instalar ou rodar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isBusy {
                    // A determinate bar only for the binary (Y-modem) path, which
                    // reports per-block fractions. Text uploads finish in one short
                    // write with no intermediate progress, so they get a spinner
                    // instead of a bar stuck at 0%.
                    if let progress = store.installProgress(for: app), progress > 0, progress < 1 {
                        ProgressView(value: progress) {
                            Text("Instalando… \(Int((progress * 100).rounded()))%")
                                .font(.caption)
                        }
                        .tint(BruceColor.purple)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().tint(BruceColor.purple)
                            Text("Instalando…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(BruceColor.surface)

            if let devices = app.supportedDevices, !devices.isEmpty {
                Section {
                    ForEach(devices, id: \.self) { device in
                        Label(device, systemImage: "cpu")
                            .font(.subheadline)
                    }
                } header: {
                    Text("Dispositivos suportados")
                } footer: {
                    Text("O autor lista estes dispositivos. Em outros, o app pode não funcionar.")
                        .font(.caption)
                }
                .listRowBackground(BruceColor.surface)
            }

            Section("Detalhes") {
                LabeledContent("Versão", value: app.version)
                if let record = store.installedRecord(for: app), record.version != app.version {
                    LabeledContent("Instalada", value: record.version)
                }
                LabeledContent("Categoria", value: app.category.isEmpty ? "—" : app.category)
                LabeledContent("Fonte", value: app.slug)
                    .font(.system(.body, design: .monospaced))
            }
            .listRowBackground(BruceColor.surface)
        }
        .scrollContentBackground(.hidden)
        .background(BruceColor.backdrop.ignoresSafeArea())
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar()
        .confirmationDialog("Remover \(app.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remover do Bruce", role: .destructive) { remove() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Apaga os arquivos do app no armazenamento do device.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(app.name)
                    .font(.title2.weight(.bold))
                Spacer()
                StoreInstallBadge(app: app)
            }
            Text(app.details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        if !isInstalled {
            installButton(title: L10n.t("Instalar"), systemImage: "square.and.arrow.down")
        } else {
            if updateAvailable {
                installButton(title: L10n.t("Atualizar para v\(app.version)"),
                              systemImage: "arrow.up.circle")
            }
            Button {
                status = nil
                Task {
                    let failure = await store.run(app, using: ble)
                    status = failure ?? L10n.t("Rodando no Bruce.")
                }
            } label: {
                Label("Rodar no Bruce", systemImage: "play.fill")
            }
            .disabled(!isReady || isBusy)

            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Label("Remover", systemImage: "trash")
            }
            .disabled(!isReady || isBusy)
        }
    }

    private func installButton(title: String, systemImage: String) -> some View {
        Button {
            install()
        } label: {
            Label(isBusy ? L10n.t("Instalando…") : title, systemImage: systemImage)
        }
        .disabled(!isReady || isBusy)
    }

    // MARK: - Operations

    private func install() {
        status = nil
        Task {
            let failure = await store.install(app, using: ble)
            status = failure ?? L10n.t("Instalado em /BruceJS/\(app.category).")
        }
    }

    private func remove() {
        status = nil
        Task {
            let failure = await store.remove(app, using: ble)
            status = failure ?? L10n.t("Removido do device.")
        }
    }
}

#Preview {
    NavigationStack {
        StoreAppDetailView(app: StoreApp(
            name: "Device Info",
            details: "Device information display showing hardware details and memory statistics",
            version: "1.0.1",
            slug: "emericklaw/Bruce-Device-Info-App/Device Info",
            supportedDevices: nil,
            category: "Tools"
        ))
    }
    .environmentObject(BLEManager())
    .environmentObject(AppStore())
    .preferredColorScheme(.dark)
}
