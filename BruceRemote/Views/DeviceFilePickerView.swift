import SwiftUI

/// A sheet that browses the device filesystem and returns a chosen file.
///
/// One directory per screen (like `FileBrowserView`), but read-only and focused on
/// selection: folders drill in, files that match `allowedExtensions` are tappable
/// and dismiss the sheet with the pick. Pass `allowedExtensions: nil` to allow any.
struct DeviceFilePickerView: View {
    let title: LocalizedStringKey
    let startPath: String
    /// Lowercased extensions (without dot) that can be picked, or nil for all.
    let allowedExtensions: Set<String>?
    let onPick: (BruceFile) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        title: LocalizedStringKey,
        startPath: String = "/",
        allowedExtensions: Set<String>? = nil,
        onPick: @escaping (BruceFile) -> Void
    ) {
        self.title = title
        self.startPath = startPath
        self.allowedExtensions = allowedExtensions
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            DeviceFolderPicker(path: startPath, allowedExtensions: allowedExtensions) { file in
                onPick(file)
                dismiss()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// One directory level of the picker.
private struct DeviceFolderPicker: View {
    @EnvironmentObject private var ble: BLEManager

    let path: String
    let allowedExtensions: Set<String>?
    let onPick: (BruceFile) -> Void

    @State private var entries: [BruceFile] = []
    @State private var isLoading = false

    private var isReady: Bool { ble.state == .ready }

    /// Folders plus files whose extension is allowed.
    private var visible: [BruceFile] {
        entries.filter { entry in
            guard !entry.isDirectory else { return true }
            guard let allowed = allowedExtensions else { return true }
            return allowed.contains(entry.ext)
        }
    }

    var body: some View {
        List {
            Section {
                if visible.isEmpty && !isLoading {
                    Text(isReady ? "Nada aqui." : "Conecte-se ao Bruce para navegar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { entry in
                    if entry.isDirectory {
                        NavigationLink {
                            DeviceFolderPicker(path: entry.path, allowedExtensions: allowedExtensions, onPick: onPick)
                                .navigationTitle(entry.name)
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label(entry.name, systemImage: "folder.fill")
                        }
                    } else {
                        Button { onPick(entry) } label: {
                            HStack {
                                Label(entry.name, systemImage: entry.systemImage)
                                Spacer()
                                if let size = entry.sizeLabel {
                                    Text(size).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(path).font(.system(.caption, design: .monospaced)).textCase(nil)
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .task(id: path) { await load() }
    }

    private func load() async {
        guard isReady else { entries = []; return }
        isLoading = true
        defer { isLoading = false }
        let lines = await ble.request(StorageCommand.list(path: path), echo: false)
        entries = BruceFile.parseListing(lines, parent: path)
    }
}
