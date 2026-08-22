import Foundation

/// The Bruce App Store: browses the community catalog and installs, runs, updates
/// and removes JavaScript apps on the connected device.
///
/// Catalog data comes from `StoreClient` (network). Installs go through `BLEManager`
/// (files over BLE, then `js run_from_file`). What this app installed is tracked in
/// a local ledger under `Documents`, keyed by the catalog's stable app id (`slug`);
/// the ledger records every device path an app wrote, so removal is exact.
@MainActor
final class AppStore: ObservableObject {
    /// Category index, Themes filtered out (they are not runnable scripts).
    @Published private(set) var categories: [StoreCategory] = []
    /// Apps per category slug, fetched lazily and cached.
    @Published private(set) var appsByCategory: [String: [StoreApp]] = [:]
    /// What this app has installed, keyed by `StoreApp.id` (the catalog slug).
    @Published private(set) var installed: [String: InstalledApp] = [:]

    /// Loading state of the top-level catalog.
    @Published private(set) var catalogState: LoadState = .idle
    /// Loading state per category slug (for the apps list).
    @Published private(set) var categoryState: [String: LoadState] = [:]
    /// Apps with an operation (install/update/remove) in flight, by app id.
    @Published private(set) var busy: Set<String> = []
    /// Install progress 0…1 per app id, while an install/update runs.
    @Published private(set) var progress: [String: Double] = [:]

    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    private let client: StoreClient
    private let ledgerURL: URL

    init(client: StoreClient = StoreClient()) {
        self.client = client
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        ledgerURL = docs.appendingPathComponent("appstore-installed.json")
        loadLedger()
    }

    // MARK: - Catalog

    /// Load the category index. Skips the network if already loaded, unless forced.
    func loadCatalog(force: Bool = false) async {
        if case .loaded = catalogState, !force, !categories.isEmpty { return }
        catalogState = .loading
        do {
            let catalog = try await client.fetchCatalog()
            categories = catalog.categories.filter { !$0.isThemes }
            catalogState = .loaded
        } catch {
            catalogState = .failed(message(for: error))
        }
    }

    /// Load (and cache) the apps in a category.
    func loadApps(in category: StoreCategory, force: Bool = false) async {
        if !force, appsByCategory[category.slug] != nil { return }
        categoryState[category.slug] = .loading
        do {
            let apps = try await client.fetchApps(in: category)
            appsByCategory[category.slug] = apps
            categoryState[category.slug] = .loaded
        } catch {
            categoryState[category.slug] = .failed(message(for: error))
        }
    }

    // MARK: - Install state

    func installedRecord(for app: StoreApp) -> InstalledApp? { installed[app.id] }
    func isInstalled(_ app: StoreApp) -> Bool { installed[app.id] != nil }
    func isBusy(_ app: StoreApp) -> Bool { busy.contains(app.id) }
    func installProgress(for app: StoreApp) -> Double? { progress[app.id] }

    /// Whether the catalog lists a newer version than the installed one.
    func updateAvailable(for app: StoreApp) -> Bool {
        guard let record = installed[app.id] else { return false }
        return record.version != app.version
    }

    /// The runnable entry point of an installed app, if it has one.
    func entryPath(for app: StoreApp) -> String? { installed[app.id]?.entryPath }

    // MARK: - Install / update / remove

