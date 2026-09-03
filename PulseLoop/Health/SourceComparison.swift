import Foundation
import HealthKit

/// Pure comparison logic behind `CompareSourcesView`: bin heart rate per source, find the bins where
/// sources agree, and find the minutes where two or more sleep sources report the same stage.
enum SourceComparison {
    static let heartRateBinMinutes = 5
    static let heartRateToleranceBpm = 5.0

    // MARK: Heart rate

    struct HeartRateBin: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        /// Mean bpm per source inside this bin.
        let values: [String: Double]
    }

    struct HeartRateAgreement: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let bpm: Double
    }

    static func bins(_ samples: [SourcedHeartRate], minutes: Int = heartRateBinMinutes) -> [HeartRateBin] {
        let width = TimeInterval(minutes * 60)
        var sums: [Date: [String: (sum: Double, n: Int)]] = [:]
        for s in samples {
            let binStart = Date(timeIntervalSince1970: (s.date.timeIntervalSince1970 / width).rounded(.down) * width)
            var bySource = sums[binStart] ?? [:]
            let cur = bySource[s.source] ?? (0, 0)
            bySource[s.source] = (cur.sum + s.bpm, cur.n + 1)
            sums[binStart] = bySource
        }
        return sums.map { date, bySource in
            HeartRateBin(date: date, values: bySource.mapValues { $0.sum / Double($0.n) })
        }
        .sorted { $0.date < $1.date }
    }

    /// Bins where at least two sources have a value and all of them sit within `tolerance` of each other.
    static func agreements(_ bins: [HeartRateBin], tolerance: Double = heartRateToleranceBpm) -> [HeartRateAgreement] {
        bins.compactMap { bin in
            let v = Array(bin.values.values)
            guard v.count >= 2, let lo = v.min(), let hi = v.max(), hi - lo <= tolerance else { return nil }
            return HeartRateAgreement(date: bin.date, bpm: v.reduce(0, +) / Double(v.count))
        }
    }

    // MARK: Sleep

    struct SleepAgreementBlock: Identifiable, Equatable {
        var id: Date { start }
        let start: Date
        let end: Date
        let value: HKCategoryValueSleepAnalysis
    }

    /// Minute runs inside `from..<to` where two or more sources report a stage and every one of them
    /// reports the *same* stage. "In bed" spans are ignored; only stages count.
    static func sleepAgreement(_ segments: [SourcedSleep], from: Date, to: Date) -> [SleepAgreementBlock] {
        let stages = segments.filter { $0.value != .inBed }
        guard Set(stages.map(\.source)).count >= 2 else { return [] }
        let minute: TimeInterval = 60
        var blocks: [SleepAgreementBlock] = []
        var open: (start: Date, value: HKCategoryValueSleepAnalysis)?
        var t = from
        while t < to {
            let next = t.addingTimeInterval(minute)
            var perSource: [String: HKCategoryValueSleepAnalysis] = [:]
            for s in stages where s.start < next && s.end > t {
                perSource[s.source] = s.value
            }
            let values = Set(perSource.values)
            let agreeing = perSource.count >= 2 && values.count == 1 ? values.first : nil
            if let agreeing {
                if let o = open, o.value == agreeing {
                    // still agreeing on the same stage: extend the open block
                } else {
                    if let o = open { blocks.append(SleepAgreementBlock(start: o.start, end: t, value: o.value)) }
                    open = (t, agreeing)
                }
            } else if let o = open {
                blocks.append(SleepAgreementBlock(start: o.start, end: t, value: o.value))
                open = nil
            }
            t = next
        }
        if let o = open { blocks.append(SleepAgreementBlock(start: o.start, end: to, value: o.value)) }
        return blocks
    }

    // MARK: Sources

    /// Stable display order: the Apple Watch first, then alphabetical.
    static func orderedSources(_ sources: some Collection<String>) -> [String] {
        Array(Set(sources)).sorted { a, b in
            let aw = a.localizedCaseInsensitiveContains("watch"), bw = b.localizedCaseInsensitiveContains("watch")
            if aw != bw { return aw }
            return a < b
        }
    }
}
