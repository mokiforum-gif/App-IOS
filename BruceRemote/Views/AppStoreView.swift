import SwiftUI

/// The "Apps" tab: the Bruce App Store. Browses the community catalog
/// (`ghp.iceis.co.uk`) and installs JavaScript apps onto the connected device.
///
/// Browsing is network-only, so it works with no device connected; installing and
/// running are gated on an active link inside the app's detail screen.
struct AppStoreView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var ble: BLEManager

    var body: some View {
        ZStack {
            BruceColor.backdrop.ignoresSafeArea()
            content
        }
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar()
        .task { await store.loadCatalog() }
        // Reconcile install state with what the device actually reports, so badges
        // and the "Instalados" list are correct even for apps this phone didn't
        // install. Runs on open and whenever the link becomes ready.
        .task(id: ble.state) {
            if ble.state == .ready { await store.syncInstalledFromDevice(using: ble) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.catalogState {
        case .idle, .loading where store.categories.isEmpty:
            ProgressView(L10n.t("Carregando a loja…"))
                .tint(BruceColor.purple)
        case .failed(let message) where store.categories.isEmpty:
            StoreErrorView(message: message) {
                Task { await store.loadCatalog(force: true) }
            }
        default:
            categoryList
        }
    }

    private var categoryList: some View {
        List {
            Section {
                NavigationLink {
                    InstalledAppsView()
                } label: {
                    Label {
                        HStack {
                            Text("Instalados no dispositivo")
                            Spacer()
                            Text("\(store.installed.count)")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Color(hex: 0x3DDC84))
                    }
                }
            }
            .listRowBackground(BruceColor.surface)

            Section {
                ForEach(store.categories) { category in
                    NavigationLink {
                        StoreCategoryView(category: category)
                    } label: {
                        Label {
                            HStack {
                                Text(category.name)
                                Spacer()
                                Text("\(category.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        } icon: {
                            Image(systemName: Self.symbol(for: category.slug))
                                .foregroundStyle(BruceColor.lilac)
                        }
                    }
                }
            } footer: {
                Text("Scripts da comunidade Bruce. Uso autorizado apenas.")
                    .font(.caption)
            }
            .listRowBackground(BruceColor.surface)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await store.loadCatalog(force: true) }
    }

    /// A representative SF Symbol per known category slug.
    static func symbol(for slug: String) -> String {
        switch slug.lowercased() {
        case "games":     return "gamecontroller.fill"
        case "tools":     return "wrench.and.screwdriver.fill"
        case "utilities": return "slider.horizontal.3"
        case "infrared":  return "dot.radiowaves.left.and.right"
        case "rf":        return "antenna.radiowaves.left.and.right"
        case "wifi":      return "wifi"
        case "audio":     return "speaker.wave.2.fill"
        default:          return "app.badge"
        }
    }
}

/// A shared failure state with a retry button, matching the app's dark surfaces.
struct StoreErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Não foi possível carregar")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Label("Tentar de novo", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(BruceColor.purple)
        }
        .padding(32)
    }
}

#Preview {
    NavigationStack { AppStoreView() }
        .environmentObject(BLEManager())
        .environmentObject(AppStore())
        .preferredColorScheme(.dark)
}
