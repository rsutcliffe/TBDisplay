// Collects timings for one stage of the pipeline (capture, encode, send, decode) and summarises them.

import Foundation

struct LatencyStats {
    private var samples: [Double] = []
    var count: Int { samples.count }
    mutating func add(_ milliseconds: Double) { samples.append(milliseconds) }
    var average: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }
    var maximum: Double { samples.max() ?? 0 }
    func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }
    mutating func reset() { samples.removeAll(keepingCapacity: true) }
    func summary(_ label: String) -> String {
        guard !samples.isEmpty else { return "\(label): no frames" }
        return "\(label) avg \(String(format: "%.1f", average)) ms, p95 \(String(format: "%.1f", percentile(0.95))) ms, max \(String(format: "%.1f", maximum)) ms (\(count) frames)"
    }
}
