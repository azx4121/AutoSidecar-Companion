import XCTest
@testable import WDSession

final class HostVideoActivityTests: XCTestCase {
    func testBackgroundConnectionStartsOnlyWhenClientReturns() {
        var state = HostVideoActivity()
        XCTAssertEqual(state.receive(.clientActive(false), hasPipeline: false), .wait)
        XCTAssertEqual(state.receive(.sessionReady, hasPipeline: false), .pause)
        XCTAssertEqual(state.receive(.clientActive(true), hasPipeline: false), .start)
        XCTAssertEqual(state.receive(.clientActive(true), hasPipeline: true), .resendConfiguration)
    }

    func testForegroundConnectionCanPauseAndResume() {
        var state = HostVideoActivity()
        XCTAssertEqual(state.receive(.sessionReady, hasPipeline: false), .start)
        XCTAssertEqual(state.receive(.clientActive(false), hasPipeline: true), .pause)
        XCTAssertEqual(state.receive(.clientActive(true), hasPipeline: false), .start)
    }

    func testClientResumingDuringSetupStartsOnceReady() {
        var state = HostVideoActivity()
        XCTAssertEqual(state.receive(.clientActive(false), hasPipeline: false), .wait)
        XCTAssertEqual(state.receive(.clientActive(true), hasPipeline: false), .wait)
        XCTAssertEqual(state.receive(.sessionReady, hasPipeline: false), .start)
    }
}
