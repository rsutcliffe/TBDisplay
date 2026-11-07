// Finding out whether a newer TBDisplay has been released. This only decides and reports: it never downloads or
// runs anything. The person opens the release page and installs the notarised disk image themselves.

import Foundation

struct ReleaseInfo: Equatable {
    let version: String      // without a leading "v"
    let url: URL             // the release page
}

enum UpdateStatus: Equatable {
    case upToDate(latest: String)
    case available(ReleaseInfo)
    case failed(String)
}

enum UpdateCheck {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/rsutcliffe/TBDisplay/releases/latest")!
    static let maxResponseBytes = 1_000_000
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    /// "v1.7.1" gives [1, 7, 1]. Nil when the text is not a dotted number, so nothing odd is ever offered as an update.
    static func components(_ text: String) -> [Int]? {
        var t = Substring(text)
        if let first = t.first, first == "v" || first == "V" { t = t.dropFirst() }
        if let cut = t.firstIndex(where: { $0 == "-" || $0 == "+" }) { t = t[..<cut] }      // "1.8.0-beta" is read as 1.8.0
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = components(candidate), var b = components(current) else { return false }
        while a.count < b.count { a.append(0) }
        while b.count < a.count { b.append(0) }
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }

    /// The release page address must be this project's own, over https, or the answer is not trusted.
    static func isTrustedReleaseURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil else { return false }
        let base = "/rsutcliffe/TBDisplay/releases"
        return parts.path == base || parts.path.hasPrefix(base + "/")
    }

    /// Reads GitHub's "latest release" answer. Nil for drafts, pre-releases, junk and untrusted links.
    static func parseLatestRelease(_ data: Data) -> ReleaseInfo? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }
        guard let tag = object["tag_name"] as? String, components(tag) != nil,
              let link = object["html_url"] as? String, let url = URL(string: link), isTrustedReleaseURL(url) else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, url: url)
    }

    /// At most one automatic check a day, only when switched on. A last-check time in the future (clock changed) counts as due.
    static func shouldCheckAutomatically(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= minimumInterval
    }

    static func status(current: String, fetch: () async throws -> Data) async -> UpdateStatus {
        let data: Data
        do { data = try await fetch() } catch { return .failed("Could not reach GitHub to check for updates.") }
        guard data.count <= maxResponseBytes else { return .failed("GitHub's answer was too large to trust.") }
        guard let release = parseLatestRelease(data) else { return .failed("GitHub's answer was not a release this app understands.") }
        return isNewer(release.version, than: current) ? .available(release) : .upToDate(latest: release.version)
    }
}
