import SwiftUI

/// NFC / RFID manager, built on the firmware's `rfid` command family.
///
/// The driver on the device keeps **one** tag in memory, so everything here is
/// two-step: put a tag in that slot (`rfid read` from the reader, or
/// `rfid loadfile` from a saved dump), then act on it — emulate, clone, write
/// back, or save. The screen mirrors that: a "current tag" card on top, and the
/// device's `/BruceRFID` files below.
///
/// Captures are rebuilt into `.rfid` locally (`RFIDTag.fileContent`) rather than
/// downloaded after saving, because the firmware renames on collision and never
/// reports the name it chose.
struct RFIDView: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var library: LibraryStore

    private let folder = BruceFolder.rfid

    @State private var deviceFiles: [BruceFile] = []
    @State private var loading = false
    @State private var reading = false
    @State private var emulating = false
    @State private var status: String?
    @State private var tag: RFIDTag?
    @State private var captureName = ""
    @State private var confirmClone = false

    private var isReady: Bool { ble.state == .ready }
    private var isBusy: Bool { loading || reading || emulating || ble.isBusy }

    private var localTags: [LibraryItem] {
        library.items.filter { LibraryCategory.of($0) == .nfc }
    }
    private func isLocal(_ name: String) -> Bool { localTags.contains { $0.name == name } }

    private var deviceTags: [BruceFile] {
        deviceFiles.filter { ["rfid", "nfc", "picc"].contains($0.ext) }
    }
    private var localOnly: [LibraryItem] {
        localTags.filter { local in !deviceFiles.contains { $0.name == local.name } }
    }

    var body: some View {
        List {
            readSection
            if let tag, tag.isValid { tagSection(tag) }
            if let status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            deviceSection
            if !localOnly.isEmpty { localSection }
        }
        .navigationTitle("NFC / RFID")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!isReady || isBusy)
            }
        }
        .alert("Clonar para cartão magic?", isPresented: $confirmClone) {
            Button("Clonar", role: .destructive) { clone() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Grava o UID lido em um cartão de UID gravável. Cartões comuns não aceitam e a operação falha sem alterar nada.")
        }
    }

    // MARK: - Read

    private var readSection: some View {
        Section {
            Button {
                read()
            } label: {
                Label(reading ? L10n.t("Aproxime a tag do leitor…") : L10n.t("Ler tag"),
                      systemImage: "wave.3.right")
            }
            .disabled(!isReady || isBusy)
        } footer: {
            Text("O Bruce espera cerca de 8 segundos por uma tag. O módulo guarda uma tag por vez: ler de novo substitui a anterior.")
        }
    }

    // MARK: - Current tag

    private func tagSection(_ tag: RFIDTag) -> some View {
        Section("Tag atual") {
            field("UID", tag.uid)
            field("Tipo", tag.type)
            field("SAK", tag.sak)
            field("ATQA", tag.atqa)
            if let pages = tag.pages { field("Páginas", "\(pages)") }

            if tag.hasDump {
                TextField("nome", text: $captureName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { saveLocal(tag) } label: {
                    Label("Salvar no celular", systemImage: "iphone.and.arrow.forward")
                }
                Button { saveRemote(tag) } label: {
                    Label("Salvar no device (+ cópia local)", systemImage: "externaldrive.badge.plus")
                }
                .disabled(!isReady || isBusy)
            } else {
                Text("Só o UID foi lido — sem dump de memória para salvar ou gravar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button {
                emulate()
            } label: {
                Label(emulating ? L10n.t("Emulando…") : L10n.t("Emular tag"), systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(!isReady || isBusy)

            Button { confirmClone = true } label: {
                Label("Clonar UID (cartão magic)", systemImage: "doc.on.doc")
            }
            .disabled(!isReady || isBusy || (tag.uid ?? "").isEmpty)

            Button(role: .destructive) { self.tag = nil; status = nil } label: {
                Label("Descartar", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func field(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value {
            HStack {
                Text(label)
                Spacer()
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Device / phone lists

    private var deviceSection: some View {
        Section("No device (\(folder))") {
            if deviceTags.isEmpty && !loading {
                Text(isReady ? L10n.t("Nenhum dump aqui") : L10n.t("Conecte-se para listar"))
                    .foregroundStyle(.secondary)
            }
            ForEach(deviceTags) { file in
                deviceRow(file)
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
                loadFromDevice(file)
            } label: {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!isReady || isBusy)

            if isLocal(file.name) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { download(file) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.borderless)
                    .disabled(!isReady || isBusy)
            }
        }
    }

    private var localSection: some View {
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
            Text("Abra um item para enviar ao device (Enviar ao Bruce).")
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

    private func read() {
        Task {
            reading = true
            status = nil
            // The firmware polls for `timeout` ms before giving up, so the request
            // has to outlast that — plus room for the dump itself to stream back.
            let lines = await ble.request(RFIDCommand.read(timeout: 8000), timeout: 20) { buffer in
                buffer.contains(where: RFIDTag.isTerminalLine)
            }
            reading = false

            let scanned = RFIDTag.parse(lines)
            guard scanned.isValid else {
                status = lines.contains(where: { $0.contains("ERROR: RFID module not found") })
                    ? L10n.t("Nenhum módulo RFID encontrado neste Bruce.")
                    : L10n.t("Nada lido. Encoste a tag no leitor e tente de novo.")
                return
            }
            tag = scanned
            captureName = scanned.fileNameStem
            status = scanned.hasDump
                ? L10n.t("Lido: \(scanned.summary)")
                : L10n.t("Lido: \(scanned.summary) — sem dump de memória.")
        }
    }

    private func emulate() {
        Task {
            emulating = true
            status = L10n.t("Emulando — o Bruce fica ocupado até 60 s ou até você apertar ESC nele.")
            // Blocking on the device: `emulate()` loops for up to 60 s and no other
            // serial command is served meanwhile, so the wait is generous and the
            // completion predicate ends it as soon as the firmware reports back.
            let reply = await ble.request(RFIDCommand.emulate, timeout: 70) { buffer in
                buffer.contains { $0.hasPrefix("Emulate:") }
            }
            emulating = false
            let line = reply.first { $0.hasPrefix("Emulate:") }
            status = line?.contains("Success") == true
                ? L10n.t("Emulação encerrada.")
                : (line ?? L10n.t("Emulação encerrada sem resposta do device."))
        }
    }

    private func clone() {
        Task {
            loading = true
            let reply = await ble.request(RFIDCommand.clone(timeout: 5000), timeout: 20)
            loading = false
            let line = reply.first { $0.hasPrefix("Clone:") }
            status = line ?? L10n.t("Sem resposta do device.")
        }
    }

    private func loadFromDevice(_ file: BruceFile) {
        Task {
            loading = true
            let lines = await ble.request(RFIDCommand.loadFile(path: file.path), timeout: 20) { buffer in
                buffer.contains(where: RFIDTag.isTerminalLine)
            }
            loading = false
            let loaded = RFIDTag.parse(lines)
            if loaded.isValid {
                tag = loaded
                captureName = (file.name as NSString).deletingPathExtension
                status = L10n.t("Carregado do device: \(file.name)")
            } else {
                status = L10n.t("Falha ao carregar \(file.name).")
            }
        }
    }

    private func download(_ file: BruceFile) {
        Task {
            loading = true
            let lines = await ble.request(StorageCommand.read(path: file.path), timeout: 25)
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

    /// The `.rfid` filename derived from the name field.
    private func normalizedName() -> String {
        var name = captureName.trimmed.isEmpty ? "tag" : captureName.trimmed
        if !name.hasSuffix(".rfid") { name += ".rfid" }
        return name
    }

    private func saveLocal(_ tag: RFIDTag) {
        let name = normalizedName()
        _ = library.save(content: tag.fileContent, suggestedName: name)
        status = L10n.t("Salvo no celular: \(name)")
    }

    private func saveRemote(_ tag: RFIDTag) {
        Task {
            let name = normalizedName()
            let path = BruceFolder.path(folder, name)
            loading = true
            // Written from the app rather than with `rfid save`: the firmware picks
            // its own name on collision and never says which, so the file could not
            // be matched to the library copy afterwards.
            let ok = await ble.saveTextFileVerified(path: path, content: tag.fileContent)
            loading = false
            if ok {
                _ = library.save(content: tag.fileContent, suggestedName: name)
                status = L10n.t("Salvo no device: \(path)")
                await load()
            } else {
                status = L10n.t("Falha ao salvar no device.")
            }
        }
    }
}

#Preview {
    NavigationStack { RFIDView() }
        .environmentObject(BLEManager())
        .environmentObject(LibraryStore())
}
