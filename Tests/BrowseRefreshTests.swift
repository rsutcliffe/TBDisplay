// A search for the MacBook that has gone quiet is started again, so the client recovers when the cable link returns.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runBrowseRefreshTests() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    check(!BrowseRefresh.due(startedAt: start, now: start), "a search that has just started is left alone")
    check(!BrowseRefresh.due(startedAt: start, now: start.addingTimeInterval(9.9)), "a search under ten seconds old is left alone")
    check(BrowseRefresh.due(startedAt: start, now: start.addingTimeInterval(10)), "a search ten seconds old is started again")
    check(BrowseRefresh.due(startedAt: start, now: start.addingTimeInterval(600)), "a very old search is started again")
    check(!BrowseRefresh.due(startedAt: start, now: start.addingTimeInterval(-5)), "a clock that moved back does not restart it")
    check(BrowseRefresh.due(startedAt: start, now: start.addingTimeInterval(3), interval: 2), "the interval can be changed")
}
