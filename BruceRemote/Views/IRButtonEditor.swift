import SwiftUI

/// Create or edit one remote button.
///
/// The default flow is **Aprender**: capture a frame from the physical remote and
/// store the whole `.ir` block in the button, replayed via `ir tx_from_buffer` —
/// which works for air conditioners (`state`) and everything else. "Decodificado"
/// and "Arquivo" remain for manual entry.
struct IRButtonEditor: View {
    @EnvironmentObject private var store: RemoteStore
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    let remote: IRRemote
    let existing: IRButton?

    @State private var label: String
    @State private var systemImage: String
    @State private var mode: Mode
    @State private var proto: String
    @State private var address: String
    @State private var command: String
    @State private var filePath: String
    @State private var capturedContent: String?
    @State private var capturedSummary = ""
    @State private var learning = false
    @State private var saving = false
    @State private var status: String?

    enum Mode: String, CaseIterable {
        case learned = "Aprender", decoded = "Decodificado", file = "Arquivo"

        /// The raw value doubles as the storage key, so the visible name is
        /// localized separately.
        var label: String {
            switch self {
            case .learned: return L10n.t("Aprender")
            case .decoded: return L10n.t("Decodificado")
            case .file:    return L10n.t("Arquivo")
            }
        }
    }

    private static let icons = [
        "power", "speaker.wave.2.fill", "speaker.wave.1.fill", "speaker.slash.fill",
        "chevron.up", "chevron.down", "chevron.left", "chevron.right", "circle.fill",
        "play.fill", "pause.fill", "stop.fill", "backward.fill", "forward.fill",
        "backward.end.fill", "forward.end.fill", "house.fill", "arrow.uturn.backward",
        "list.bullet", "gearshape.fill", "tv", "fan.fill", "thermometer", "snowflake",
    ]

    init(remote: IRRemote, existing: IRButton?) {
        self.remote = remote
        self.existing = existing
        _label = State(initialValue: existing?.label ?? "")
        _systemImage = State(initialValue: existing?.systemImage ?? "power")
        switch existing?.action {
        case let .decoded(p, a, c):
            _mode = State(initialValue: .decoded)
            _proto = State(initialValue: p); _address = State(initialValue: a); _command = State(initialValue: c)
            _filePath = State(initialValue: ""); _capturedContent = State(initialValue: nil)
        case let .file(path):
            _mode = State(initialValue: .file)
            _proto = State(initialValue: "NEC"); _address = State(initialValue: ""); _command = State(initialValue: "")
            _filePath = State(initialValue: path); _capturedContent = State(initialValue: nil)
        case let .buffer(content):
            _mode = State(initialValue: .learned)
            _proto = State(initialValue: "NEC"); _address = State(initialValue: ""); _command = State(initialValue: "")
            _filePath = State(initialValue: ""); _capturedContent = State(initialValue: content)
        case nil:
            _mode = State(initialValue: .learned)
            _proto = State(initialValue: "NEC"); _address = State(initialValue: ""); _command = State(initialValue: "")
            _filePath = State(initialValue: ""); _capturedContent = State(initialValue: nil)
        }
    }

    private var isReady: Bool { ble.state == .ready }

    private var canSave: Bool {
        guard !label.trimmed.isEmpty, !saving else { return false }
        switch mode {
        case .learned: return capturedContent != nil && isReady   // saving to device needs a link
        case .decoded: return !proto.trimmed.isEmpty && address.trimmed.count == 8 && command.trimmed.count == 8
        case .file:    return !filePath.trimmed.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Botão") {
                    TextField("rótulo (ex: Power)", text: $label)
                    iconPicker
                }

                Picker("Tipo", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .learned:  learnedSection
                case .decoded:  decodedSection
                case .file:     fileSection
                }

                if let status {
                    Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(existing == nil ? L10n.t("Novo botão") : L10n.t("Editar botão"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.disabled(!canSave) }
            }
        }
    }

    // MARK: - Sections

