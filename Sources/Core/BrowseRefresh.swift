// While the iMac client is looking for the MacBook, Bonjour can go quiet for good: after the cable link drops and
// returns, the search never reports the MacBook on the Thunderbolt Bridge again, and only restarting the client
// helped. So a search that has found nothing for a while is started afresh.

import Foundation

enum BrowseRefresh {
    static let interval: TimeInterval = 10

    static func due(startedAt: Date, now: Date, interval: TimeInterval = BrowseRefresh.interval) -> Bool { now.timeIntervalSince(startedAt) >= interval }
}