    /// Download an app's files and write them to the device. On success the app is
    /// recorded in the ledger. Returns nil on success or a message to display.
    ///
    /// Update reuses this path: it overwrites the same files and, if the file set
    /// shrank, deletes the ones the new version dropped.
    @discardableResult
    func install(_ app: StoreApp, using ble: BLEManager) async -> String? {
        guard !busy.contains(app.id) else { return nil }
        guard ble.state == .ready else { return L10n.t("Conecte-se ao Bruce para instalar.") }

        busy.insert(app.id)
        progress[app.id] = 0
        defer { busy.remove(app.id); progress[app.id] = nil }

        let previousFiles = installed[app.id]?.files ?? []

        do {
            let metadata = try await client.fetchMetadata(for: app)
            let installDir = "\(BruceFolder.js)/\(metadata.category)"

            var writtenPaths: [String] = []
            var entryPath: String?
            let total = max(metadata.files.count, 1)

            for (index, file) in metadata.files.enumerated() {
                let name = installName(from: file)
                let devicePath = "\(installDir)/\(name)"
                let data = try await client.fetchFile(file, metadata: metadata)

                if let failure = await ble.installStoreFile(path: devicePath, data: data, progress: { fraction in
                    self.progress[app.id] = (Double(index) + fraction) / Double(total)
                }) {
                    return failure
                }

                writtenPaths.append(devicePath)
                if entryPath == nil, name.lowercased().hasSuffix(".js") { entryPath = devicePath }
                progress[app.id] = Double(index + 1) / Double(total)
            }

            // Prefer a `.js` whose name matches the app for the Run action.
            if let match = writtenPaths.first(where: {
                ($0 as NSString).lastPathComponent.caseInsensitiveCompare("\(app.name).js") == .orderedSame
            }) {
                entryPath = match
            }

            // On update, remove files the new version no longer ships.
            let orphans = previousFiles.filter { !writtenPaths.contains($0) }
            if !orphans.isEmpty { await ble.removeStoreFiles(orphans) }

            installed[app.id] = InstalledApp(
                version: app.version,
                commit: metadata.commit,
                files: writtenPaths,
                entryPath: entryPath
            )
            saveLedger()
            await writeDeviceLedgerEntry(id: app.id,
                                         entry: DeviceLedgerEntry(version: app.version, commit: metadata.commit),
                                         using: ble)
            return nil
        } catch {
            return message(for: error)
        }
    }

    /// Remove an installed app's files from the device and forget it. Works whether
    /// the app was installed by this app (files known) or discovered from the
    /// device's ledger (files resolved from the catalog on demand).
    @discardableResult
    func remove(_ app: StoreApp, using ble: BLEManager) async -> String? {
        await removeInstalled(slug: app.id, using: ble)
    }

    /// Launch an installed app, resolving its entry point from the catalog if this
    /// app didn't install it and so doesn't know the path yet.
    @discardableResult
    func run(_ app: StoreApp, using ble: BLEManager) async -> String? {
        await runInstalled(slug: app.id, using: ble)
    }

    // MARK: - Installed apps (by slug)

    /// Installed apps as a list, sorted by display name, for the "Instalados" view.
    var installedList: [(slug: String, record: InstalledApp)] {
        installed
            .map { (slug: $0.key, record: $0.value) }
            .sorted { displayName(forSlug: $0.slug).localizedCaseInsensitiveCompare(displayName(forSlug: $1.slug)) == .orderedAscending }
    }

    func isBusy(slug: String) -> Bool { busy.contains(slug) }

    /// The app's friendly name from its `owner/repo/app` slug: the last component.
    func displayName(forSlug slug: String) -> String {
        (slug as NSString).lastPathComponent
    }

    /// Launch an installed app by slug. If the entry point is unknown (the app was
    /// discovered from the device ledger, not installed here), resolves it from the
    /// catalog first.
    @discardableResult
    func runInstalled(slug: String, using ble: BLEManager) async -> String? {
        guard ble.state == .ready else { return L10n.t("Conecte-se ao Bruce para rodar.") }
        if let path = installed[slug]?.entryPath {
            ble.runScript(at: path)
            return nil
        }
        guard !busy.contains(slug) else { return nil }
        busy.insert(slug); defer { busy.remove(slug) }
        guard let resolved = await resolveFileInfo(slug: slug) else {
            return L10n.t("Não foi possível localizar o app na loja.")
        }
        installed[slug] = resolved
        saveLedger()
        guard let path = resolved.entryPath else { return L10n.t("Este app não tem um script para rodar.") }
        ble.runScript(at: path)
        return nil
    }

    /// Remove an installed app by slug: delete its files, forget it locally, and
    /// drop it from the device ledger. Resolves the file list from the catalog when
    /// this app didn't install it.
    @discardableResult
    func removeInstalled(slug: String, using ble: BLEManager) async -> String? {
        guard installed[slug] != nil else { return nil }
        guard ble.state == .ready else { return L10n.t("Conecte-se ao Bruce para remover.") }
        guard !busy.contains(slug) else { return nil }

        busy.insert(slug); defer { busy.remove(slug) }

        var files = installed[slug]?.files ?? []
        if files.isEmpty, let resolved = await resolveFileInfo(slug: slug) {
            files = resolved.files
        }
        await ble.removeStoreFiles(files)
        installed[slug] = nil
        saveLedger()
        await writeDeviceLedgerEntry(id: slug, entry: nil, using: ble)
        return nil
    }

