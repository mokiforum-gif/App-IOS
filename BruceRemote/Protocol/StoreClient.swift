import Foundation

/// Fetches the community App Store catalog and app files over HTTPS.
///
/// The firmware talks to this host over plain HTTP, but it also serves HTTPS, so
/// the app uses HTTPS and needs no App Transport Security exception. Everything is
/// `async` and returns decoded models (or `StoreError`); nothing here touches BLE.
struct StoreClient {
    /// Community store host. HTTPS avoids an ATS cleartext exception.
    static let baseURL = URL(string: "https://ghp.iceis.co.uk")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Catalog

    /// The category index (`categories.json`).
    func fetchCatalog() async throws -> StoreCatalog {
        try await getJSON(path: ["service", "main", "releases", "categories.json"])
    }

    /// The apps in one category (`category-<slug>.min.json`), tagged with the
    /// category name so a flattened list still knows where each app belongs.
    ///
    /// One malformed app entry must not blank the whole category: `apps` is decoded
    /// leniently, dropping entries that fail to parse rather than throwing.
    func fetchApps(in category: StoreCategory) async throws -> [StoreApp] {
        let payload: StoreCategoryApps = try await getJSON(
            path: ["service", "main", "releases", "category-\(category.slug).min.json"]
        )
        return payload.apps.compactMap(\.value).map {
            var app = $0; app.category = payload.category; return app
        }
    }

    /// The file manifest for one app (`metadata.json`).
    func fetchMetadata(for app: StoreApp) async throws -> StoreAppMetadata {
        guard let repo = app.repositoryPath else { throw StoreError.malformedApp(app.slug) }
        return try await getJSON(
            path: ["service", "main", "repositories", repo.owner, repo.repo, repo.app, "metadata.json"]
        )
    }

    /// The bytes of one file (`service/manual/<owner>/<repo>/<commit>/<file>`).
    func fetchFile(_ file: String, metadata: StoreAppMetadata) async throws -> Data {
        let repoRelative = Self.repoRelativePath(dir: metadata.path, file: file)
        let url = Self.url(path:
            ["service", "manual", metadata.owner, metadata.repo, metadata.commit] + repoRelative
        )
        let (data, response) = try await session.data(from: url)
        try Self.check(response, url: url)
        return data
    }

    // MARK: - Path helpers

    /// The repo-relative path segments of a file, joining the manifest's directory
    /// (usually "/") with the file name and dropping empty segments.
    static func repoRelativePath(dir: String, file: String) -> [String] {
        (dir + "/" + file)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: - Fetching

    private func getJSON<T: Decodable>(path: [String]) async throws -> T {
        let url = Self.url(path: path)
        let (data, response) = try await session.data(from: url)
        try Self.check(response, url: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StoreError.decoding(url.absoluteString)
        }
    }

    /// Build a URL by percent-encoding each path segment (names contain spaces).
    private static func url(path: [String]) -> URL {
        var url = baseURL
        for segment in path {
            let encoded = segment.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed) ?? segment
            url.appendPathComponent(encoded)
        }
        return url
    }

    private static func check(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw StoreError.http(status: http.statusCode, url: url.absoluteString)
        }
    }
}

/// URL-encoding set for a single path segment: reserved delimiters stay encoded so
/// a name like "Device Info" or "App Store" survives as one component.
private extension CharacterSet {
    static let urlPathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#[]")
        return set
    }()
}

/// A store fetch that failed, with enough context to show the user.
enum StoreError: LocalizedError {
    case http(status: Int, url: String)
    case decoding(String)
    case malformedApp(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, _):  return L10n.t("A loja respondeu com erro \(status).")
        case .decoding:             return L10n.t("Não foi possível ler o catálogo da loja.")
        case .malformedApp:         return L10n.t("Este app tem um identificador inválido.")
        }
    }
}
