import XCTest
import WDSession

final class ReceiverPanelTests: XCTestCase {
    private func profile(_ size: CGSize, model: String = "", builtIn: Bool = true,
                         portrait: Bool = false, refresh: Int = 60, lowPower: Bool = false,
                         hevc: Bool = true, hdr: Bool = false, edr: CGFloat = 1) -> ReceiverPanel? {
        ReceiverPanel(model: model, builtIn: builtIn, nativeSize: size, displayScale: 2,
                      portrait: portrait, maximumFPS: refresh, lowPower: lowPower, hevc: hevc,
                      hdrPlayback: hdr, headroom: edr)
    }

    func testReportedRasterAndRateForDifferentPanels() throws {
        for (width, height, hz) in [(2266, 1488, 60), (2360, 1640, 60), (2388, 1668, 120), (2752, 2064, 120)] {
            let native = CGSize(width: Double(height), height: Double(width))
            let panel = try XCTUnwrap(profile(native, refresh: hz))
            XCTAssertEqual(panel.width, UInt32(width))
            XCTAssertEqual(panel.height, UInt32(height))
            XCTAssertEqual(panel.scale, 2)
            XCTAssertEqual(panel.maxRefreshHz, UInt16(hz))
            let rotated = try XCTUnwrap(profile(native, portrait: true, refresh: hz))
            XCTAssertEqual(rotated.width, UInt32(height))
            XCTAssertEqual(rotated.height, UInt32(width))
        }
    }

    func testZoomOverrideOnlyForMeasuredModel() throws {
        let scaled = CGSize(width: 1590, height: 2226)
        for model in ["iPad14,5", "iPad14,6"] {
            let panel = try XCTUnwrap(profile(scaled, model: model))
            XCTAssertEqual(panel.width, 2732)
            XCTAssertEqual(panel.height, 2048)
        }
        XCTAssertEqual(profile(scaled)?.width, 2226)
    }

    func testUnavailableAndExternalScreens() {
        XCTAssertNil(profile(CGSize(width: 0, height: 0), model: "iPad14,5"))
        XCTAssertNil(profile(CGSize(width: 1000, height: 800), refresh: 0))
        XCTAssertNil(profile(CGSize(width: 3840, height: 2160), model: "iPad14,5", builtIn: false))
    }

    func testHDRCapabilitiesAndLowPowerAreIndependent() throws {
        let size = CGSize(width: 2388, height: 1668)
        XCTAssertFalse(try XCTUnwrap(profile(size, refresh: 120)).supportsHDR10)
        XCTAssertFalse(try XCTUnwrap(profile(size, hevc: false, hdr: true, edr: 2)).supportsHDR10)
        XCTAssertFalse(try XCTUnwrap(profile(size, hdr: false, edr: 2)).supportsHDR10)
        XCTAssertFalse(try XCTUnwrap(profile(size, hdr: true, edr: 1)).supportsHDR10)
        let constrained = try XCTUnwrap(profile(size, refresh: 120, lowPower: true, hdr: true, edr: 2))
        XCTAssertTrue(constrained.supportsHDR10)
        XCTAssertEqual(constrained.maxRefreshHz, 60)
        XCTAssertEqual(profile(size, refresh: 48, lowPower: true)?.maxRefreshHz, 48)
    }
}
