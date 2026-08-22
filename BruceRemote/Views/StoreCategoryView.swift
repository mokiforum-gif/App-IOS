import SwiftUI

/// The apps inside one store category, each a link into its detail screen.
struct StoreCategoryView: View {
    let category: StoreCategory

    @EnvironmentObject private var store: AppStore

    private var apps: [StoreApp] { store.appsByCategory[category.slug] ?? [] }
    private var state: AppStore.LoadState { store.categoryState[category.slug] ?? .idle }

    var body: some View {
        ZStack {
            BruceColor.backdrop.ignoresSafeArea()
            content
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar()
        .task { await store.loadApps(in: category) }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading where apps.isEmpty:
            ProgressView().tint(BruceColor.purple)
        case .failed(let message) where apps.isEmpty:
            StoreErrorView(message: message) {
                Task { await store.loadApps(in: category, force: true) }
            }
        default:
            appList
        }
    }

    private var appList: some View {
        List {
            Section {
                ForEach(apps) { app in
                    NavigationLink {
                        StoreAppDetailView(app: app)
                    } label: {
                        StoreAppRow(app: app)
                    }
                }
            }
            .listRowBackground(BruceColor.surface)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await store.loadApps(in: category, force: true) }
    }
}

/// One app in a category list: name, short description, and an install badge.
struct StoreAppRow: View {
    let app: StoreApp
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(app.name)
                    .font(.headline)
                Spacer()
                StoreInstallBadge(app: app)
            }
            Text(app.details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("v\(app.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// A compact status capsule: installed, update available, or nothing.
struct StoreInstallBadge: View {
    let app: StoreApp
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if store.updateAvailable(for: app) {
            StatusPill(text: L10n.t("Atualizar"), systemImage: "arrow.up.circle.fill",
                       tint: BruceColor.azure)
        } else if store.isInstalled(app) {
            StatusPill(text: L10n.t("Instalado"), systemImage: "checkmark.circle.fill",
                       tint: Color(hex: 0x3DDC84))
        }
    }
}

#Preview {
    NavigationStack {
        StoreCategoryView(category: StoreCategory(name: "Tools", slug: "tools", count: 5, lastUpdated: 0))
    }
    .environmentObject(BLEManager())
    .environmentObject(AppStore())
    .preferredColorScheme(.dark)
}
