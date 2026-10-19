// The iMac's side of pairing: find a MacBook that has its pairing window open, then run the exchange.

import AppKit
import Foundation
import Network

final class PairingGuestController: NSObject {
    var onChange: ((PairingFlowModel?) -> Void)?       // main thread
    private var flow = PairingFlowModel(role: .guest)
    private var browser: NWBrowser?
    private var guest: PairingGuest?
    private let queue = DispatchQueue(label: "tbdisplay.pairing.browse")
    private var found = false
    private var gate = GenerationGate()      // a timer from an earlier attempt must not act on a newer one
    private var latest: [NWBrowser.Result] = []

    @objc func pairPressed() { start() }

    /// The person at this iMac says whether its code matches the MacBook's.
    func answer(_ yes: Bool) { guest?.confirm(yes) }

    func start() {
        flow = PairingFlowModel(role: .guest)
        let generation: Int = queue.sync { found = false; latest = []; return gate.advance() }
        onChange?(flow)
        let browser = NWBrowser(for: .bonjour(type: pairServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.found, gate.isCurrent(generation) else { return }
            let first = self.latest.isEmpty
            self.latest = Array(results)
            guard first, !results.isEmpty else { return }
            // Give other MacBooks a moment to appear, then take the one on the cable if there is one.
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.found, self.gate.isCurrent(generation) else { return }
                let candidates = self.latest.map { PairingCandidate(name: "\($0.endpoint)", interfaces: $0.interfaces.map(\.name)) }
                guard let best = choosePairingCandidate(candidates),
                      let result = self.latest.first(where: { "\($0.endpoint)" == best.name }) else { return }
                self.found = true
                self.browser?.cancel(); self.browser = nil
                self.pair(with: result.endpoint, generation: generation)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        // Nobody answered: say so instead of waiting forever.
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.found, self.gate.isCurrent(generation) else { return }
            self.browser?.cancel(); self.browser = nil
            self.finish(.failed("no MacBook is ready to pair. On the MacBook choose “Pair a new Mac…” in the TBDisplay menu."), generation: generation)
        }
    }

    private func pair(with endpoint: NWEndpoint, generation: Int) {
        let guest = PairingGuest(endpoint: endpoint, callbackQueue: .main)
        guest.onCode = { [weak self] code in self?.flow.codeShown(code); self?.publish() }
        guest.onFinished = { [weak self] outcome in self?.finish(outcome, generation: generation) }
        self.guest = guest
        guest.start()
    }

    private func finish(_ outcome: PairingOutcome, generation: Int) {
        DispatchQueue.main.async {
            self.flow.finished(outcome)
            self.publish()
            // Leave the result up for a while, then go back to the normal status, unless a new attempt started meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if self.queue.sync(execute: { self.gate.isCurrent(generation) }) { self.onChange?(nil) }
            }
        }
    }

    private func publish() { onChange?(flow) }
}
