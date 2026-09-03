import UIKit
import XCTest
@testable import PulseLoop

@MainActor
final class QuickActionRouterTests: XCTestCase {
    func testKnownShortcutIsQueuedOnceAndConsumed() {
        let router = QuickActionRouter()
        XCTAssertTrue(router.handle(UIApplicationShortcutItem(type: "com.pulseloop.sync", localizedTitle: "Sync ring")))
        XCTAssertEqual(router.pending, .sync)
        XCTAssertEqual(router.consume(), .sync)
        XCTAssertNil(router.consume(), "consuming clears the action")
    }

    func testUnknownShortcutIsRefused() {
        let router = QuickActionRouter()
        XCTAssertFalse(router.handle(UIApplicationShortcutItem(type: "com.pulseloop.nope", localizedTitle: "?")))
        XCTAssertNil(router.pending)
    }
}
