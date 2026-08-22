import Foundation

/// Persists user-built IR remotes as JSON under the app's Documents directory.
@MainActor
final class RemoteStore: ObservableObject {
    @Published private(set) var remotes: [IRRemote] = []

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("remotes.json")
        load()
    }

    // MARK: - Remotes

    func addRemote(name: String) -> IRRemote {
        let remote = IRRemote(name: name)
        remotes.append(remote)
        save()
        return remote
    }

    func deleteRemote(_ remote: IRRemote) {
        remotes.removeAll { $0.id == remote.id }
        save()
    }

    func renameRemote(_ remote: IRRemote, to name: String) {
        update(remote) { $0.name = name }
    }

    // MARK: - Buttons

    func addButton(_ button: IRButton, to remote: IRRemote) {
        update(remote) { $0.buttons.append(button) }
    }

    func updateButton(_ button: IRButton, in remote: IRRemote) {
        update(remote) { r in
            if let i = r.buttons.firstIndex(where: { $0.id == button.id }) { r.buttons[i] = button }
        }
    }

    func deleteButtons(at offsets: IndexSet, in remote: IRRemote) {
        update(remote) { $0.buttons.remove(atOffsets: offsets) }
    }

    /// Current snapshot of a remote (buttons change as they're edited).
    func remote(id: UUID) -> IRRemote? { remotes.first { $0.id == id } }

    // MARK: - Persistence

    private func update(_ remote: IRRemote, _ change: (inout IRRemote) -> Void) {
        guard let i = remotes.firstIndex(where: { $0.id == remote.id }) else { return }
        change(&remotes[i])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        remotes = (try? JSONDecoder().decode([IRRemote].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(remotes) else { return }
        try? data.write(to: fileURL)
    }
}
