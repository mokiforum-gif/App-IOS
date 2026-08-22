import SwiftUI

/// Firmware update **checker**: shows the version the device reports against the
/// latest GitHub release, with the notes, and hands off to the web flasher.
///
/// It deliberately does not flash: the Bruce is flashed over USB (ESP Web Tools),
/// which iOS cannot do, and the firmware has no OTA to receive an image over WiFi
/// or BLE. So this informs and guides to a computer rather than pretending to
/// update from the phone.
struct FirmwareView: View {
    @EnvironmentObject private var ble: BLEManager

    @State private var state: LoadState = .idle
    @State private var release: FirmwareRelease?
    /// Installed version read on demand when the overview hasn't populated it yet.
    @State private var installedProbe: String?

    private enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    private var isReady: Bool { ble.state == .ready }
    private var installed: String? { ble.deviceStatus?.info.version ?? installedProbe }
    private var deviceName: String? { ble.deviceStatus?.info.device }

    private var updateStatus: Bool? {
        guard let release else { return nil }
        return FirmwareVersion.isUpdate(installed: installed, latest: release.tagName)
    }

    var body: some View {
        List {
            versionSection

            if let release, let notes = releaseNotes(release) {
                Section {
                    if let name = release.name, !name.isEmpty {
                        Text(name).font(.subheadline.weight(.semibold))
                    }
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Novidades")
                }
                .listRowBackground(BruceColor.surface)
            }

            flashSection
        }
        .scrollContentBackground(.hidden)
        .background(BruceColor.backdrop.ignoresSafeArea())
        .navigationTitle("Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar()
        .task { await loadIfNeeded() }
        .task(id: ble.state) { await probeInstalledIfNeeded() }
        .refreshable { await load(force: true) }
    }

    // MARK: - Versions

    private var versionSection: some View {
        Section {
            LabeledContent("Instalada") {
                Text(installed ?? (isReady ? "—" : L10n.t("conecte-se")))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Disponível") {
                switch state {
                case .loading, .idle:
                    ProgressView().controlSize(.small)
                case .failed:
                    Text("—").foregroundStyle(.secondary)
                case .loaded:
                    Text(release?.tagName ?? "—")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            statusRow
        } header: {
            Text("Versão")
        } footer: {
            if case .failed(let message) = state {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .listRowBackground(BruceColor.surface)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch updateStatus {
        case .some(true):
            Label("Atualização disponível", systemImage: "arrow.up.circle.fill")
                .foregroundStyle(Color(hex: 0xFFC53D))
                .font(.subheadline.weight(.semibold))
        case .some(false):
            Label("Firmware atualizado", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color(hex: 0x3DDC84))
                .font(.subheadline.weight(.semibold))
        case .none:
            if release != nil, installed == nil, isReady {
                Text("Não foi possível ler a versão instalada.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Flash handoff

    private var flashSection: some View {
        Section {
            Link(destination: FirmwareService.flasherURL) {
                Label("Abrir o flasher do Bruce", systemImage: "arrow.up.forward.app")
            }
            if let asset = release?.asset(forDeviceNamed: deviceName),
               let url = URL(string: asset.downloadURL) {
                Link(destination: url) {
                    Label("Baixar \(asset.name) (\(asset.size.byteSizeLabel))",
                          systemImage: "square.and.arrow.down")
                }
            }
            if let release, let url = URL(string: release.htmlURL) {
                Link(destination: url) {
                    Label("Ver a release no GitHub", systemImage: "safari")
                }
            }
        } header: {
            Text("Instalar")
        } footer: {
            Text("O flash é feito por um computador com Chrome e cabo USB — o iPhone não consegue gravar o firmware. Abra o flasher no computador, conecte o Bruce por USB e selecione a versão.")
                .font(.caption)
        }
        .listRowBackground(BruceColor.surface)
    }

    // MARK: - Loading

    /// Notes trimmed and capped so a very long changelog doesn't dominate the screen.
    private func releaseNotes(_ release: FirmwareRelease) -> String? {
        guard let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty
        else { return nil }
        let limit = 1200
        return body.count > limit ? String(body.prefix(limit)) + "…" : body
    }

    private func loadIfNeeded() async {
        if case .loaded = state { return }
        await load()
    }

    private func load(force: Bool = false) async {
        if case .loading = state, !force { return }
        state = .loading
        do {
            release = try await FirmwareService().latestRelease()
            state = .loaded
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription
                            ?? L10n.t("Falha de rede ao consultar o GitHub."))
        }
    }

    /// If connected but the overview hasn't run yet, read just `info` for the version.
    private func probeInstalledIfNeeded() async {
        guard isReady, ble.deviceStatus?.info.version == nil, installedProbe == nil else { return }
        let lines = await ble.request(SystemCommand.info, echo: false)
        installedProbe = DeviceInfo.parse(lines).version
    }
}

#Preview {
    NavigationStack { FirmwareView() }
        .environmentObject(BLEManager())
        .preferredColorScheme(.dark)
}
