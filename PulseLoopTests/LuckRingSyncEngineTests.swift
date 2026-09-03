import XCTest
@testable import PulseLoop

/// The K6 startup: the bind bundle and the auto-monitoring config go out at once, the REQUESTs (device
/// info, battery, settings sync) and the history pager only after the settle window, and a dropped link
/// cancels what is still pending.
@MainActor
final class LuckRingSyncEngineTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
        /// dataType of every *head* packet written, in order (continuation pages are skipped).
        var headTypes: [UInt8] { sent.map { [UInt8]($0) }.filter { $0[0] == 0 }.map { $0[5] } }
    }

    private func makeEngine(writer: FakeWriter, settle: TimeInterval) -> LuckRingSyncEngine {
        let pager = LuckRingHistorySync(writer: writer, settleSeconds: 5, stallSeconds: 5, progressSink: { _ in })
        return LuckRingSyncEngine(writer: writer, historySync: pager, startupSettleSeconds: settle)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testRequestsWaitForTheSettleWindow() async {
        let writer = FakeWriter()
        let engine = makeEngine(writer: writer, settle: 0.05)
        engine.runStartup()
        XCTAssertEqual(writer.headTypes, [110, 128], "only the bind bundle and the monitoring config go out at once")

        await sleep(0.25)
        XCTAssertEqual(writer.headTypes, [110, 128, 2, 3, 9, 5], "then device info, battery, settings sync and the first history type")
        engine.connectionDidEnd()
    }

    func testDroppedLinkCancelsPendingRequests() async {
        let writer = FakeWriter()
        let engine = makeEngine(writer: writer, settle: 0.05)
        engine.runStartup()
        engine.connectionDidEnd()

        await sleep(0.25)
        XCTAssertEqual(writer.headTypes, [110, 128], "nothing deferred may fire into a dead link")
    }
}
