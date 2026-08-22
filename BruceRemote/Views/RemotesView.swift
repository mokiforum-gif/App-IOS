import SwiftUI

/// List of user-built IR remotes. Editing works offline; sending needs a device.
struct RemotesView: View {
    @EnvironmentObject private var store: RemoteStore
    @State private var showAdd = false
    @State private var newName = ""

    var body: some View {
        List {
            if store.remotes.isEmpty {
                ContentUnavailableView(
                    "Nenhum controle",
                    systemImage: "av.remote",
                    description: Text("Crie um controle e adicione botões — manualmente ou capturando do controle físico com “Aprender”.")
                )
            }
            ForEach(store.remotes) { remote in
                NavigationLink {
                    RemoteView(remoteID: remote.id)
                } label: {
                    HStack {
                        Label(remote.name, systemImage: "av.remote")
                        Spacer()
                        Text("\(remote.buttons.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { store.remotes[$0] }.forEach(store.deleteRemote)
            }
        }
        .navigationTitle("Controles IR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newName = ""; showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .alert("Novo controle", isPresented: $showAdd) {
            TextField("nome (ex: TV da sala)", text: $newName)
            Button("Criar") {
                let name = newName.trimmed
                if !name.isEmpty { _ = store.addRemote(name: name) }
            }
            Button("Cancelar", role: .cancel) {}
        }
    }
}

#Preview {
    NavigationStack { RemotesView() }
        .environmentObject(RemoteStore())
        .environmentObject(BLEManager())
}
