import SwiftUI

/// Flipper-style IR manager, built only on the reliable device→phone direction:
/// - **Capturar**: `ir rx` → save the `.ir` to the phone library.
/// - **No device**: list the device's `.ir` files, transmit them (`ir tx_from_file`,
///   a single dependable command) and download offline copies.
/// - **Só no celular**: local captures not yet on the device.
///
/// Emulating a just-captured signal and saving it back to the device both need
/// the phone→device transfer, which the current firmware BLE RX mangles — those
/// are intentionally left out until that transport is fixed.
struct IRSyncView: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var library: LibraryStore

    private let folder = BruceFolder.ir

    @State private var deviceFiles: [BruceFile] = []
    @State private var loading = false
    @State private var status: String?
    @State private var capturing = false
    @State private var captureName = ""
    @State private var pendingCapture: String?   // reconstructed .ir awaiting an action
    @State private var pendingSummary = ""
    @State private var rawMode = false

    private var isReady: Bool { ble.state == .ready }

    private var localIR: [LibraryItem] { library.items.filter { $0.ext == "ir" } }
    private func isLocal(_ name: String) -> Bool { localIR.contains { $0.name == name } }

    private var deviceIR: [BruceFile] { deviceFiles.filter { $0.ext == "ir" } }
    private var localOnly: [LibraryItem] {
        localIR.filter { local in !deviceFiles.contains { $0.name == local.name } }
    }

    var body: some View {
        List {
            Section {
                Picker("Modo", selection: $rawMode) {
                    Text("Decodificado").tag(false)
                    Text("RAW (ar-cond.)").tag(true)
                }
                .pickerStyle(.segmented)

                Button {
                    capture()
                } label: {
                    Label(capturing ? L10n.t("Aponte o controle e pressione…") : L10n.t("Capturar do controle"),
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(!isReady || capturing || ble.isBusy)
            } footer: {
                Text("Ar-condicionado precisa de RAW: o replay pelo state decodificado não aciona o aparelho (o próprio Bruce força RAW nesses casos).")
            }

            if let content = pendingCapture {
                Section("Captura: \(pendingSummary)") {
                    TextField("nome", text: $captureName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        emulate(content)
                    } label: {
                        Label(ble.isBusy ? L10n.t("Emulando…") : L10n.t("Emular (testar)"), systemImage: "paperplane.fill")
                    }
                    .disabled(!isReady || ble.isBusy)
                    Button { saveLocal(content) } label: {
                        Label("Salvar no celular", systemImage: "iphone.and.arrow.forward")
                    }
                    Button { saveRemote(content) } label: {
                        Label("Salvar no device (+ cópia local)", systemImage: "externaldrive.badge.plus")
                    }
                    .disabled(!isReady || ble.isBusy)
                    Button(role: .destructive) { pendingCapture = nil } label: {
                        Label("Descartar", systemImage: "trash")
                    }
                }
            }

            if let status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }

            Section("No device (\(folder))") {
                if deviceIR.isEmpty && !loading {
                    Text(isReady ? L10n.t("Nenhum .ir aqui") : L10n.t("Conecte-se para listar"))
                        .foregroundStyle(.secondary)
                }
                ForEach(deviceIR) { file in
                    deviceRow(file)
                }
            }

            if !localOnly.isEmpty {
                Section {
                    ForEach(localOnly) { item in
                        NavigationLink {
                            LibraryItemDetailView(item: item)
                        } label: {
                            Label(item.name, systemImage: "iphone")
                        }
                    }
                } header: {
                    Text("Só no celular")
                } footer: {
                    Text("Abra um item para enviar ao device (Enviar ao Bruce) ou transmitir.")
                }
            }
        }
        .navigationTitle("Infravermelho")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!isReady || loading)
            }
        }
    }

    private func deviceRow(_ file: BruceFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                if isLocal(file.name) {
                    Label("cópia no celular", systemImage: "iphone")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                transmit(file)
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!isReady || ble.isBusy)

            if isLocal(file.name) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { download(file) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.borderless)
                    .disabled(!isReady)
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard isReady else { deviceFiles = []; return }
        loading = true
        defer { loading = false }
        let lines = await ble.request(StorageCommand.list(path: folder))
        deviceFiles = BruceFile.parseListing(lines, parent: folder)
    }

    private func transmit(_ file: BruceFile) {
        Task {
            loading = true
            defer { loading = false }
            let ok = await ble.transmitIRFile(path: file.path)
            status = ok
                ? L10n.t("Transmitido: \(file.name)")
                : L10n.t("Falha ao transmitir \(file.name).")
        }
    }

    private func download(_ file: BruceFile) {
        Task {
            loading = true
            let lines = await ble.request(StorageCommand.read(path: file.path), timeout: 20)
            loading = false
            let content = lines.joined(separator: "\n")
            if content.isEmpty {
                status = L10n.t("Falha ao ler \(file.name).")
            } else {
                _ = library.save(content: content, suggestedName: file.name)
                status = L10n.t("Baixado para o celular: \(file.name)")
            }
        }
    }

    private func capture() {
        Task {
            capturing = true
            status = nil
            let lines = await ble.request(rawMode ? IRCommand.rxRaw : IRCommand.rx, timeout: 15) { buffer in
                buffer.contains(where: IRCapture.isTerminalField)
            }
            capturing = false
            let cap = IRCapture.parse(lines)
            guard cap.isValid else {
                // Distinguish a genuine timeout/no-signal from a partial or
                // malformed capture so the user knows whether to retry or check
                // the firmware/BLE link.
                if cap.hasSignal {
                    status = L10n.t("Captura incompleta/malformada. Verifique o sinal e a conexão BLE.")
                } else if rawMode {
                    status = L10n.t("Nada capturado em RAW. Se o controle foi pressionado, pode ser sinal fraco ou limite do BLE (dump grande não fatiado). Tente de novo ou capture pelo menu IR do Bruce.")
                } else {
                    status = L10n.t("Nada capturado. Aponte o controle e tente de novo.")
                }
                return
            }

            // A parsed A/C capture cannot be replayed from its `state` — steer the
            // user to RAW, which is what Bruce's own IR Read does for these.
            if !rawMode && cap.hasState {
                rawMode = true
                pendingCapture = nil
                status = L10n.t("Ar-condicionado detectado (\(cap.protocolName ?? "?")). Mudei para RAW — capture de novo.")
                return
            }

            pendingCapture = cap.fileContent
            let proto: String
            switch cap.type {
            case "raw":
                proto = "RAW"
            case "parsed":
                proto = cap.protocolName ?? "parsed"
            default:
                proto = L10n.t("captura")
            }
            pendingSummary = cap.hasState ? "\(proto) · A/C" : proto
            captureName = proto.lowercased().replacingOccurrences(of: " ", with: "_")
            status = L10n.t("Capturado: \(pendingSummary). Emule para testar ou salve.")
        }
    }

    /// The `.ir` filename derived from the capture name field.
    private func normalizedName() -> String {
        var name = captureName.trimmed.isEmpty ? "captura" : captureName.trimmed
        if !name.hasSuffix(".ir") { name += ".ir" }
        return name
    }

    private func emulate(_ content: String) {
        Task {
            let reply = await ble.transmitIRBuffer(content: content)
            status = reply.isEmpty ? L10n.t("Falha ao emular (device não entrou em modo leitura).") : L10n.t("Emulado.")
        }
    }

    private func saveLocal(_ content: String) {
        let name = normalizedName()
        _ = library.save(content: content, suggestedName: name)
        status = L10n.t("Salvo no celular: \(name)")
        pendingCapture = nil
    }

    private func saveRemote(_ content: String) {
        Task {
            let name = normalizedName()
            let path = "/BruceIR/\(name)"
            loading = true
            let ok = await ble.saveTextFileVerified(path: path, content: content)
            loading = false
            if ok {
                _ = library.save(content: content, suggestedName: name)   // keep an offline copy too
                status = L10n.t("Salvo no device: \(path)")
                pendingCapture = nil
                await load()
            } else {
                status = L10n.t("Falha ao salvar no device.")
            }
        }
    }
}

#Preview {
    NavigationStack { IRSyncView() }
        .environmentObject(BLEManager())
        .environmentObject(LibraryStore())
}
