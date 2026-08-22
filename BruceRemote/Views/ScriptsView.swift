import SwiftUI

/// The JS / Scripts module: browse the device's `/BruceJS` folder and run any
/// `.js` script with `js run_from_file` — the same interpreter that runs store
/// apps. One directory per screen, mirroring `FileBrowserView`.
///
/// This is the app-side analog of the device's own "JS Interpreter" menu: it's how
/// you launch what the App Store installed (and any script you uploaded yourself).
struct ScriptsView: View {
    @EnvironmentObject private var ble: BLEManager

    /// Absolute directory this screen lists. Defaults to the apps root.
    let path: String

    @State private var entries: [BruceFile] = []
    @State private var isLoading = false
    @State private var status: String?

    init(path: String = BruceFolder.js) { self.path = path }

    private var isReady: Bool { ble.state == .ready }
    private var isRoot: Bool { path == BruceFolder.js }
    private var title: String { isRoot ? L10n.t("JS / Scripts") : (path as NSString).lastPathComponent }

    /// Folders and `.js` files only; other assets (icons, data) are hidden here.
    private var visible: [BruceFile] {
        entries.filter { $0.isDirectory || $0.ext == "js" }
    }

    var body: some View {
        List {
            if let status {
                Section {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                if visible.isEmpty && !isLoading {
                    Text(isReady ? "Nenhum script aqui." : "Conecte-se ao Bruce para ver os scripts.")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { entry in
                    row(for: entry)
                }
            } header: {
                Text(path).font(.system(.caption, design: .monospaced)).textCase(nil)
            } footer: {
                if isRoot {
                    Text("Scripts em /BruceJS. A loja instala aqui; rode qualquer .js com o interpretador do Bruce.")
                        .font(.caption)
                }
            }

            if isRoot {
                Section {
                    Button(role: .destructive) {
                        ble.send(JSCommand.exit)
                        status = L10n.t("Interpretador encerrado.")
                    } label: {
                        Label("Parar script (js exit)", systemImage: "stop.fill")
                    }
                    .disabled(!isReady)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading { ProgressView() } }
        .connectionToolbar()
        .refreshable { await load() }
        .task(id: path) { await load() }
    }

    @ViewBuilder
    private func row(for entry: BruceFile) -> some View {
        if entry.isDirectory {
            NavigationLink {
                ScriptsView(path: entry.path)
            } label: {
                Label(entry.name, systemImage: "folder.fill")
            }
        } else {
            Button {
                run(entry)
            } label: {
                HStack {
                    Label(entry.name, systemImage: "curlybraces")
                    Spacer()
                    Image(systemName: "play.fill")
                        .foregroundStyle(isReady ? BruceColor.purple : .secondary)
                }
            }
            .disabled(!isReady)
        }
    }

    private func load() async {
        guard isReady else { entries = []; return }
        isLoading = true
        defer { isLoading = false }
        let lines = await ble.request(StorageCommand.list(path: path), echo: false)
        entries = BruceFile.parseListing(lines, parent: path)
    }

    private func run(_ entry: BruceFile) {
        ble.runScript(at: entry.path)
        status = L10n.t("Rodando \(entry.name) no Bruce.")
    }
}

#Preview {
    NavigationStack { ScriptsView() }
        .environmentObject(BLEManager())
        .preferredColorScheme(.dark)
}
