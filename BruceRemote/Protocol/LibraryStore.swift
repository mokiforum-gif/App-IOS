import Foundation

/// Manages the on-device library of captures under `Documents/Library`.
///
/// Files are the source of truth; favorites are persisted separately in
/// `UserDefaults`. All mutations re-scan the directory and republish `items`.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    private let directory: URL
    private let favoritesKey = "library.favorites"
    private var favorites: Set<String>

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("Library", isDirectory: true)
        favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Reading

    func reload() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        items = urls.compactMap { url -> LibraryItem? in
            guard !url.hasDirectoryPath else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LibraryItem(
                url: url,
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? .distantPast,
                isFavorite: favorites.contains(url.lastPathComponent)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.modified > rhs.modified
        }
    }

    func content(of item: LibraryItem) -> String? {
        try? String(contentsOf: item.url, encoding: .utf8)
    }

    // MARK: - Writing

    /// Save text under `suggestedName`, disambiguating if the name is taken.
    @discardableResult
    func save(content: String, suggestedName: String) -> LibraryItem? {
        let url = uniqueURL(for: suggestedName.isEmpty ? "captura.txt" : suggestedName)
        do {
            try content.data(using: .utf8)?.write(to: url)
            reload()
            return items.first { $0.url == url }
        } catch {
            return nil
        }
    }

    /// Import an existing file (from the Files app) into the library.
    @discardableResult
    func importFile(from source: URL) -> LibraryItem? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let dest = uniqueURL(for: source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            reload()
            return items.first { $0.url == dest }
        } catch {
            return nil
        }
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: item.url)
        if favorites.remove(item.id) != nil { persistFavorites() }
        reload()
    }

    func rename(_ item: LibraryItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let dest = directory.appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            if favorites.remove(item.id) != nil {
                favorites.insert(trimmed)
                persistFavorites()
            }
            reload()
        } catch {}
    }

    func toggleFavorite(_ item: LibraryItem) {
        if favorites.contains(item.id) {
            favorites.remove(item.id)
        } else {
            favorites.insert(item.id)
        }
        persistFavorites()
        reload()
    }

    // MARK: - Helpers

    private func persistFavorites() {
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    /// Append " 2", " 3"… before the extension until the name is free.
    private func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        return directory.appendingPathComponent(candidate)
    }
}
