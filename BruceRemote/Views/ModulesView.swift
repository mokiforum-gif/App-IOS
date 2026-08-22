import SwiftUI

/// The "Módulos" tab: the Bruce's own capabilities, each a link into its module
/// screen. Everything here is gated on an active connection.
///
/// Direct control of the device (remote, terminal, files) lives in "Meu Bruce";
/// what stays here is what the Bruce *does* — transmit, capture, drive hardware.
/// The raw hardware screens appear only in advanced mode (`AppSettings`).
struct ModulesView: View {
    @EnvironmentObject private var ble: BLEManager
    @EnvironmentObject private var settings: AppSettings

    private var isReady: Bool { ble.state == .ready }

    var body: some View {
        ZStack {
            BruceColor.backdrop.ignoresSafeArea()
            VStack(spacing: 0) {
                BruceLogoHeader()
                ConnectionStatusBar()
                moduleList
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar()
    }

    /// A device module link, disabled until connected.
    private func moduleLink<Destination: View>(
        _ title: LocalizedStringKey,
        _ systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(!isReady)
    }

    private var moduleList: some View {
        List {
            Section {
                NavigationLink {
                    IRSyncView()
                } label: {
                    Label("Infravermelho", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(!isReady)

                NavigationLink {
                    SubGHzView()
                } label: {
                    Label("Sub-GHz / RF", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!isReady)

                NavigationLink {
                    RFIDView()
                } label: {
                    Label("NFC / RFID", systemImage: "wave.3.right")
                }
                .disabled(!isReady)
            } header: {
                Text("Módulos")
            }
            .listRowBackground(BruceColor.surface)

            Section {
                moduleLink("Áudio", "speaker.wave.2.fill") { AudioView() }
                moduleLink("LEDs & Tela", "paintpalette.fill") { LEDView() }
                moduleLink("WiFi", "wifi") { WiFiView() }
                moduleLink("JS / Scripts", "curlybraces") { ScriptsView() }
                if settings.advancedMode {
                    moduleLink("GPIO & I2C", "cpu") { GPIOView() }
                }
            } header: {
                Text("Sistema & hardware")
            } footer: {
                if !settings.advancedMode {
                    Text("Ative o modo avançado em Config para ver GPIO & I2C e os arquivos do dispositivo.")
                        .font(.caption)
                }
            }
            .listRowBackground(BruceColor.surface)
        }
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    NavigationStack { ModulesView() }
        .environmentObject(BLEManager())
        .environmentObject(AppSettings())
}
