import SwiftUI

/// The interface language, either following the phone or pinned by the user.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case portuguese
    case english

    var id: String { rawValue }

    /// The locale to resolve strings against, or nil to follow the device.
    var locale: Locale? {
        switch self {
        case .system:     return nil
        case .portuguese: return Locale(identifier: "pt-BR")
        case .english:    return Locale(identifier: "en")
        }
    }

    /// Shown in its own language, the way system language pickers do it, so the
    /// option is recognizable even when the app is currently in the other one.
    var label: LocalizedStringKey {
        switch self {
        case .system:     return "Idioma do aparelho"
        case .portuguese: return "Português (Brasil)"
        case .english:    return "English"
        }
    }
}

/// Preferences that belong to the app rather than the device, persisted in
/// `UserDefaults`.
///
/// - `advancedMode` gates the screens that can misfire in the wrong hands (raw
///   GPIO/I2C writes, the device filesystem) — off by default, so the everyday
///   surface stays small.
/// - `language` overrides the phone's language for the app alone. `L10n.locale`
///   is kept in step with it, since strings built outside SwiftUI's `Text` (model
///   labels, interpolated messages) resolve programmatically.
@MainActor
final class AppSettings: ObservableObject {
    @Published var advancedMode: Bool {
        didSet { defaults.set(advancedMode, forKey: Key.advancedMode) }
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            L10n.use(language)
        }
    }

    /// The locale the whole interface resolves against.
    var locale: Locale { language.locale ?? .autoupdatingCurrent }

    private let defaults: UserDefaults

    private enum Key {
        static let advancedMode = "settings.advancedMode"
        static let language = "settings.language"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        advancedMode = defaults.bool(forKey: Key.advancedMode)
        language = defaults.string(forKey: Key.language)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        L10n.use(language)
    }
}

/// Programmatic string lookup for text that never passes through `Text`.
///
/// SwiftUI resolves `Text("literal")` against `\.locale` in the environment, which
/// the root view sets from `AppSettings`. Model-layer labels have no environment,
/// so they go through here.
///
/// The lookup swaps the *bundle*, not just the locale: `String(localized:locale:)`
/// uses its `locale` for formatting, while the table it reads still comes from the
/// bundle's own language — so pinning a language means resolving against that
/// language's `.lproj` directly. Following the device means the main bundle, which
/// is what already picks the right one.
enum L10n {
    /// The locale strings are formatted with; mirrors `AppSettings.locale`.
    nonisolated(unsafe) private(set) static var locale: Locale = .autoupdatingCurrent
    /// The bundle the strings table is read from.
    nonisolated(unsafe) private static var bundle: Bundle = .main

    /// Point programmatic lookups at the chosen language.
    static func use(_ language: AppLanguage) {
        locale = language.locale ?? .autoupdatingCurrent
        bundle = language.locale.flatMap(localizationBundle(for:)) ?? .main
    }

    /// Localized text for a key, in the app's currently selected language.
    ///
    /// Keys are the Portuguese strings themselves (the catalog's source language),
    /// so an untranslated key still renders as correct Portuguese.
    static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle, locale: locale)
    }

    /// The `.lproj` for a locale — exact match first ("pt-BR"), then the bare
    /// language ("pt"), then nil so the caller falls back to the main bundle.
    private static func localizationBundle(for locale: Locale) -> Bundle? {
        let candidates = [locale.identifier, locale.language.languageCode?.identifier]
            .compactMap { $0 }
        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }
}
