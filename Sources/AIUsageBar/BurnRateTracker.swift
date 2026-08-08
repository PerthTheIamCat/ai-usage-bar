import Foundation

/// Predicts whether a limit window will hit 100% before it resets, by
/// fitting a straight line through recent `usedPercent` readings — the same
/// "linear-extrapolated burn rate" approach every comparable tool in this
/// space converges on independently. Samples are the values the app already
/// displays (post-projection, so a `~`-marked Claude reading contributes
/// too), collected as they arrive rather than re-derived from logs, and kept
/// on disk so a relaunch doesn't throw away the last hour of pace.
enum BurnRateTracker {
    private struct Sample: Codable {
        let at: Date
        let usedPercent: Double
    }

    struct Forecast {
        /// Positive = climbing. Zero or negative means "not currently on pace
        /// to run out" and the caller should show nothing alarming.
        let percentPerMinute: Double
        let etaToFull: Date
        let willDepleteBeforeReset: Bool
    }

    /// Only recent pace matters — a burst three hours ago says nothing about
    /// right now. Long enough to smooth out single-request noise, short
    /// enough to react when someone starts (or stops) a heavy session.
    private static let lookback: TimeInterval = 45 * 60
    /// Comfortably covers one full 5-hour window so samples are never kept
    /// (or trusted) past the point where they'd span a reset.
    private static let maxSampleAge: TimeInterval = 6 * 3600
    private static let maxSamples = 120

    private static func key(_ provider: ProviderKind, _ window: LimitWindowKind) -> String {
        "burnRateSamples.\(provider.rawValue).\(window.rawValue)"
    }

    private static func load(_ provider: ProviderKind, _ window: LimitWindowKind, _ defaults: UserDefaults) -> [Sample] {
        guard let data = defaults.data(forKey: key(provider, window)),
              let samples = try? JSONDecoder().decode([Sample].self, from: data)
        else { return [] }
        return samples
    }

    private static func save(_ provider: ProviderKind, _ window: LimitWindowKind, _ samples: [Sample], _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        defaults.set(data, forKey: key(provider, window))
    }

    /// Call once per refresh with whatever `usedPercent` is currently shown
    /// for that provider/window. Cheap — this only ever touches a handful of
    /// small values, never the logs. `defaults` is only ever overridden by
    /// tests, to keep them from reading or writing this Mac's real state.
    static func record(_ provider: ProviderKind, _ window: LimitWindowKind, usedPercent: Double, at: Date = Date(), defaults: UserDefaults = .standard) {
        var samples = load(provider, window, defaults)
        if let last = samples.last {
            // A drop of more than a couple of points means the window rolled
            // over (or a stale-data fallback replaced a fresher reading) —
            // either way, the climb before it no longer describes "now."
            if usedPercent < last.usedPercent - 2 {
                samples.removeAll()
            } else if abs(usedPercent - last.usedPercent) < 0.05 && at.timeIntervalSince(last.at) < 30 {
                return
            }
        }
        samples.append(Sample(at: at, usedPercent: usedPercent))
        let cutoff = at.addingTimeInterval(-maxSampleAge)
        samples.removeAll { $0.at < cutoff }
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        save(provider, window, samples, defaults)
    }

    /// nil whenever there isn't enough recent signal to say anything, or the
    /// window isn't actually climbing toward full.
    static func forecast(_ provider: ProviderKind, _ window: LimitWindowKind, resetsAt: Date?, now: Date = Date(), defaults: UserDefaults = .standard) -> Forecast? {
        let recent = load(provider, window, defaults).filter { now.timeIntervalSince($0.at) <= lookback }
        guard recent.count >= 3, let latest = recent.last,
              recent.first!.at.distance(to: latest.at) >= 5 * 60,
              let rate = linearRatePerMinute(recent), rate > 0
        else { return nil }

        let minutesToFull = (100 - latest.usedPercent) / rate
        guard minutesToFull.isFinite, minutesToFull > 0 else { return nil }
        let eta = latest.at.addingTimeInterval(minutesToFull * 60)
        return Forecast(percentPerMinute: rate, etaToFull: eta, willDepleteBeforeReset: resetsAt.map { eta < $0 } ?? false)
    }

    /// Ordinary least-squares slope of usedPercent against elapsed minutes.
    private static func linearRatePerMinute(_ samples: [Sample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let t0 = samples[0].at
        let xs = samples.map { $0.at.timeIntervalSince(t0) / 60 }
        let ys = samples.map(\.usedPercent)
        let n = Double(xs.count)
        let sumX = xs.reduce(0, +), sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return nil }
        return (n * sumXY - sumX * sumY) / denominator
    }
}
