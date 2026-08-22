import SwiftUI

/// Detail for a library item: a header card with its category and sync state,
/// then upload/replay to the connected Bruce, share, rename, favorite and delete.
struct LibraryItemDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    let item: LibraryItem

    @State private var uploadPath: String
    @State private var transmitAfterUpload = false
    @State private var status: String?
    @State private var isUploading = false
    @State private var showRename = false
    @State private var newName: String

    init(item: LibraryItem) {
        self.item = item
        // Default to the folder Bruce itself uses for each capture type, so
        // uploads land where the device's own modules look for them.
        let category = LibraryCategory.of(item)
        let folder = category.deviceFolder ?? ""
        _uploadPath = State(initialValue: "\(folder)/\(item.name)")
        _newName = State(initialValue: item.name)
    }

    private var isReady: Bool { ble.state == .ready }
    private var content: String? { library.content(of: item) }
    private var category: LibraryCategory { LibraryCategory.of(item) }
    private var sync: SyncState { ble.syncState(for: item) }
    /// The filesystem this item is being compared against and uploaded to.
    private var activeStorage: DeviceStorage? { ble.storageReport?.active }

    var body: some View {
        List {
            Section { header }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            Section("Enviar ao Bruce") {
                TextField("caminho no device", text: $uploadPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                if item.isReplayable {
                    Toggle("Transmitir após enviar", isOn: $transmitAfterUpload)
                }
                Button {
                    upload()
                } label: {
                    Label(isUploading ? L10n.t("Enviando…") : useLabel, systemImage: "arrow.up.doc")
                }
                .disabled(!isReady || isUploading)
                if !isReady {
                    Text("Conecte-se ao Bruce para enviar.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let activeStorage {
                    // The path field says nothing about *which* storage it lands on —
                    // the device decides that, and it is the same one being checked
                    // for the sync badge above.
                    Text("Destino: \(activeStorage.label).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Ações") {
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Compartilhar", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    library.toggleFavorite(item)
                } label: {
                    Label(item.isFavorite ? "Remover dos favoritos" : "Favoritar",
                          systemImage: item.isFavorite ? "star.slash" : "star")
                }
                Button {
                    newName = item.name; showRename = true
                } label: {
                    Label("Renomear", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    library.delete(item)
                    dismiss()
                } label: {
                    Label("Apagar", systemImage: "trash")
                }
            }

            if let status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }

            if let content {
                Section("Conteúdo") {
                    Text(content.isEmpty ? L10n.t("(vazio)") : content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await ble.refreshStorageReport() }
        .alert("Renomear", isPresented: $showRename) {
            TextField("nome", text: $newName)
            Button("Salvar") { library.rename(item, to: newName); dismiss() }
            Button("Cancelar", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                categoryBadge
                Spacer()
                syncBadge
            }

            Text(item.name)
                .font(.title3.weight(.bold))
                .lineLimit(3)

            HStack(spacing: 16) {
                metric("Tamanho", item.sizeLabel)
                metric("Modificado", item.modified.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BruceColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var categoryBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: category.systemImage).font(.system(size: 12, weight: .bold))
            Text(category.title).font(.caption.weight(.bold))
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(category.color, in: Capsule())
    }

    private var syncBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: sync.systemImage)
                Text(sync.label)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(sync.color)
            // Naming the folder that was checked turns a bare "not synced" into
            // something diagnosable against what the device actually holds — and
            // the storage matters as much as the folder, since the device exposes
            // only one filesystem at a time (`DeviceStorage`).
            if let folder = category.deviceFolder {
                Text(activeStorage.map { "\(folder) · \($0.shortLabel)" } ?? folder)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }

    /// "Enviar e transmitir" reads better than "Enviar" when the toggle is on.
    private var useLabel: String {
        item.isReplayable && transmitAfterUpload ? L10n.t("Enviar e transmitir") : L10n.t("Enviar ao Bruce")
    }

    /// The library item's own file URL is already share-ready.
    private var exportURL: URL? { item.url }

    private func upload() {
        guard let content, isReady else { return }
        let path = uploadPath.trimmed
        guard !path.isEmpty else { return }
        Task {
            isUploading = true
            let reply = await ble.uploadTextFile(path: path, content: content)
            status = reply.last ?? L10n.t("Enviado.")
            if transmitAfterUpload {
                switch item.ext {
                case "ir":
                    Task { await ble.transmitIRFile(path: path) }
                case "sub":
                    ble.send(SubGHzCommand.txFromFile(path: path))
                default:
                    break
                }
            }
            // Reflect the new file on the device in the sync badge.
            if let folder = category.deviceFolder {
                await ble.refreshDeviceIndex(folders: [folder])
            }
            isUploading = false
        }
    }
}
