import SwiftUI

/// Sub-GHz module (CC1101): receive frames and replay `.sub` files, plus a raw
/// transmit for advanced use. Runs fine while the app stays connected — unlike
/// the nRF24 jammer, which would drop the BLE link.
struct SubGHzView: View {
    @EnvironmentObject private var ble: BLEManager

    @State private var filePath = ""
    @State private var value = ""
    @State private var frequency = "433920000"
    @State private var te = "174"
    @State private var count = "10"

    private var isReady: Bool { ble.state == .ready }

    var body: some View {
        Form {
            Section("Receber") {
                Button {
                    ble.send(SubGHzCommand.rx)
                } label: {
                    Label("Escutar (rx)", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!isReady)
            }

            Section("Enviar de arquivo") {
                TextField("caminho (ex: /BruceRF/gate.sub)", text: $filePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    ble.send(SubGHzCommand.txFromFile(path: filePath.trimmed))
                } label: {
                    Label("Transmitir arquivo", systemImage: "paperplane")
                }
                .disabled(!isReady || filePath.trimmed.isEmpty)
            }

            Section("Enviar bruto") {
                TextField("value (chave decodificada)", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                TextField("frequência em Hz (ex: 433920000)", text: $frequency)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                TextField("te (µs, ex: 174)", text: $te)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                TextField("count (repetições, ex: 10)", text: $count)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                Button {
                    ble.send(SubGHzCommand.tx(
                        value: value.trimmed,
                        frequency: Int(frequency.trimmed) ?? 0,
                        te: Int(te.trimmed) ?? 0,
                        count: Int(count.trimmed) ?? 0
                    ))
                } label: {
                    Label("Transmitir", systemImage: "paperplane.fill")
                }
                .disabled(!isReady || value.trimmed.isEmpty || Int(frequency.trimmed) == nil)
            }

            Section("Saída") {
                ConsolePane()
                    .frame(minHeight: 180)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Sub-GHz / RF")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!isReady)
    }
}

#Preview {
    NavigationStack { SubGHzView() }
        .environmentObject(BLEManager())
}
