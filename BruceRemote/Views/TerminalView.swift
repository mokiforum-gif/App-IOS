import SwiftUI

/// Raw terminal: shows the TX stream and lets the user type command lines to RX.
struct TerminalView: View {
    @EnvironmentObject private var ble: BLEManager
    @State private var command = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(ble.lines) { line in
                            Text(line.text)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(line.kind == .sent ? Color.accentColor : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: ble.lines.count) { _, _ in
                    if let last = ble.lines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            quickCommands
            inputBar
        }
    }

    private var quickCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SystemCommand.allCases, id: \.serialLine) { command in
                    Button(command.label) { ble.send(command) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(ble.state != .ready)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("comando (ex: info)", text: $command)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .submitLabel(.send)
                .focused($inputFocused)
                .onSubmit(sendCommand)

            Button(action: sendCommand) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(!canSend)
        }
        .padding(10)
    }

    private var canSend: Bool {
        ble.state == .ready && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sendCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ble.state == .ready, !trimmed.isEmpty else { return }
        ble.send(trimmed)
        command = ""
        inputFocused = true
    }
}

#Preview {
    TerminalView()
        .environmentObject(BLEManager())
}
