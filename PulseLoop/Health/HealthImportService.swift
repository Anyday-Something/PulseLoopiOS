import Foundation
import HealthKit
import Observation
import SwiftData

/// Reads heart rate, blood oxygen and sleep **out of** Apple Health — from other apps and devices, never
/// from PulseLoop's own export — into PulseLoop's own store, so the Sleep, Vitals and Today screens show
/// a ring that another app synced (or the Watch) exactly as if this app had synced it.
///
/// Imported rows are marked (`MeasurementSource.healthImport`; sleep sessions via a `DerivedUpdateRow`
/// marker) so `HealthSyncService` never writes them back out. Read access rides on the same
/// authorization prompt as the export (`readTypes` covers the share types). Ring apps are imported by
/// default; the Watch only with its own toggle, and its heart rate is thinned to one value per minute.
@MainActor
@Observable
final class HealthImportService {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let shared = HealthImportService()

    private let store = HKHealthStore()
    private let defaults = UserDefaults.standard
    private(set) var isImporting = false
    private(set) var lastResult: String?
    private(set) var lastRunAt: Date?

    /// How far back the very first import looks.
    static let firstRunWindowDays = 30
    /// Foreground runs are throttled to this.
    static let foregroundThrottle: TimeInterval = 300
    static let sleepMarkerKind = "health_import"
    static let sleepMarkerEntity = "sleep_session"

    private var prefs: AppleHealthPrefs { AppleHealthPrefsStore.shared.prefs }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var isRunningUnitTests: Bool { NSClassFromString("XCTestCase") != nil }

    // MARK: Entry points

    /// Foreground hook: runs when the import is on and the last run is older than the throttle.
    func importIfDue(context: ModelContext) {
        guard prefs.importFromHealth, isAvailable, !isRunningUnitTests else { return }
        if let last = lastRunAt, Date().timeIntervalSince(last) < Self.foregroundThrottle { return }
        Task { await importNow(context: context) }
    }

