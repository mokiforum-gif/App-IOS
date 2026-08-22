import SwiftUI

/// The "Meu Bruce" tab: what the connected device *is* and how it is doing, plus
/// the three ways of driving it directly — remote control, terminal and files.
///
/// Everything here comes from the device's own report (`info`, `free`, `uptime`,
/// `date`) rather than from anything the app remembers, so a stale reading is
/// impossible: on disconnect `BLEManager` drops it and the screen says so.
struct MyBruceView: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore

    private var isReady: Bool { ble.state == .ready }
    private var status: DeviceStatus? { ble.deviceStatus }

    private var health: DeviceHealth {
        DeviceHealth.evaluate(status: status, storage: ble.storageReport)
    }

    private var healthTint: Color {
        switch health.level {
        case .ok:        return Color(hex: 0x3DDC84)   // green, as used by Sub-GHz
        case .attention: return Color(hex: 0xFFC53D)   // amber
        case .unknown:   return Color(hex: 0x8E8E93)   // grey
        }
    }

    /// Library items that belong in a device folder, and how many are there.
    ///
    /// Nil when the phone's library has nothing to compare — a "0/0" pill would
    /// be noise on a device that is perfectly in sync with an empty library.
    private var syncSummary: (text: String, systemImage: String, tint: Color)? {
        let items = library.items.filter { LibraryCategory.of($0).deviceFolder != nil }
        guard !items.isEmpty else { return nil }
        guard !ble.scannedFolders.isEmpty else {
            return (L10n.t("verificando…"), "icloud", Color(hex: 0x8E8E93))
        }
        let synced = items.filter { ble.syncState(for: $0) == .synced }.count
        let complete = synced == items.count
        return (L10n.t("\(synced)/\(items.count) sincronizados"),
                complete ? "checkmark.icloud.fill" : "icloud",
                complete ? BruceColor.azure : Color(hex: 0x8E8E93))
    }

    /// The device folders worth scanning: only those the library actually uses.
    private var libraryFolders: [String] {
        Array(Set(library.items.compactMap { LibraryCategory.of($0).deviceFolder }))
    }

    /// The link is being established — nothing can be asked of the device yet.
    private var isLinking: Bool {
        switch ble.state {
        case .scanning, .connecting, .discovering: return true
        default:                                   return false
        }
    }

    var body: some View {
        ZStack {
            BruceColor.backdrop.ignoresSafeArea()
            VStack(spacing: 0) {
                BruceLogoHeader()
                ConnectionStatusBar()
                list
            }
        }
        // No title: the wordmark below the bar already names the screen, and the
        // tab underneath repeats it — same reasoning as Módulos.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar()
        // Read once per connection, not per visit: the overview is six serial
        // round trips, and coming back to the tab (or any re-render) would pay
        // for them again. `deviceStatus` is nil exactly until the first read of
        // a session, and goes back to nil on disconnect. Anything fresher is on
        // the user's terms — pull to refresh.
        .task(id: ble.state) {
            guard isReady, ble.deviceStatus == nil else { return }
            await refresh()
        }
        .refreshable { await refresh(force: true) }
    }

    private var list: some View {
        List {
            Section { identityCard }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            shortcutsSection

            if isLinking {
                linkingSection
            } else if let step = ble.probeStep {
                loadingSection(current: step)
            } else if isReady {
                deviceSection; memorySection; storageSection; sessionSection
            } else {
                Section { Text("Conecte-se ao Bruce para ver as informações do dispositivo.") }
                    .listRowBackground(BruceColor.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .animation(.default, value: ble.probeStep)
    }

    // MARK: - Loading

    /// Before the link is up there is nothing to enumerate — just say where it is.
    private var linkingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(ble.state.label)
                Spacer()
            }
        } header: {
            Text("Conectando")
        }
        .listRowBackground(BruceColor.surface)
    }

    /// The library scan only runs when there is something to compare, so a row for
    /// it would otherwise sit unchecked forever.
    private var visibleSteps: [DeviceProbeStep] {
        libraryFolders.isEmpty
            ? DeviceProbeStep.allCases.filter { $0 != .library }
            : DeviceProbeStep.allCases
    }

    /// The overview read, step by step: done, in flight, still to come.
    ///
    /// Each step is its own serial round trip over a link that can take seconds,
    /// so naming the one in flight is the difference between "it is working" and
    /// "it is stuck".
    private func loadingSection(current: DeviceProbeStep) -> some View {
        Section {
            ForEach(visibleSteps) { step in
                HStack(spacing: 12) {
                    stepIcon(for: step, current: current)
                        .frame(width: 20)
                    Text(step.label)
                        .foregroundStyle(step > current ? .secondary : .primary)
                    Spacer()
                    if step == current {
                        Text(step.command)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Lendo o dispositivo")
        } footer: {
            Text("Cada item é um comando serial; o Bruce responde um de cada vez.")
                .font(.caption)
        }
        .listRowBackground(BruceColor.surface)
    }

    @ViewBuilder
    private func stepIcon(for step: DeviceProbeStep, current: DeviceProbeStep) -> some View {
        if step < current {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BruceColor.lilac)
        } else if step == current {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // The wordmark above already carries the shark, so the card leads
                // with the device's own name instead of repeating the logo.
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.deviceName ?? "Bruce")
                        .font(.title3.weight(.bold))
                    if let device = status?.info.device {
                        Text(device).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Battery lives in the status bar above; the card carries verdicts
                // instead — what the readings add up to, not one more raw number.
                if isReady {
                    StatusPill(text: health.label,
                               systemImage: health.systemImage,
                               tint: healthTint)
                }
            }

            if let version = status?.info.version {
                Text("Firmware \(version)")
                    .font(.caption.monospaced())
                    .foregroundStyle(BruceColor.lilac)
            }

            // Footer: how long it has been up and how fresh this reading is on the
            // left, the sync verdict on the right.
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    if let uptime = status?.uptime {
                        Label(uptime, systemImage: "clock.arrow.circlepath")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Tempo ligado"))
                            .accessibilityValue(uptime)
                    }
                    if let refreshed = ble.lastOverviewRefresh {
                        Text("Atualizado às \(refreshed.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if isReady, let sync = syncSummary {
                    StatusPill(text: sync.text,
                               systemImage: sync.systemImage,
                               tint: sync.tint)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BruceColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 4)
    }

    // MARK: - Sections

    /// Direct control of the device. The file browser is advanced-only: it writes
    /// to the same storage the firmware's own modules read from.
    private var shortcutsSection: some View {
        Section {
            NavigationLink {
                RemoteControlView()
            } label: {
                Label("Controle remoto", systemImage: "av.remote.fill")
            }
            .disabled(!isReady)

            NavigationLink {
                TerminalView()
                    .navigationTitle("Terminal")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Terminal", systemImage: "terminal")
            }

            NavigationLink {
                FirmwareView()
            } label: {
                Label("Firmware", systemImage: "arrow.triangle.2.circlepath")
            }

            if settings.advancedMode {
                NavigationLink {
                    FileBrowserView()
                } label: {
                    Label("Arquivos", systemImage: "folder")
                }
                .disabled(!isReady)
            }
        } header: {
            Text("Controle")
        }
        .listRowBackground(BruceColor.surface)
    }

    private var deviceSection: some View {
        Section {
            infoRow("Modelo", status?.info.device)
            infoRow("Firmware", status?.info.version)
            infoRow("Commit", status?.info.commit)
            infoRow("SDK", status?.info.sdk)
            infoRow("MAC", status?.info.mac)
            if let connected = status?.info.wifiConnected {
                infoRow("WiFi", connected ? L10n.t("conectado") : L10n.t("desconectado"))
            }
            infoRow("IP", status?.info.ip)
        } header: {
            Text("Dispositivo")
        }
        .listRowBackground(BruceColor.surface)
    }

    private var memorySection: some View {
        Section {
            if let memory = status?.memory, memory.freeHeap != nil {
                if let free = memory.freeHeap, let total = memory.totalHeap {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Heap")
                            Spacer()
                            Text("\(free.byteSizeLabel) / \(total.byteSizeLabel)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let used = memory.heapUsedFraction {
                            ProgressView(value: used).tint(BruceColor.lilac)
                        }
                    }
                } else {
                    infoRow("Heap livre", memory.freeHeap?.byteSizeLabel)
                }
                if let freePSRAM = memory.freePSRAM, let totalPSRAM = memory.totalPSRAM {
                    infoRow("PSRAM", "\(freePSRAM.byteSizeLabel) / \(totalPSRAM.byteSizeLabel)")
                } else if status?.memory.hasPSRAM == false {
                    infoRow("PSRAM", L10n.t("ausente"))
                }
            } else {
                Text("Sem leitura de memória.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Memória")
        }
        .listRowBackground(BruceColor.surface)
    }

    @ViewBuilder
    private var storageSection: some View {
        if let report = ble.storageReport {
            Section {
                ForEach(DeviceStorage.allCases) { storage in
                    DeviceStorageRow(storage: storage, report: report)
                }
            } header: {
                Text("Armazenamento")
            } footer: {
                Text(report.explanation).font(.caption)
            }
            .listRowBackground(BruceColor.surface)
        }
    }

    /// Uptime moved to the card; what is left is the device's own clock. Refreshing
    /// is the pull gesture — a button here would invite tapping it on every visit,
    /// which is exactly the traffic this screen no longer generates.
    private var sessionSection: some View {
        Section {
            infoRow("Relógio", status?.clock ?? L10n.t("não configurado"))
        } header: {
            Text("Sessão")
        }
        .listRowBackground(BruceColor.surface)
    }

    // MARK: - Helpers

    /// A label/value line, omitted entirely when the device did not report it —
    /// an empty row would read as "the device has no MAC", which is not the case.
    @ViewBuilder
    private func infoRow(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private func refresh(force: Bool = false) async {
        guard isReady else { return }
        await ble.refreshDeviceOverview(force: force, libraryFolders: libraryFolders)
    }
}

#Preview {
    NavigationStack { MyBruceView() }
        .environmentObject(BLEManager())
        .environmentObject(AppSettings())
        .environmentObject(LibraryStore())
        .preferredColorScheme(.dark)
}
