import SwiftUI

/// The app shell: five tabs, each its own navigation stack.
///
/// - **Meu Bruce** — the connected device itself: identity, memory, storage, and
///   the direct controls (remote, terminal, files).
/// - **Módulos** — what the Bruce can transmit and sense (IR, Sub-GHz, hardware).
/// - **Biblioteca** — captures stored on the phone, with upload/replay to the device.
/// - **Apps** — the Bruce App Store.
/// - **Config** — device and app settings, including advanced mode and language.
///
/// The connection lives in `BLEManager`, shared across every tab, so scanning on
/// one tab lights up the others; each tab carries its own connect/disconnect
/// button via `connectionToolbar()`.
struct RootTabView: View {
    @State private var selection = 0
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { MyBruceView() }
                .tabItem {
                    // Template-rendered silhouette: the tab bar tints it, so it is
                    // white while selected and grey otherwise, like an SF Symbol.
                    Label {
                        Text("Meu Bruce")
                    } icon: {
                        Image("BruceShark").renderingMode(.template)
                    }
                }
                .tag(0)

            NavigationStack { ModulesView() }
                .tabItem { Label("Módulos", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)

            NavigationStack { LibraryView() }
                .tabItem { Label("Biblioteca", systemImage: "folder.fill") }
                .tag(2)

            NavigationStack { AppStoreView() }
                .tabItem { Label("Apps", systemImage: "bag.fill") }
                .tag(3)

            NavigationStack {
                SystemView()
                    .connectionToolbar()
            }
            .tabItem { Label("Config", systemImage: "gearshape.fill") }
            .tag(4)
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(BLEManager())
        .environmentObject(LibraryStore())
        .environmentObject(RemoteStore())
        .environmentObject(AppSettings())
        .environmentObject(AppStore())
        .tint(BruceColor.purple)
        .preferredColorScheme(.dark)
}
