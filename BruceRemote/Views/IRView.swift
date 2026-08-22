import SwiftUI

/// Infrared module: receive frames and replay `.ir` files (the dependable paths),
/// plus a raw decoded-frame transmit for advanced use.
struct IRView: View {
    @EnvironmentObject private var ble: BLEManager

    @State private var filePath = ""
    @State private var proto = ""
    @State private var address = ""
    @State private var value = ""

    private var isReady: Bool { ble.state == .ready }

    var body: some View {
        Form {
            Section("Receber") {
                Button {
                    ble.send(IRCommand.rx)
                } label: {
                    Label("Capturar frame IR", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(!isReady)
            }

            Section("Enviar de arquivo") {
                TextField("caminho (ex: /ir/tv.ir)", text: $filePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    Task { await ble.transmitIRFile(path: filePath.trimmed) }
                } label: {
                    Label("Transmitir arquivo", systemImage: "paperplane")
                }
                .disabled(!isReady || filePath.trimmed.isEmpty)
            }

            Section("Enviar frame decodificado") {
                TextField("protocolo (ex: NEC)", text: $proto)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("endereço", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("comando (8 hex)", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    ble.send(IRCommand.tx(protocol: proto.trimmed, address: address.trimmed, command: value.trimmed))
                } label: {
                    Label("Transmitir frame", systemImage: "paperplane.fill")
                }
                .disabled(!isReady || proto.trimmed.isEmpty)
            }

            Section("Saída") {
                ConsolePane()
                    .frame(minHeight: 180)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Infravermelho")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!isReady)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#Preview {
    NavigationStack { IRView() }
        .environmentObject(BLEManager())
}
