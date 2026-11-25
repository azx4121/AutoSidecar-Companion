import CoreGraphics
import XCTest
@testable import WiredDisplayHost

final class HostPanelTests: XCTestCase {
    func testNativeModeMatchesEveryPanelInBothOrientations() {
        let sizes: [(UInt32, UInt32)] = [
            (2048, 1536), (2160, 1620), (2266, 1488), (2360, 1640),
            (2388, 1668), (2420, 1668), (2732, 2048), (2752, 2064)
        ]
        for (long, short) in sizes {
            for (width, height) in [(long, short), (short, long)] {
                for scale in [1, 2] {
                    let modes = VirtualDisplayController.modeSizes(panelWidth: width, panelHeight: height,
                                                                      hiDPI: scale == 2)
                    XCTAssertEqual(modes.count, 3)
                    XCTAssertEqual(modes[.native], CGSize(width: Int(width) / scale, height: Int(height) / scale))
                    XCTAssertGreaterThan(modes[.more]!.width, modes[.native]!.width)
                    XCTAssertGreaterThan(modes[.most]!.width, modes[.more]!.width)
                }
            }
        }
    }

    func testOversizedAlternateModesDoNotInvalidateNativeMode() {
        let modes = VirtualDisplayController.modeSizes(panelWidth: 8192, panelHeight: 6144, hiDPI: true)
        XCTAssertEqual(modes, [.native: CGSize(width: 4096, height: 3072)])
    }
}
