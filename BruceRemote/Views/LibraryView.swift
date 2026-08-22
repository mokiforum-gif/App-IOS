import SwiftUI

/// The app-side library ("Archive"): captures saved on the phone, grouped by type
/// and shown as cards. Each card carries its category badge and — when the Bruce
/// is connected — whether that capture already lives on the device.
///
/// Works offline; the sync badge and uploading need a connection.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var ble: BLEManager

    @State private var showImporter = false
    @State private var search = ""

    private var filtered: [LibraryItem] {
        let q = search.trimmed
        guard !q.isEmpty else { return library.items }
        return library.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var favorites: [LibraryItem] { filtered.filter(\.isFavorite) }

    /// Categories that actually have items, in the enum's declared order, with a count.
    private var categoryCounts: [(category: LibraryCategory, count: Int)] {
        LibraryCategory.allCases.compactMap { category in
            let n = filtered.filter { LibraryCategory.of($0) == category }.count
            return n > 0 ? (category, n) : nil
        }
    }

    var body: some View {
        ScrollView {
            if library.items.isEmpty {
                ContentUnavailableView(
                    "Biblioteca vazia",
                    systemImage: "tray",
                    description: Text("Baixe capturas do Bruce ou importe arquivos para guardá-los aqui.")
                )
                .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    categoriesCard
                    if !favorites.isEmpty {
                        section("Favoritos", systemImage: "star.fill", items: favorites)
                    }
                    section("Todos", items: filtered)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
        .background(BruceColor.backdrop.ignoresSafeArea())
        // Thumb-reachable, and out of the way of the search field: the importer sits
        // above the tab bar rather than in the navigation bar. Outside the `if` so
        // an empty library — the one that most needs it — still offers it.
        .overlay(alignment: .bottomTrailing) { importButton }
        .navigationTitle("Biblioteca")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Buscar")
        // Same placement as every other tab, instead of this screen's own.
        .connectionToolbar()
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach { _ = library.importFile(from: $0) }
                Task { await refreshIndex() }
            }
        }
        .task { library.reload(); await refreshIndex() }
        .task(id: ble.state) { await refreshIndex() }
        .refreshable { library.reload(); await refreshIndex() }
    }

    // MARK: - Import

    private var importButton: some View {
        Button {
            showImporter = true
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(BruceColor.purple, in: Circle())
                .overlay(Circle().stroke(BruceColor.lilac.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel(Text("Importar arquivos"))
    }

    // MARK: - Sections

    private var categoriesCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(categoryCounts.enumerated()), id: \.element.category) { index, entry in
                NavigationLink {
                    LibraryCategoryView(category: entry.category)
                } label: {
                    categoryRow(entry.category, count: entry.count)
                }
                .buttonStyle(.plain)
                if index < categoryCounts.count - 1 {
                    Divider().overlay(BruceColor.lilac.opacity(0.12))
                }
            }
        }
        .background(BruceColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func categoryRow(_ category: LibraryCategory, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(category.color)
                .frame(width: 28)
            Text(category.title)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func section(_ title: LocalizedStringKey, systemImage: String? = nil, items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title).font(.title3.weight(.bold))
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(.yellow).font(.subheadline)
                }
            }
            LibraryGrid(items: items)
        }
    }

    // MARK: - Sync index

    private func refreshIndex() async {
        let folders = Set(library.items.compactMap { LibraryCategory.of($0).deviceFolder })
        guard !folders.isEmpty else { return }
        await ble.refreshDeviceIndex(folders: Array(folders))
    }
}

/// A responsive two-column grid of library cards, each linking to its detail.
struct LibraryGrid: View {
    @EnvironmentObject private var ble: BLEManager
    let items: [LibraryItem]

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { item in
                NavigationLink {
                    LibraryItemDetailView(item: item)
                } label: {
                    LibraryCard(item: item, sync: ble.syncState(for: item))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One capture as a card: a colored category badge, the sync state, and the name.
struct LibraryCard: View {
    let item: LibraryItem
    let sync: SyncState

    private var category: LibraryCategory { LibraryCategory.of(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                categoryBadge
                Spacer()
                Image(systemName: sync.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(sync.color)
                    .accessibilityLabel(sync.label)
            }

            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.sizeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(BruceColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottomTrailing) {
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .padding(8)
            }
        }
    }

    private var categoryBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: category.systemImage)
                .font(.system(size: 11, weight: .bold))
            Text(category.title)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(category.color, in: Capsule())
    }
}

/// The full list of one category, reached from the library's category rows.
struct LibraryCategoryView: View {
    @EnvironmentObject private var library: LibraryStore
    let category: LibraryCategory

    private var items: [LibraryItem] {
        library.items.filter { LibraryCategory.of($0) == category }
    }

    var body: some View {
        ScrollView {
            LibraryGrid(items: items)
                .padding()
        }
        .background(BruceColor.backdrop.ignoresSafeArea())
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { LibraryView() }
        .environmentObject(LibraryStore())
        .environmentObject(BLEManager())
        .preferredColorScheme(.dark)
}
