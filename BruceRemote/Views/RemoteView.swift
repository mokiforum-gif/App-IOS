import SwiftUI

/// A single remote: a grid of buttons that fire IR commands on tap.
struct RemoteView: View {
    @EnvironmentObject private var store: RemoteStore
    @EnvironmentObject private var ble: BLEManager

    let remoteID: UUID

    @State private var editing = false
    @State private var editorButton: IRButton?     // existing button being edited
    @State private var addingButton = false        // presenting editor for a new button

    private var remote: IRRemote? { store.remote(id: remoteID) }
    private var isReady: Bool { ble.state == .ready }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ScrollView {
            if let remote {
                if remote.buttons.isEmpty {
                    ContentUnavailableView(
                        "Sem botões",
                        systemImage: "plus.app",
                        description: Text("Toque em + para adicionar um botão ou capturar um do controle físico.")
                    )
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(remote.buttons) { button in
                            cell(for: button, in: remote)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(remote?.name ?? L10n.t("Controle"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(editing ? L10n.t("OK") : L10n.t("Editar")) { editing.toggle() }
                Button { addingButton = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $addingButton) {
            if let remote {
                IRButtonEditor(remote: remote, existing: nil)
            }
        }
        .sheet(item: $editorButton) { button in
            if let remote {
                IRButtonEditor(remote: remote, existing: button)
            }
        }
        .overlay(alignment: .bottom) {
            if !isReady {
                Text("Conecte-se ao Bruce para transmitir.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private func cell(for button: IRButton, in remote: IRRemote) -> some View {
        Button {
            if editing {
                editorButton = button
            } else {
                press(button)
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: button.systemImage)
                    .font(.title2)
                Text(button.label)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(BruceColor.surfaceHi, in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if editing {
                    Button {
                        if let i = remote.buttons.firstIndex(where: { $0.id == button.id }) {
                            store.deleteButtons(at: [i], in: remote)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .background(.black, in: Circle())
                    }
                    .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isReady || editing ? Color.accentColor : .secondary)
        .disabled(!isReady && !editing)
    }

    private func press(_ button: IRButton) {
        guard isReady else { return }
        ble.perform(button.action)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
