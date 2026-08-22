import SwiftUI
import UniformTypeIdentifiers

/// Browses the device filesystem over `storage list`, one directory per screen.
/// Supports creating folders, uploading text files, deleting entries, and drills
/// into files via `FileDetailView` (download / replay).
///
/// Only ever shows *one* filesystem: the firmware routes every `storage` command
/// to the SD card when a card is mounted and to LittleFS otherwise, with no way to
/// address the other one. The listing is therefore labelled with the filesystem it
/// came from, and the root shows both capacities so an empty folder on the SD is
/// not mistaken for a missing file in the internal memory. See `DeviceStorage`.
struct FileBrowserView: View {
    @EnvironmentObject private var ble: BLEManager

    /// Absolute directory path this screen lists. Root is "/".
    let path: String

    @State private var entries: [BruceFile] = []
    @State private var isLoading = false
    @State private var status: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showImporter = false
    /// Fraction of a binary (Y-modem) upload, or nil when none is running.
    @State private var transferProgress: Double?
    /// Human-readable readout beneath the bar: percent, bytes, speed and ETA.
    /// Refreshed on a wall-clock throttle, not on every one of the tens of
    /// thousands of block callbacks a large upload fires.
    @State private var transferDetail: String?

    init(path: String = "/") { self.path = path }

    private var isReady: Bool { ble.state == .ready }
    private var title: String { path == "/" ? L10n.t("Arquivos") : (path as NSString).lastPathComponent }

