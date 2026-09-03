import Foundation
import HealthKit

/// A heart-rate sample as Apple Health holds it, tagged with the app or device that wrote it.
struct SourcedHeartRate: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let bpm: Double
    let source: String
}

struct SourcedSpO2: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let percent: Double
    let source: String
}

struct SourcedSleep: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let value: HKCategoryValueSleepAnalysis
    let source: String

    var minutes: Double { end.timeIntervalSince(start) / 60 }

    var stageLabel: String {
        switch value {
        case .inBed: return "In bed"
        case .awake: return "Awake"
        case .asleepCore: return "Core"
        case .asleepDeep: return "Deep"
        case .asleepREM: return "REM"
        case .asleepUnspecified: return "Asleep"
        @unknown default: return "Other"
        }
    }

    var isAsleep: Bool {
        switch value {
        case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified: return true
        default: return false
        }
    }
}

/// Reads Apple Health across **every** source — the Apple Watch, PulseLoop's own export, any other
/// ring app — with each sample tagged by its source name, so one day can be compared source against
/// source. Read-only; never writes.
///
/// Read access rides on the existing `HealthSyncService.requestAuthorization()` prompt (its `readTypes`
/// already cover the share types). HealthKit hides read-denial by design: a denied type simply returns
/// only what this app wrote itself.
final class HealthSourceReader: @unchecked Sendable {
    private let store = HKHealthStore()

    func heartRate(from: Date, to: Date) async throws -> [SourcedHeartRate] {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: Self.window(from, to))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store).map {
            SourcedHeartRate(date: $0.startDate, bpm: $0.quantity.doubleValue(for: unit), source: $0.sourceRevision.source.name)
        }
    }

    func spo2(from: Date, to: Date) async throws -> [SourcedSpO2] {
        guard let type = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) else { return [] }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: Self.window(from, to))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store).map {
            SourcedSpO2(date: $0.startDate, percent: $0.quantity.doubleValue(for: .percent()) * 100, source: $0.sourceRevision.source.name)
        }
    }

    func sleep(from: Date, to: Date) async throws -> [SourcedSleep] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: Self.window(from, to))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store).compactMap {
            guard let value = HKCategoryValueSleepAnalysis(rawValue: $0.value) else { return nil }
            return SourcedSleep(start: $0.startDate, end: $0.endDate, value: value, source: $0.sourceRevision.source.name)
        }
    }

    private static func window(_ from: Date, _ to: Date) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    }
}
