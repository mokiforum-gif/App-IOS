import SwiftUI

/// Detail for a single file: read its contents from the device (download),
/// export via the share sheet, replay `.sub`/`.ir` captures, or delete it.
struct FileDetailView: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let file: BruceFile
    /// Called after a destructive change so the browser can refresh.
    var onChange: () async -> Void

    @State private var content: String?
    @State private var exportURL: URL?
    @State private var isLoading = false
    @State private var status: String?

    private var isReady: Bool { ble.state == .ready }

    var body: some View {
        List {
            Section("Ações") {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Baixar / Exportar", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        library.save(content: content ?? "", suggestedName: file.name)
                        status = L10n.t("Salvo na biblioteca.")
                    } label: {
                        Label("Salvar na biblioteca", systemImage: "books.vertical")
                    }
                } else {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Ler do dispositivo", systemImage: "arrow.down.doc")
                    }
                    .disabled(!isReady || isLoading)
                }

                if file.isReplayable {
                    Button {
                        transmit()
                    } label: {
                        Label("Transmitir no dispositivo", systemImage: "paperplane.fill")
                    }
                    .disabled(!isReady)
                }

                Button(role: .destructive) {
                    remove()
                } label: {
                    Label("Apagar", systemImage: "trash")
                }
                .disabled(!isReady)
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
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading { ProgressView() } }
        .task { await load() }
    }

    // MARK: - Actions

    private func load() async {
        guard isReady else { return }
        isLoading = true
        defer { isLoading = false }
        let lines = await ble.request(StorageCommand.read(path: file.path), timeout: 20)
        let text = lines.joined(separator: "\n")
        content = text
        writeTempFile(text)
    }

    /// Persist the downloaded text to a temp file so `ShareLink` can export it.
    private func writeTempFile(_ text: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        do {
            try text.data(using: .utf8)?.write(to: url)
            exportURL = url
        } catch {
            status = L10n.t("Falha ao preparar exportação: \(error.localizedDescription)")
        }
    }

    private func transmit() {
        switch file.ext {
        case "ir":
            Task { await ble.transmitIRFile(path: file.path) }
        case "sub":
            ble.send(SubGHzCommand.txFromFile(path: file.path))
        default:
            break
        }
        status = L10n.t("Comando de transmissão enviado.")
    }

    private func remove() {
        Task {
            let reply = await ble.request(StorageCommand.remove(path: file.path))
            status = reply.last
            await onChange()
            dismiss()
        }
    }
}
