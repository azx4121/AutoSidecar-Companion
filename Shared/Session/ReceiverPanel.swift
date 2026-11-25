import Foundation

/// The display profile sent in the existing hello. Missing screen data delays negotiation.
public struct ReceiverPanel: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let scale: UInt8
    public let maxRefreshHz: UInt16
    public let supportsHDR10: Bool

    public init?(model: String, builtIn: Bool, nativeSize: CGSize, displayScale: CGFloat,
                 portrait: Bool, maximumFPS: Int, lowPower: Bool, hevc: Bool,
                 hdrPlayback: Bool, headroom: CGFloat) {
        guard builtIn,
              (1...16384).contains(nativeSize.width), (1...16384).contains(nativeSize.height),
              displayScale.isFinite, (1...4).contains(displayScale.rounded()),
              maximumFPS > 0 else { return nil }
        let correction = Self.zoomCorrection(for: model)
        let measured = correction ?? nativeSize
        let long = UInt32(max(measured.width, measured.height))
        let short = UInt32(min(measured.width, measured.height))
        width = portrait ? short : long
        height = portrait ? long : short
        scale = correction == nil ? UInt8(displayScale.rounded()) : 2
        maxRefreshHz = UInt16(min(maximumFPS, lowPower ? 60 : 120))
        supportsHDR10 = hevc && hdrPlayback && headroom.isFinite && headroom > 1
    }

    /// On these two variants Display Zoom was observed to report a scaled backing raster.
    public static func zoomCorrection(for model: String) -> CGSize? {
        guard model == "iPad14,5" || model == "iPad14,6" else { return nil }
        return CGSize(width: 2732, height: 2048)
    }
}