    /// Fetch metadata for a slug and compute the exact device paths it installs to,
    /// so a device-discovered app can still be run or removed precisely.
    private func resolveFileInfo(slug: String) async -> InstalledApp? {
        let stub = StoreApp(name: displayName(forSlug: slug), details: "",
                            version: installed[slug]?.version ?? "",
                            slug: slug, supportedDevices: nil, category: "")
        guard let metadata = try? await client.fetchMetadata(for: stub) else { return nil }
        let installDir = "\(BruceFolder.js)/\(metadata.category)"
        let paths = metadata.files.map { "\(installDir)/\(installName(from: $0))" }
        let entry = paths.first { ($0 as NSString).lastPathComponent.caseInsensitiveCompare("\(metadata.name).js") == .orderedSame }
            ?? paths.first { $0.lowercased().hasSuffix(".js") }
        return InstalledApp(version: metadata.version, commit: metadata.commit,
                            files: paths, entryPath: entry)
    }

    // MARK: - Device ledger (/BruceAppStore/installed.json)

    /// Path of the on-device store's install record.
    private var deviceLedgerPath: String { "\(BruceFolder.appStore)/installed.json" }

    /// Merge the device's `installed.json` into the local ledger so install badges
    /// and the "Instalados" list reflect what is actually on the device — including
    /// apps installed by the on-device store. Device values win for version/commit;
    /// local file/entry info is preserved. Does not prune local-only records.
    func syncInstalledFromDevice(using ble: BLEManager) async {
        guard ble.state == .ready else { return }
        let device = await readDeviceLedger(using: ble)
        guard !device.isEmpty else { return }

        var merged = installed
        for (id, entry) in device {
            let local = merged[id]
            merged[id] = InstalledApp(version: entry.version, commit: entry.commit,
                                      files: local?.files ?? [], entryPath: local?.entryPath)
        }
        if merged != installed {
            installed = merged
            saveLedger()
        }
    }

    /// Read and parse the device ledger. Missing file or unparsable content yields
    /// an empty map (treated as "nothing installed there").
    private func readDeviceLedger(using ble: BLEManager) async -> [String: DeviceLedgerEntry] {
        let lines = await ble.request(StorageCommand.read(path: deviceLedgerPath), timeout: 15, echo: false)
        let joined = lines.joined(separator: "\n")
        guard let start = joined.firstIndex(of: "{"), let end = joined.lastIndex(of: "}"), start <= end,
              let data = String(joined[start...end]).data(using: .utf8),
              let map = try? JSONDecoder().decode([String: DeviceLedgerEntry].self, from: data)
        else { return [:] }
        return map
    }

    /// Read-modify-write one entry in the device ledger, preserving entries this app
    /// doesn't manage (e.g. those written by the on-device store).
    private func writeDeviceLedgerEntry(id: String, entry: DeviceLedgerEntry?, using ble: BLEManager) async {
        guard ble.state == .ready else { return }
        var map = await readDeviceLedger(using: ble)
        if let entry { map[id] = entry } else { map.removeValue(forKey: id) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(map), let json = String(data: data, encoding: .utf8) else { return }
        _ = await ble.saveTextFileVerified(path: deviceLedgerPath, content: json)
    }

    // MARK: - Ledger persistence

    private func loadLedger() {
        guard let data = try? Data(contentsOf: ledgerURL) else { return }
        installed = (try? JSONDecoder().decode([String: InstalledApp].self, from: data)) ?? [:]
    }

    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: ledgerURL)
    }

    // MARK: - Helpers

    /// The install name under the category folder, mirroring the on-device store:
    /// the file's repo-relative path with leading slashes stripped, so nested assets
    /// (`assets/icon.png`) keep their subfolder instead of being flattened.
    private func installName(from entry: String) -> String {
        var name = entry
        while name.hasPrefix("/") { name.removeFirst() }
        return name
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? L10n.t("Falha de rede ao acessar a loja.")
    }
}
