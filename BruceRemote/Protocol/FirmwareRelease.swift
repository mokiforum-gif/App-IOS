import Foundation

/// The latest Bruce firmware release, from the GitHub Releases API.
///
/// This backs the firmware **update checker**: the app can read the version the
/// device reports (`info` → `DeviceInfo.version`) and compare it to the newest
/// release, then hand the user off to the web flasher. It cannot flash the device
/// itself — that needs USB (ESP Web Tools) or a firmware with OTA, neither of which
/// is possible from iOS with the current firmware.
struct FirmwareRelease: Decodable {
    /// Release tag, e.g. "1.16" — the version string to compare against.
    let tagName: String
    let name: String?
    /// Release notes (markdown), shown as plain text.
    let body: String?
    /// The release page on GitHub.
    let htmlURL: String
    let publishedAt: Date?
    let assets: [Asset]

    struct Asset: Decodable, Hashable {
        let name: String
        let downloadURL: String
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
            case size
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

extension FirmwareRelease {
    /// The `.bin` for a device, matched from what `info` reports as its name.
    ///
    /// Prefers an exact `Bruce-<device>.bin` match so a plain "Lilygo T-Embed" does
    /// not pick up the "…-cc1101" build (whose name merely contains the shorter one),
    /// falling back to a contains match when there is no exact one.
    func asset(forDeviceNamed deviceName: String?) -> Asset? {
        guard let deviceName, !deviceName.isEmpty else { return nil }
        let key = Self.normalize(deviceName)
        guard !key.isEmpty else { return nil }

        if let exact = assets.first(where: {
            $0.name.lowercased().hasSuffix(".bin")
            && Self.normalize(String($0.name.dropLast(4))) == "bruce-\(key)"
        }) {
            return exact
        }
        return assets.first {
            $0.name.lowercased().hasSuffix(".bin") && Self.normalize($0.name).contains(key)
        }
    }

    /// Lowercase, keep alphanumerics, turn separators into single dashes:
    /// "Lilygo T-Embed CC1101" → "lilygo-t-embed-cc1101".
    static func normalize(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" || ch == "." { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Numeric version comparison tolerant of tags like "1.16", "1.16.1" or "dev".
enum FirmwareVersion {
    /// Leading dotted number groups, e.g. "1.16.1-beta" → [1, 16, 1]; "dev" → [].
    static func components(_ s: String) -> [Int] {
        let head = s.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        return head.split(separator: ".").compactMap { Int($0) }
    }

    /// Comparison of two version strings, or nil when either can't be parsed.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        let a = components(lhs), b = components(rhs)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// True when `latest` is strictly newer than `installed`. Nil when unknown.
    static func isUpdate(installed: String?, latest: String) -> Bool? {
        guard let installed else { return nil }
        guard let result = compare(installed, latest) else { return nil }
        return result == .orderedAscending
    }
}

/// Fetches the latest firmware release from GitHub.
struct FirmwareService {
    /// Canonical Bruce firmware repo (the old `pr3y/Bruce` redirects here).
    static let repo = "BruceDevices/firmware"
    /// The web flasher (USB / ESP Web Tools) — the actual way to flash the device.
    static let flasherURL = URL(string: "https://bruce.computer/flasher")!

    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func latestRelease() async throws -> FirmwareRelease {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests with no User-Agent.
        request.setValue("BruceRemote", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FirmwareError.http(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(FirmwareRelease.self, from: data)
        } catch {
            throw FirmwareError.decoding
        }
    }
}

enum FirmwareError: LocalizedError {
    case http(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .http(let status): return L10n.t("O GitHub respondeu com erro \(status).")
        case .decoding:         return L10n.t("Não foi possível ler a lista de versões.")
        }
    }
}
