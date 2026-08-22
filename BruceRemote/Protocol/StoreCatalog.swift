import Foundation

/// Data model for the community Bruce App Store, served from `ghp.iceis.co.uk`.
///
/// The same catalog the on-device store (`installAppStoreJS`) reads. Endpoints:
/// - `…/service/main/releases/categories.json` — the category index.
/// - `…/service/main/releases/category-<slug>.min.json` — apps in a category.
/// - `…/service/main/repositories/<owner>/<repo>/<app>/metadata.json` — file list.
/// - `…/service/manual/<owner>/<repo>/<commit>/<file>` — a file's bytes.
///
/// The on-device store saves apps under `/BruceJS/<Category>/<file>` and tracks
/// what it installed in `/BruceAppStore/installed.json`; this app mirrors both so
/// the two stores stay interoperable.

// MARK: - Catalog index

/// The top-level `categories.json` payload.
struct StoreCatalog: Decodable {
    let totalCategories: Int
    let totalApps: Int
    let categories: [StoreCategory]
}

/// One category as listed in the index.
struct StoreCategory: Decodable, Identifiable, Hashable {
    let name: String
    let slug: String
    let count: Int
    let lastUpdated: Int

    var id: String { slug }

    /// Themes are `.css`-style theme files applied via settings, not runnable
    /// scripts — out of scope for the JS-app store, so the UI hides this category.
    var isThemes: Bool { slug.caseInsensitiveCompare("themes") == .orderedSame }
}

// MARK: - Apps in a category

/// The `category-<slug>.min.json` payload.
///
/// `apps` is decoded through `FailableDecodable` so a single bad entry drops out
/// instead of failing the whole category (which would blank the menu).
struct StoreCategoryApps: Decodable {
    let category: String
    let count: Int
    let apps: [FailableDecodable<StoreApp>]
}

/// Decodes `T` if it can, otherwise holds `nil` instead of throwing — used to make
/// arrays tolerant of individual malformed elements.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A store app as listed inside a category. Field names are the catalog's terse
/// keys (`n`, `d`, `v`, `s`, `sd`).
struct StoreApp: Decodable, Identifiable, Hashable {
    /// Display name.
    let name: String
    /// Description.
    let details: String
    /// Version string (e.g. "1.0.1").
    let version: String
    /// Repository identifier, `owner/repo/appFolder` — the catalog's stable key.
    let slug: String
    /// Supported devices, when the author restricts the app. `nil` means unlisted.
    let supportedDevices: [String]?

    /// Category name, filled in by the client (not present in the per-app JSON).
    var category: String = ""

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case details = "d"
        case version = "v"
        case slug = "s"
        case supportedDevices = "sd"
    }

    /// The catalog key doubles as identity; it is unique across the store.
    var id: String { slug }

    /// `owner`, `repo`, `appFolder` parsed out of `slug`. The app folder can itself
    /// contain slashes in principle, so everything past the second `/` is the app.
    var repositoryPath: (owner: String, repo: String, app: String)? {
        let parts = slug.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }
}

// MARK: - App metadata (file manifest)

/// The `metadata.json` for one app: what files to fetch and at which commit.
struct StoreAppMetadata: Decodable {
    let name: String
    let description: String
    let category: String
    let version: String
    let commit: String
    let owner: String
    let repo: String
    /// Repository-relative directory the files live in (usually "/").
    let path: String
    /// File entries. Each is a repo-relative name; the app installs them flat under
    /// its category folder.
    let files: [String]
}

// MARK: - Install ledger

/// One installed app's provenance, mirroring the on-device `installed.json` values.
struct InstalledApp: Codable, Hashable {
    let version: String
    let commit: String
    /// Absolute device paths this app wrote, so removal is exact. Empty for an app
    /// discovered from the device's `installed.json` that this app didn't install.
    var files: [String]
    /// The runnable entry point, when the app has a `.js` to launch.
    var entryPath: String?
}

/// The exact shape of one entry in the device's `/BruceAppStore/installed.json`,
/// which the on-device store writes as `{ "<slug>": { version, commit } }`.
struct DeviceLedgerEntry: Codable, Hashable {
    let version: String
    let commit: String
}