    /// Settings button + foreground hook. Returns after the store is saved.
    func importNow(context: ModelContext) async {
        guard !isImporting, isAvailable, !isRunningUnitTests else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let hr = try await importQuantity(.heartRate, kind: .heartRate, context: context) {
                $0.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            }
            let spo2 = try await importQuantity(.oxygenSaturation, kind: .spo2, context: context) {
                $0.doubleValue(for: .percent()) * 100
            }
            let nights = try await importSleep(context: context)
            try context.save()
            if hr + spo2 + nights > 0 { PulseDataChange.shared.notify() }
            lastRunAt = Date()
            lastResult = "Imported \(hr) heart-rate, \(spo2) SpO₂ samples and \(nights) night\(nights == 1 ? "" : "s") "
                + "at \(Date().formatted(date: .omitted, time: .shortened))."
        } catch {
            lastResult = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: Quantities

    private func importQuantity(_ id: HKQuantityTypeIdentifier, kind: MeasurementKind, context: ModelContext,
                                value: (HKQuantity) -> Double) async throws -> Int {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { return 0 }
        let since = watermark(kind.rawValue) ?? Calendar.current.date(byAdding: .day, value: -Self.firstRunWindowDays, to: Date())!
        let now = Date()
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: foreignWindow(from: since, to: now))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let own = Bundle.main.bundleIdentifier ?? ""
        let importWatch = prefs.importFromWatch

        var ringApps: [(date: Date, value: Double)] = []
        var watch: [(date: Date, value: Double)] = []
        for s in samples {
            let cls = HealthImportPlanner.classify(sourceName: s.sourceRevision.source.name,
                                                   bundleIdentifier: s.sourceRevision.source.bundleIdentifier,
                                                   ownBundleIdentifier: own)
            guard HealthImportPlanner.isImported(cls, importWatch: importWatch) else { continue }
            if cls == .watch { watch.append((s.startDate, value(s.quantity))) } else { ringApps.append((s.startDate, value(s.quantity))) }
        }
        let incoming = ringApps + (kind == .heartRate ? HealthImportPlanner.thinnedPerMinute(watch) : watch)
        guard !incoming.isEmpty else { return 0 }

        // Skip anything already stored at that second, whatever its source (a ring sync may have
        // delivered the same reading directly).
        let raw = kind.rawValue
        let existing = (try? context.fetch(FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == raw && $0.timestamp >= since }
        ))) ?? []
        var seen = Set(existing.map { Int($0.timestamp.timeIntervalSince1970) })
        var inserted = 0
        for s in incoming {
            let key = Int(s.date.timeIntervalSince1970)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            context.insert(Measurement(kind: kind, value: s.value, unit: kind.unit, timestamp: s.date, source: .healthImport))
            inserted += 1
        }
        if let latest = samples.last?.startDate { setWatermark(kind.rawValue, latest) }
        return inserted
    }

    // MARK: Sleep

    private func importSleep(context: ModelContext) async throws -> Int {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return 0 }
        let cal = Calendar.current
        let anchor = watermark("sleep").map { cal.date(byAdding: .day, value: -1, to: $0) ?? $0 }
            ?? cal.date(byAdding: .day, value: -Self.firstRunWindowDays, to: Date())!
        let now = Date()
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: foreignWindow(from: anchor, to: now))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let own = Bundle.main.bundleIdentifier ?? ""
        let segments: [HealthImportPlanner.SleepSegment] = samples.compactMap { s in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: s.value),
                  let stage = HealthImportPlanner.stage(for: value) else { return nil }
            let cls = HealthImportPlanner.classify(sourceName: s.sourceRevision.source.name,
                                                   bundleIdentifier: s.sourceRevision.source.bundleIdentifier,
                                                   ownBundleIdentifier: own)
            return HealthImportPlanner.SleepSegment(start: s.startDate, end: s.endDate, stage: stage,
                                                    source: s.sourceRevision.source.name, sourceClass: cls)
        }
        let nights = HealthImportPlanner.nightsBySource(segments, importWatch: prefs.importFromWatch, calendar: cal)
        var persisted = 0
        for night in nights {
            for seg in night.segments {
                let minutes = HealthImportPlanner.minutes(of: seg)
                guard !minutes.isEmpty else { continue }
                SleepService.persistTimeline(start: seg.start, stages: minutes, context: context)
            }
            markImported(day: night.day, context: context)
            persisted += 1
        }
        if let latest = samples.last?.endDate { setWatermark("sleep", latest) }
        return persisted
    }

    /// Every session on that waking day is marked as imported so the exporter leaves it alone.
    private func markImported(day: Date, context: ModelContext) {
        let cal = Calendar.current
        let known = Self.importedSleepSessionIDs(context: context)
        let sessions = ((try? context.fetch(FetchDescriptor<SleepSession>())) ?? [])
            .filter { cal.isDate($0.date, inSameDayAs: day) && !known.contains($0.id) }
        for s in sessions {
            context.insert(DerivedUpdateRow(kind: Self.sleepMarkerKind, entityType: Self.sleepMarkerEntity, entityId: s.id.uuidString))
        }
    }

    static func importedSleepSessionIDs(context: ModelContext) -> Set<UUID> {
        let kind = sleepMarkerKind, entity = sleepMarkerEntity
        let rows = (try? context.fetch(FetchDescriptor<DerivedUpdateRow>(
            predicate: #Predicate { $0.kind == kind && $0.entityType == entity }
        ))) ?? []
        return Set(rows.compactMap { UUID(uuidString: $0.entityId) })
    }

    // MARK: Plumbing

    /// Samples in the window that PulseLoop did not write itself.
    private func foreignWindow(from: Date, to: Date) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: from, end: to, options: []),
            NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default())),
        ])
    }

    private func watermark(_ key: String) -> Date? {
        let t = defaults.double(forKey: "healthImport.watermark.\(key)")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func setWatermark(_ key: String, _ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: "healthImport.watermark.\(key)")
    }

    /// Forget the watermarks so the next run re-reads the full window (Settings > "Import now" after
    /// changing the Watch toggle, for instance).
    func resetWatermarks() {
        for key in ["hr", "spo2", "sleep"] { defaults.removeObject(forKey: "healthImport.watermark.\(key)") }
    }
}
