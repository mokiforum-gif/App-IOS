import SwiftUI

/// The "Config" tab: app preferences first (they work offline), then the device's
/// own controls — power, firmware settings and factory reset.
///
/// Advanced mode is the gate for everything that can misfire in the wrong hands:
/// the raw `settings` editor and the factory reset here, GPIO & I2C in Módulos,
/// and the device file browser in Meu Bruce.
struct SystemView: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var settings: AppSettings

    @State private var settingName = ""
    @State private var settingValue = ""
    @State private var confirmPower: PowerCommand?
    @State private var confirmReset = false

    private var isReady: Bool { ble.state == .ready }

    var body: some View {
        Form {
            appSection

            Group {
                Section("Energia") {
                    Button(role: .destructive) { confirmPower = .off } label: {
                        Label("Desligar", systemImage: "power")
                    }
                    Button { confirmPower = .reboot } label: {
                        Label("Reiniciar", systemImage: "arrow.clockwise")
                    }
                    Button { confirmPower = .sleep } label: {
                        Label("Dormir", systemImage: "moon.fill")
                    }
                }
                .listRowBackground(BruceColor.surface)

                if settings.advancedMode {
                    Section("Configurações do firmware") {
                        Button { ble.send(SettingsCommand.view) } label: {
                            Label("Ver todas", systemImage: "list.bullet")
                        }
                        TextField("nome", text: $settingName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("novo valor", text: $settingValue)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button {
                            ble.send(SettingsCommand.set(name: settingName.trimmed,
                                                         value: settingValue.trimmed))
                        } label: {
                            Label("Alterar", systemImage: "pencil")
                        }
                        .disabled(settingName.trimmed.isEmpty || settingValue.trimmed.isEmpty)
                    }
                    .listRowBackground(BruceColor.surface)

                    Section {
                        Button(role: .destructive) { confirmReset = true } label: {
                            Label("Factory reset", systemImage: "trash")
                        }
                    }
                    .listRowBackground(BruceColor.surface)
                }

                Section("Saída") {
                    ConsolePane()
                        .frame(minHeight: 160)
                        .listRowInsets(EdgeInsets())
                }
                .listRowBackground(BruceColor.surface)
            }
            // Only the device half needs a connection — the app settings above stay
            // usable offline, which is when people usually go looking for them.
            .disabled(!isReady)
        }
        .bruceScreenBackground()
        .navigationTitle("Config")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $confirmPower) { command in
            Alert(
                title: Text(powerTitle(command)),
                message: Text("Isso vai desconectar o Bruce."),
                primaryButton: .destructive(Text("Confirmar")) { ble.send(command) },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
        .alert("Factory reset?", isPresented: $confirmReset) {
            Button("Resetar", role: .destructive) { ble.send(SettingsCommand.factoryReset) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Restaura as configurações de fábrica do dispositivo.")
        }
    }

    // MARK: - App preferences

    private var appSection: some View {
        Section {
            Picker("Idioma", selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }

            Toggle(isOn: $settings.advancedMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Modo avançado")
                    Text("Mostra GPIO & I2C, os arquivos do dispositivo e as configurações do firmware.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Aplicativo")
        }
        .listRowBackground(BruceColor.surface)
    }

    private func powerTitle(_ command: PowerCommand) -> LocalizedStringKey {
        switch command {
        case .off:    return "Desligar o Bruce?"
        case .reboot: return "Reiniciar o Bruce?"
        case .sleep:  return "Colocar para dormir?"
        }
    }
}

extension PowerCommand: Identifiable {
    var id: String { serialLine }
}

#Preview {
    NavigationStack { SystemView() }
        .environmentObject(BLEManager())
        .environmentObject(AppSettings())
}
