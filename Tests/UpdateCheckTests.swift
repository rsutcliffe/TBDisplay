// The update check: version comparison, reading GitHub's answer, trusting the link, and when to check.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runUpdateCheckTests() {
    // Version parsing and comparison
    check(UpdateCheck.components("1.7.1") == [1, 7, 1], "a dotted version is read as numbers")
    check(UpdateCheck.components("v1.8.0") == [1, 8, 0] && UpdateCheck.components("V2") == [2], "a leading v is ignored")
    check(UpdateCheck.components("1.8.0-beta.2") == [1, 8, 0], "a suffix after a dash is ignored")
    check(UpdateCheck.components("latest") == nil && UpdateCheck.components("") == nil && UpdateCheck.components("1..2") == nil, "text that is not a version is refused")
    check(UpdateCheck.isNewer("1.7.1", than: "1.7.0"), "a newer patch is newer")
    check(UpdateCheck.isNewer("1.8.0", than: "1.7.9"), "a newer minor beats a larger patch")
    check(UpdateCheck.isNewer("2.0", than: "1.99.99"), "a newer major is newer")
    check(UpdateCheck.isNewer("1.10.0", than: "1.9.0"), "numbers are compared as numbers, not as text")
    check(UpdateCheck.isNewer("v1.8.0", than: "1.7.0"), "a leading v does not matter")
    check(!UpdateCheck.isNewer("1.7.0", than: "1.7.0"), "the same version is not newer")
    check(!UpdateCheck.isNewer("1.7", than: "1.7.0") && !UpdateCheck.isNewer("1.7.0", than: "1.7"), "1.7 and 1.7.0 are the same")
    check(!UpdateCheck.isNewer("1.6.9", than: "1.7.0"), "an older version is not newer")
    check(!UpdateCheck.isNewer("garbage", than: "1.7.0") && !UpdateCheck.isNewer("1.8.0", than: "garbage"), "an unreadable version never prompts")

    // Which links are trusted
    func trusted(_ s: String) -> Bool { URL(string: s).map(UpdateCheck.isTrustedReleaseURL) ?? false }
    check(trusted("https://github.com/rsutcliffe/TBDisplay/releases/tag/v1.8.0"), "this project's release page is trusted")
    check(!trusted("http://github.com/rsutcliffe/TBDisplay/releases/tag/v1.8.0"), "plain http is not trusted")
    check(!trusted("https://github.com.evil.example/rsutcliffe/TBDisplay/releases/tag/v1.8.0"), "a look-alike host is not trusted")
    check(!trusted("https://evil.example/rsutcliffe/TBDisplay/releases/tag/v1.8.0"), "another host is not trusted")
    check(!trusted("https://github.com/someone/else/releases/tag/v1.8.0"), "another project's page is not trusted")
    check(!trusted("https://github.com/rsutcliffe/TBDisplay-fake/releases/tag/v1.8.0"), "a project with a similar name is not trusted")
    check(!trusted("https://user@github.com/rsutcliffe/TBDisplay/releases/tag/v1.8.0"), "a link with embedded credentials is not trusted")

    // Reading GitHub's answer
    func answer(tag: String? = "v1.8.0", url: String = "https://github.com/rsutcliffe/TBDisplay/releases/tag/v1.8.0", draft: Bool = false, pre: Bool = false) -> Data {
        var d: [String: Any] = ["html_url": url, "draft": draft, "prerelease": pre]
        if let tag { d["tag_name"] = tag }
        return (try? JSONSerialization.data(withJSONObject: d)) ?? Data()
    }
    check(UpdateCheck.parseLatestRelease(answer()) == ReleaseInfo(version: "1.8.0", url: URL(string: "https://github.com/rsutcliffe/TBDisplay/releases/tag/v1.8.0")!), "a normal release is read, without the v")
    check(UpdateCheck.parseLatestRelease(answer(draft: true)) == nil, "a draft is ignored")
    check(UpdateCheck.parseLatestRelease(answer(pre: true)) == nil, "a pre-release is ignored")
    check(UpdateCheck.parseLatestRelease(answer(tag: nil)) == nil, "an answer with no tag is refused")
    check(UpdateCheck.parseLatestRelease(answer(tag: "latest")) == nil, "a tag that is not a version is refused")
    check(UpdateCheck.parseLatestRelease(answer(url: "https://evil.example/x")) == nil, "an untrusted link is refused")
    check(UpdateCheck.parseLatestRelease(Data("not json".utf8)) == nil && UpdateCheck.parseLatestRelease(Data()) == nil, "junk is refused")

    // When to check automatically
    let now = Date(timeIntervalSince1970: 1_000_000)
    check(!UpdateCheck.shouldCheckAutomatically(enabled: false, lastCheck: nil, now: now), "switched off means never")
    check(UpdateCheck.shouldCheckAutomatically(enabled: true, lastCheck: nil, now: now), "never checked means check")
    check(!UpdateCheck.shouldCheckAutomatically(enabled: true, lastCheck: now.addingTimeInterval(-3600), now: now), "an hour ago is too soon")
    check(UpdateCheck.shouldCheckAutomatically(enabled: true, lastCheck: now.addingTimeInterval(-25 * 3600), now: now), "25 hours ago is due")
    check(UpdateCheck.shouldCheckAutomatically(enabled: true, lastCheck: now.addingTimeInterval(-24 * 3600), now: now), "exactly a day ago is due")
    check(UpdateCheck.shouldCheckAutomatically(enabled: true, lastCheck: now.addingTimeInterval(3600), now: now), "a last check in the future (clock changed) is due")

    // The whole check, with a pretend network
    struct Down: Error {}
    func run(_ current: String, _ fetch: @escaping () async throws -> Data) -> UpdateStatus {
        var result: UpdateStatus = .failed("never ran")
        let done = DispatchSemaphore(value: 0)
        Task { result = await UpdateCheck.status(current: current, fetch: fetch); done.signal() }
        _ = done.wait(timeout: .now() + 5)
        return result
    }
    check(run("1.7.0", { answer() }) == .available(ReleaseInfo(version: "1.8.0", url: URL(string: "https://github.com/rsutcliffe/TBDisplay/releases/tag/v1.8.0")!)), "a newer release is reported as available")
    check(run("1.8.0", { answer() }) == .upToDate(latest: "1.8.0"), "the same release means up to date")
    check(run("1.9.0", { answer() }) == .upToDate(latest: "1.8.0"), "a newer build than the release is not offered a downgrade")
    if case .failed(let why) = run("1.7.0", { throw Down() }) { check(why.contains("Could not"), "a network failure is reported plainly") } else { check(false, "a network failure is reported as a failure") }
    if case .failed = run("1.7.0", { Data(repeating: 65, count: UpdateCheck.maxResponseBytes + 1) }) { check(true, "an oversized answer is refused") } else { check(false, "an oversized answer is refused") }
    if case .failed = run("1.7.0", { Data("<html>".utf8) }) { check(true, "a non-release answer is a failure") } else { check(false, "a non-release answer is a failure") }
    if case .failed = run("1.7.0", { answer(url: "https://evil.example/x") }) { check(true, "an untrusted link is a failure, never an update") } else { check(false, "an untrusted link is a failure, never an update") }
}
