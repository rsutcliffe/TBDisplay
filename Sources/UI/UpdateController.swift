// The system side of the update check: asks GitHub, remembers when, and tells the person.
// The decisions (versions, links, schedule) are in Sources/Core/UpdateCheck.swift. Nothing is downloaded or installed here:
// the person opens the release page in their browser and installs the notarised disk image themselves.

import AppKit

final class UpdateController {
    static let shared = UpdateController()

    /// Called on the main thread when the known update changes, so a menu or window can refresh.
    var onChange: (() -> Void)?
    private(set) var available: ReleaseInfo?

    /// Switched on unless the person has turned it off. Stored the other way round so a fresh install defaults to on.
    var automaticChecks: Bool {
        get { !Prefs.defaults.bool(forKey: Prefs.updateCheckDisabled) }
        set { Prefs.defaults.set(!newValue, forKey: Prefs.updateCheckDisabled) }
    }

    /// At launch: a quiet check, at most once a day, only if automatic checks are on. It says nothing unless an update exists.
    func checkAtLaunchIfDue() {
        let last = Prefs.defaults.object(forKey: Prefs.lastUpdateCheck) as? Date
        guard UpdateCheck.shouldCheckAutomatically(enabled: automaticChecks, lastCheck: last, now: Date()) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.run(interactive: false) }   // after start-up has settled
    }

    /// From "Check for updates…": always asks, and always shows the answer.
    func checkNow() { run(interactive: true) }

    func openDownloadPage() {
        guard let release = available, UpdateCheck.isTrustedReleaseURL(release.url) else { return }
        NSWorkspace.shared.open(release.url)
    }

    private func run(interactive: Bool) {
        Task {
            let status = await UpdateCheck.status(current: appVersion, fetch: Self.fetchLatestRelease)
            await MainActor.run { UpdateController.shared.finish(status, interactive: interactive) }
        }
    }

    private func finish(_ status: UpdateStatus, interactive: Bool) {
        switch status {
        case .available(let release):
            Prefs.defaults.set(Date(), forKey: Prefs.lastUpdateCheck)
            available = release
            log("A newer TBDisplay is available: \(release.version) (you have \(appVersion)). \(release.url.absoluteString)")
        case .upToDate(let latest):
            Prefs.defaults.set(Date(), forKey: Prefs.lastUpdateCheck)
            available = nil
            log("TBDisplay is up to date (\(appVersion), latest release \(latest)).")
        case .failed(let why):
            log("Update check failed: \(why)")
        }
        onChange?()
        guard interactive else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch status {
        case .available(let release):
            alert.messageText = "TBDisplay \(release.version) is available"
            alert.informativeText = "You have \(appVersion). Open the release page to download the new disk image, then install it on both Macs. TBDisplay never downloads or installs anything by itself."
            alert.addButton(withTitle: "Open download page")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { openDownloadPage() }
        case .upToDate(let latest):
            alert.messageText = "TBDisplay is up to date"
            alert.informativeText = "You have \(appVersion), and the latest release is \(latest)."
            alert.runModal()
        case .failed(let why):
            alert.messageText = "Could not check for updates"
            alert.informativeText = why
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// One plain request to GitHub's public API. No account, no cookies, and nothing about this Mac is sent except the app name and version.
    private static func fetchLatestRelease() async throws -> Data {
        var request = URLRequest(url: UpdateCheck.latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TBDisplay/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "api.github.com" else { throw URLError(.badServerResponse) }
        return data
    }
}
