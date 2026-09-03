import HealthKit
import XCTest
@testable import PulseLoop

/// The pure half of the Compare-sources screen: 5-minute binning per source, the "sources agree" bins,
/// and minute-level sleep-stage agreement. The charts only draw what these return.
final class SourceComparisonTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_699_999_800)   // on a 5-minute boundary

    private func hr(_ offsetMin: Int, _ bpm: Double, _ source: String) -> SourcedHeartRate {
        SourcedHeartRate(date: t0.addingTimeInterval(TimeInterval(offsetMin * 60)), bpm: bpm, source: source)
    }

    func testBinsAverageWithinFiveMinutesPerSource() {
        let bins = SourceComparison.bins([hr(0, 60, "Watch"), hr(2, 70, "Watch"), hr(1, 80, "Ring"), hr(7, 90, "Ring")])
        XCTAssertEqual(bins.count, 2)
        XCTAssertEqual(bins[0].values["Watch"], 65)
        XCTAssertEqual(bins[0].values["Ring"], 80)
        XCTAssertEqual(bins[1].values, ["Ring": 90])
    }

    func testAgreementNeedsTwoSourcesWithinTolerance() {
        let bins = SourceComparison.bins([
            hr(0, 60, "Watch"), hr(1, 63, "Ring"),     // agree
            hr(5, 60, "Watch"), hr(6, 75, "Ring"),     // differ
            hr(10, 70, "Watch"),                       // single source
        ])
        let agree = SourceComparison.agreements(bins)
        XCTAssertEqual(agree.count, 1)
        XCTAssertEqual(agree[0].date, t0)
        XCTAssertEqual(agree[0].bpm, 61.5)
    }

    private func seg(_ s: Int, _ e: Int, _ v: HKCategoryValueSleepAnalysis, _ src: String) -> SourcedSleep {
        SourcedSleep(start: t0.addingTimeInterval(TimeInterval(s * 60)),
                     end: t0.addingTimeInterval(TimeInterval(e * 60)), value: v, source: src)
    }

    func testSleepAgreementBlocksWhereStagesMatch() {
        let segs = [
            seg(0, 30, .asleepDeep, "Watch"), seg(30, 60, .asleepCore, "Watch"),
            seg(0, 20, .asleepDeep, "Ring"), seg(20, 60, .asleepCore, "Ring"),
            seg(0, 60, .inBed, "Ring"),
        ]
        let blocks = SourceComparison.sleepAgreement(segs, from: t0, to: t0.addingTimeInterval(3600))
        XCTAssertEqual(blocks.map(\.value), [.asleepDeep, .asleepCore])
        XCTAssertEqual(blocks[0].end, t0.addingTimeInterval(20 * 60))
        XCTAssertEqual(blocks[1].start, t0.addingTimeInterval(30 * 60))
        XCTAssertEqual(blocks[1].end, t0.addingTimeInterval(60 * 60))
    }

    func testSingleSourceHasNoSleepAgreement() {
        XCTAssertTrue(SourceComparison.sleepAgreement([seg(0, 60, .asleepDeep, "Ring")], from: t0, to: t0.addingTimeInterval(3600)).isEmpty)
    }

    func testWatchSortsFirst() {
        let ordered = SourceComparison.orderedSources(["PulseLoop", "Arne’s Apple Watch", "LuckierRing"])
        XCTAssertEqual(ordered, ["Arne’s Apple Watch", "LuckierRing", "PulseLoop"])
    }
}
