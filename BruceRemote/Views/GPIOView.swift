import SwiftUI

/// GPIO + I2C module: scan the I2C bus and drive GPIO pins.
struct GPIOView: View {
    @EnvironmentObject private var ble: BLEManager

    @State private var pin = "1"
    @State private var high = true
    @State private var output = true

    private var isReady: Bool { ble.state == .ready }
    private var pinNumber: Int? { Int(pin.trimmed) }

    var body: some View {
        Form {
            Section("I2C") {
                Button { ble.send(I2CCommand.scan) } label: {
                    Label("Escanear barramento", systemImage: "magnifyingglass")
                }
                .disabled(!isReady)
            }

            Section("GPIO") {
                TextField("pino", text: $pin)
                    .keyboardType(.numberPad).font(.system(.body, design: .monospaced))
                Toggle("Modo saída (output)", isOn: $output)
                Button {
                    ble.send(GPIOCommand.mode(pin: pinNumber ?? 0, value: output ? 1 : 0))
                } label: {
                    Label("Definir modo", systemImage: "switch.2")
                }
                .disabled(!isReady || pinNumber == nil)

                Toggle("Nível alto (on)", isOn: $high)
                Button {
                    ble.send(GPIOCommand.set(pin: pinNumber ?? 0, value: high ? 1 : 0))
                } label: {
                    Label("Escrever no pino", systemImage: "bolt.fill")
                }
                .disabled(!isReady || pinNumber == nil)
            }

            Section("Saída") {
                ConsolePane()
                    .frame(minHeight: 160)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("GPIO & I2C")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!isReady)
    }
}

#Preview {
    NavigationStack { GPIOView() }.environmentObject(BLEManager())
}
