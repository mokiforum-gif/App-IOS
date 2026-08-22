import SwiftUI

/// WiFi / network module: connect, add networks, and run scanners.
struct WiFiView: View {
    @EnvironmentObject private var ble: BLEManager

    @State private var ssid = ""
    @State private var password = ""

    private var isReady: Bool { ble.state == .ready }

    var body: some View {
        Form {
            Section("Conexão") {
                Button { ble.send(WiFiCommand.on) } label: {
                    Label("Conectar (wifi on)", systemImage: "wifi")
                }
                Button { ble.send(WiFiCommand.off) } label: {
                    Label("Desconectar (wifi off)", systemImage: "wifi.slash")
                }
                Button { ble.send(WiFiCommand.webui) } label: {
                    Label("Iniciar WebUI", systemImage: "globe")
                }
            }

            Section("Adicionar rede") {
                TextField("SSID", text: $ssid)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("senha", text: $password)
                Button {
                    ble.send(WiFiCommand.add(ssid: ssid.trimmed, password: password))
                } label: {
                    Label("Adicionar", systemImage: "plus")
                }
                .disabled(ssid.trimmed.isEmpty)
            }

            Section("Ferramentas") {
                Button { ble.send(WiFiCommand.arp) } label: {
                    Label("ARP scan (hosts)", systemImage: "list.bullet.rectangle")
                }
                Button { ble.send(WiFiCommand.sniffer) } label: {
                    Label("Raw sniffer", systemImage: "dot.radiowaves.up.forward")
                }
                Button { ble.send(WiFiCommand.listen) } label: {
                    Label("Listen TCP", systemImage: "network")
                }
            }

            Section("Saída") {
                ConsolePane()
                    .frame(minHeight: 160)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("WiFi")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!isReady)
    }
}

#Preview {
    NavigationStack { WiFiView() }.environmentObject(BLEManager())
}