    var body: some View {
        List {
            if let status {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                        // A binary upload is one 128-byte block per round trip, so
                        // a big file takes long enough that a bar is the difference
                        // between "working" and "hung".
                        if let transferProgress {
                            ProgressView(value: transferProgress).tint(BruceColor.lilac)
                            if let transferDetail {
                                Text(transferDetail)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if path == "/" { storageSection }

            Section {
                if entries.isEmpty && !isLoading {
                    Text("Pasta vazia").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    row(for: entry)
                }
                .onDelete(perform: delete)
            } header: {
                HStack {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    if let active = ble.storageReport?.active {
                        Label(active.shortLabel, systemImage: active.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BruceColor.lilac)
                    }
                }
                .textCase(nil)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading { ProgressView() } }
        .refreshable { await ble.refreshStorageReport(force: true); await load() }
        .task(id: path) { await load() }
        .toolbar { toolbarContent }
        .alert("Nova pasta", isPresented: $showNewFolder) {
            TextField("nome", text: $newFolderName)
            Button("Criar", action: createFolder)
            Button("Cancelar", role: .cancel) {}
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
    }

    /// Both filesystems, with the active one marked — the answer to "estou vendo o
    /// cartão ou a memória interna?" without having to read the listing.
    @ViewBuilder
    private var storageSection: some View {
        if let report = ble.storageReport {
            Section {
                ForEach(DeviceStorage.allCases) { storage in
                    DeviceStorageRow(storage: storage, report: report)
                }
            } header: {
                Text("Armazenamento").textCase(nil)
            } footer: {
                Text(report.explanation).font(.caption)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: BruceFile) -> some View {
        if entry.isDirectory {
            NavigationLink {
                FileBrowserView(path: entry.path)
            } label: {
                Label(entry.name, systemImage: entry.systemImage)
            }
        } else {
            NavigationLink {
                FileDetailView(file: entry) { await load() }
            } label: {
                HStack {
                    Label(entry.name, systemImage: entry.systemImage)
                    Spacer()
                    if let s = entry.sizeLabel {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showImporter = true } label: { Image(systemName: "arrow.up.doc") }
                .disabled(!isReady)
            Button { newFolderName = ""; showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .disabled(!isReady)
        }
    }

    // MARK: - Actions

    private func load() async {
        guard isReady else { status = L10n.t("Conecte-se ao Bruce para navegar."); return }
        isLoading = true
        defer { isLoading = false }
        // Before listing, not after: the probe mounts a card inserted post-boot, and
        // the listing must come from whichever filesystem ends up active.
        await ble.refreshStorageReport()
        let lines = await ble.request(StorageCommand.list(path: path))
        entries = BruceFile.parseListing(lines, parent: path)
        status = nil
    }

    private func createFolder() {
        let name = newFolderName.trimmed
        guard isReady, !name.isEmpty else { return }
        Task {
            _ = await ble.request(StorageCommand.mkdir(path: BruceFile.join(path, name)))
            await load()
        }
    }

    private func delete(at offsets: IndexSet) {
        guard isReady else { return }
        let targets = offsets.map { entries[$0] }
        Task {
            for entry in targets {
                let command: StorageCommand = entry.isDirectory
                    ? .rmdir(path: entry.path)
                    : .remove(path: entry.path)
                _ = await ble.request(command)
            }
            await load()
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                status = L10n.t("Não foi possível ler o arquivo.")
                return
            }
            let dest = BruceFile.join(path, url.lastPathComponent)

            // Text keeps the plain `storage write` path — it is the one every other
            // screen uses. Anything that is not valid UTF-8 would be truncated at
            // the first stray byte there, so it goes over Y-modem instead.
            if let content = String(data: data, encoding: .utf8) {
                isLoading = true
                let reply = await ble.uploadTextFile(path: dest, content: content)
                isLoading = false
                status = reply.last ?? L10n.t("Enviado.")
            } else {
                await sendBinary(data, to: dest, name: url.lastPathComponent)
            }
            await load()
        }
    }

    private func sendBinary(_ data: Data, to dest: String, name: String) async {
        let total = data.count
        let start = Date()
        var lastRender = start
        transferProgress = 0
        transferDetail = nil
        status = L10n.t("Enviando \(name) (\(total.byteSizeLabel)) por Y-modem…")

        let failure = await ble.sendFileYModem(path: dest, data: data) { fraction in
            transferProgress = fraction
            // The callback fires once per 128-byte block — tens of thousands of
            // times for a multi-megabyte file. The bar can follow every one, but
            // the text readout only needs to refresh about twice a second to stay
            // legible, so throttle it on wall-clock time (and always on the last).
            let now = Date()
            guard now.timeIntervalSince(lastRender) >= 0.5 || fraction >= 1 else { return }
            lastRender = now
            transferDetail = Self.transferReadout(fraction: fraction, total: total, start: start, now: now)
        }

        transferProgress = nil
        transferDetail = nil
        status = failure ?? L10n.t("Enviado: \(dest)")
    }

    /// "12% · 0,8 MB de 7,0 MB · 3 KB/s · faltam 34 min".
    ///
    /// Speed is the average since the transfer began, not an instantaneous rate:
    /// a per-block link like this one is bursty, and an average is what gives a
    /// steady ETA instead of one that jumps every second.
    private static func transferReadout(fraction: Double, total: Int, start: Date, now: Date) -> String {
        let sent = Int(Double(total) * fraction)
        let percent = Int((fraction * 100).rounded())
        let elapsed = now.timeIntervalSince(start)

        // Too early to divide: the first blocks land before enough time has passed
        // for a rate to mean anything. Show what is known and wait.
        guard elapsed > 0.8, sent > 0 else {
            return "\(percent)% · \(sent.byteSizeLabel) de \(total.byteSizeLabel)"
        }
        let bytesPerSec = Double(sent) / elapsed
        let speed = Int(bytesPerSec).byteSizeLabel
        let remaining = Double(total - sent) / max(bytesPerSec, 1)
        return "\(percent)% · \(sent.byteSizeLabel) de \(total.byteSizeLabel) · \(speed)/s · faltam \(formatETA(remaining))"
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

#Preview {
    NavigationStack { FileBrowserView() }
        .environmentObject(BLEManager())
        .environmentObject(LibraryStore())
}
