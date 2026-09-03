import Foundation
import HealthKit

/// The pure half of the Apple Health import: which sources count, which source owns a night, how a
/// Health sleep value maps onto a `SleepStage`, and how a dense Watch heart-rate stream is thinned.
enum HealthImportPlanner {
    enum SourceClass: Equatable {
        /// PulseLoop's own export — never imported (it came from here).
        case own
        /// An Apple Watch (or anything else Apple's Health stack writes for a device).
        case watch
        /// Any other writer: a ring app, a scale app, a manual Health entry.
        case other
    }

    static func classify(sourceName: String, bundleIdentifier: String, ownBundleIdentifier: String) -> SourceClass {
        if bundleIdentifier == ownBundleIdentifier { return .own }
        if sourceName.localizedCaseInsensitiveContains("watch") || bundleIdentifier.hasPrefix("com.apple.health") {
            return .watch
        }
        return .other
    }

    /// Whether a sample from this class is imported under the current toggles.
    static func isImported(_ cls: SourceClass, importWatch: Bool) -> Bool {
        switch cls {
        case .own: return false
        case .watch: return importWatch
        case .other: return true
        }
    }

    // MARK: Sleep

    struct SleepSegment: Equatable {
        let start: Date
        let end: Date
        let stage: SleepStage
        let source: String
        let sourceClass: SourceClass
    }

    /// Health's sleep values onto PulseLoop's stages. "In bed" carries no stage and is dropped.
    static func stage(for value: HKCategoryValueSleepAnalysis) -> SleepStage? {
        switch value {
        case .asleepCore, .asleepUnspecified: return .light
        case .asleepDeep: return .deep
        case .asleepREM: return .rem
        case .awake: return .awake
        case .inBed: return nil
        @unknown default: return nil
        }
    }

    /// One waking day, owned by exactly one source.
    struct Night: Equatable {
        let day: Date
        let source: String
        let segments: [SleepSegment]
    }

    private struct Candidate {
        let cls: SourceClass
        var minutes: Double = 0
        var segments: [SleepSegment] = []
    }

    /// One source per waking day. A ring app (`.other`) always beats the Watch; among several ring
    /// apps the one with the most minutes wins. The Watch only fills days no ring app covered, and only
    /// when Watch import is on. Mixing two sources' minute grids into one night would be garbage.
    static func nightsBySource(_ segments: [SleepSegment], importWatch: Bool, calendar: Calendar = .current) -> [Night] {
        var byDay: [Date: [String: Candidate]] = [:]
        for seg in segments where isImported(seg.sourceClass, importWatch: importWatch) {
            let day = calendar.wakingDay(forSleepStart: seg.start)
            var sources = byDay[day] ?? [:]
            var entry = sources[seg.source] ?? Candidate(cls: seg.sourceClass)
            entry.minutes += seg.end.timeIntervalSince(seg.start) / 60
            entry.segments.append(seg)
            sources[seg.source] = entry
            byDay[day] = sources
        }
        return byDay.keys.sorted().compactMap { day in
            guard let sources = byDay[day] else { return nil }
            let ranked = sources.sorted { a, b in
                if a.value.cls != b.value.cls { return a.value.cls == .other }
                return a.value.minutes > b.value.minutes
            }
            guard let best = ranked.first else { return nil }
            return Night(day: day, source: best.key, segments: best.value.segments.sorted { $0.start < $1.start })
        }
    }

    /// A contiguous per-minute stage array for one segment (`persistTimeline` wants exactly that).
    static func minutes(of segment: SleepSegment) -> [SleepStage] {
        let count = Int(segment.end.timeIntervalSince(segment.start) / 60)
        return Array(repeating: segment.stage, count: max(0, count))
    }

    // MARK: Heart rate

    /// The Watch writes heart rate every few seconds during a workout. Thin it to one mean per minute so
    /// the vitals store keeps ring-like density; ring apps are left as they are.
    static func thinnedPerMinute(_ samples: [(date: Date, value: Double)]) -> [(date: Date, value: Double)] {
        var sums: [Date: (sum: Double, n: Int)] = [:]
        for s in samples {
            let minute = Date(timeIntervalSince1970: (s.date.timeIntervalSince1970 / 60).rounded(.down) * 60)
            let cur = sums[minute] ?? (0, 0)
            sums[minute] = (cur.sum + s.value, cur.n + 1)
        }
        return sums.keys.sorted().map { ($0, (sums[$0]?.sum ?? 0) / Double(max(1, sums[$0]?.n ?? 1))) }
    }
}