    private var learnedSection: some View {
        Section {
            Button {
                learn()
            } label: {
                Label(learning ? L10n.t("Aponte o controle e pressione…") : L10n.t("Aprender do Bruce"),
                      systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(!isReady || learning)

            if let content = capturedContent {
                LabeledContent("Sinal", value: capturedSummary.isEmpty ? L10n.t("capturado") : capturedSummary)
                Button {
                    test(content)
                } label: {
                    Label(saving ? L10n.t("Enviando…") : L10n.t("Testar transmissão"), systemImage: "paperplane")
                }
                .disabled(!isReady || saving)
            }
            if !isReady {
                Text("Conecte-se ao Bruce para aprender.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Aprender do controle físico")
        } footer: {
            Text("Funciona com qualquer sinal, inclusive ar-condicionado (state). Ao salvar, o botão guarda o .ir no device e transmite com tx_from_file.")
        }
    }

    /// A device path for this button's `.ir`, derived from the label.
    private var devicePath: String {
        let slug = label.trimmed
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return BruceFolder.path(BruceFolder.ir, "\(slug.isEmpty ? "captura" : slug).ir")
    }

    private var decodedSection: some View {
        Section("Frame decodificado") {
            TextField("protocolo (ex: NEC)", text: $proto)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("address (8 hex)", text: $address)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            TextField("command (8 hex)", text: $command)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
    }

    private var fileSection: some View {
        Section("Arquivo no device") {
            TextField("caminho (ex: /BruceIR/tv.ir)", text: $filePath)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
    }

    private var iconPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Self.icons, id: \.self) { icon in
                    Image(systemName: icon)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(
                            systemImage == icon ? Color.accentColor.opacity(0.25) : BruceColor.surfaceHi,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(systemImage == icon ? Color.accentColor : .clear, lineWidth: 2)
                        )
                        .onTapGesture { systemImage = icon }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private func learn() {
        Task {
            learning = true
            status = nil
            // `ir rx` waits silently for the user to press the remote, so finish on
            // the capture's terminal field rather than on a quiet gap.
            let lines = await ble.request(IRCommand.rx, timeout: 15) { buffer in
                buffer.contains(where: IRCapture.isTerminalField)
            }
            let capture = IRCapture.parse(lines)
            learning = false
            if capture.isValid {
                capturedContent = capture.fileContent
                let proto = capture.protocolName ?? (capture.type == "raw" ? "RAW" : "?")
                capturedSummary = proto + (capture.hasState ? " · A/C (state)" : "")
                if label.trimmed.isEmpty { label = proto }
                status = L10n.t("Capturado: \(proto). Pronto para salvar.")
            } else {
                status = capture.hasSignal
                    ? L10n.t("Captura incompleta/malformada. Verifique o sinal e tente de novo.")
                    : L10n.t("Nada capturado. Aponte o controle e tente de novo.")
            }
        }
    }

    /// Save the captured `.ir` to the device, then transmit it via the most
    /// reliable path for this signal type.
    private func test(_ content: String) {
        Task {
            saving = true
            let path = devicePath
            let ok = await ble.saveTextFileVerified(path: path, content: content)
            saving = false
            if ok {
                _ = await ble.transmitIRFile(path: path)
                status = L10n.t("Salvo em \(path) e transmitido.")
            } else {
                status = L10n.t("Falha ao salvar no device. Tente de novo.")
            }
        }
    }

    private func save() {
        switch mode {
        case .learned:
            guard let content = capturedContent else { return }
            // Persist the capture once; the button then replays it reliably.
            Task {
                saving = true
                let path = devicePath
                let ok = await ble.saveTextFileVerified(path: path, content: content)
                saving = false
                if ok {
                    commit(action: .file(path: path))
                } else {
                    status = L10n.t("Falha ao salvar no device. Verifique a conexão e tente de novo.")
                }
            }
        case .decoded:
            commit(action: .decoded(protocol: proto.trimmed,
                                    address: address.trimmed.uppercased(),
                                    command: command.trimmed.uppercased()))
        case .file:
            commit(action: .file(path: filePath.trimmed))
        }
    }

    private func commit(action: IRButtonAction) {
        var button = existing ?? IRButton(label: "", systemImage: systemImage, action: action)
        button.label = label.trimmed
        button.systemImage = systemImage
        button.action = action

        if existing == nil {
            store.addButton(button, to: remote)
        } else {
            store.updateButton(button, in: remote)
        }
        dismiss()
    }
}
