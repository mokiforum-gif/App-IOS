import SwiftUI

@main
struct BruceRemoteApp: App {
    @StateObject private var ble = BLEManager()
    @StateObject private var library = LibraryStore()
    @StateObject private var remotes = RemoteStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(ble)
                .environmentObject(library)
                .environmentObject(remotes)
                .environmentObject(settings)
                .environmentObject(store)
                // SwiftUI resolves every `Text("literal")` against this locale, so
                // setting it here switches the whole interface. The `id` forces a
                // rebuild on top of that: labels that were built as plain strings
                // (model layer, via `L10n`) are not tied to the environment and
                // would otherwise keep the previous language until redrawn.
                .environment(\.locale, settings.locale)
                .id(settings.language)
                .tint(BruceColor.purple)
                .preferredColorScheme(.dark)
        }
    }
}
