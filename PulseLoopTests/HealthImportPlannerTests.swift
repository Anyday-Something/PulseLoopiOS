import HealthKit
import XCTest
@testable import PulseLoop

/// The pure half of the Apple Health import: source classes, one-source-per-night, stage mapping, and
/// the Watch heart-rate thinning.
final class HealthImportPlannerTests: XCTestCase {
    private let own = "com.example.pulseloop"
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13 UTC

    private func cls(_ name: String, _ bundle: String) -> HealthImportPlanner.SourceClass {
        HealthImportPlanner.classify(sourceName: name, bundleIdentifier: bundle, ownBundleIdentifier: own)
    }

    func testSourceClasses() {
        XCTAssertEqual(cls("PulseLoop", own), .own)
        XCTAssertEqual(cls("Arne’s Apple Watch", "com.apple.health.ABC"), .watch)
        XCTAssertEqual(cls("LuckierRing", "com.anydaysomething.luckierring"), .other)
        XCTAssertFalse(HealthImportPlanner.isImported(.own, importWatch: true))
        XCTAssertFalse(HealthImportPlanner.isImported(.watch, importWatch: false))
        XCTAssertTrue(HealthImportPlanner.isImported(.watch, importWatch: true))
        XCTAssertTrue(HealthImportPlanner.isImported(.other, importWatch: false))
    }

    func testStageMapping() {
        XCTAssertEqual(HealthImportPlanner.stage(for: .asleepCore), .light)
        XCTAssertEqual(HealthImportPlanner.stage(for: .asleepDeep), .deep)
        XCTAssertEqual(HealthImportPlanner.stage(for: .asleepREM), .rem)
        XCTAssertEqual(HealthImportPlanner.stage(for: .awake), .awake)
        XCTAssertNil(HealthImportPlanner.stage(for: .inBed))
    }

    private func seg(_ startMin: Int, _ endMin: Int, _ stage: SleepStage, _ source: String,
                     _ cls: HealthImportPlanner.SourceClass) -> HealthImportPlanner.SleepSegment {
        HealthImportPlanner.SleepSegment(start: t0.addingTimeInterval(TimeInterval(startMin * 60)),
                                         end: t0.addingTimeInterval(TimeInterval(endMin * 60)),
                                         stage: stage, source: source, sourceClass: cls)
    }

    func testRingAppBeatsWatchForTheSameNightAndWatchNeedsItsToggle() {
        let segments = [
            seg(0, 400, .light, "Watch", .watch),
            seg(0, 100, .deep, "LuckierRing", .other),
            seg(0, 50, .light, "PulseLoop", .own),
        ]
        let nights = HealthImportPlanner.nightsBySource(segments, importWatch: true)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].source, "LuckierRing", "a ring app wins over the Watch even with fewer minutes")

        let watchOnly = HealthImportPlanner.nightsBySource([seg(0, 400, .light, "Watch", .watch)], importWatch: false)
        XCTAssertTrue(watchOnly.isEmpty, "the Watch is imported only with its toggle")
        XCTAssertEqual(HealthImportPlanner.nightsBySource([seg(0, 400, .light, "Watch", .watch)], importWatch: true).count, 1)
    }

    func testMinutesExpandASegment() {
        XCTAssertEqual(HealthImportPlanner.minutes(of: seg(0, 3, .deep, "R", .other)), [.deep, .deep, .deep])
    }

    func testWatchHeartRateIsThinnedToOnePerMinute() {
        let dense: [(date: Date, value: Double)] = [(t0, 60), (t0.addingTimeInterval(5), 70), (t0.addingTimeInterval(65), 90)]
        let thin = HealthImportPlanner.thinnedPerMinute(dense)
        XCTAssertEqual(thin.count, 2)
        XCTAssertEqual(thin[0].value, 65)
        XCTAssertEqual(thin[1].value, 90)
    }
}
