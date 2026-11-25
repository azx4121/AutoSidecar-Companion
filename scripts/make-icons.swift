// Renders the Companion artwork for the iPad home screen and the Mac app.
// Run scripts/make-icons.sh to update both sets of assets.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(rgb >> 16 & 0xff) / 255,
            green: CGFloat(rgb >> 8 & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ context: CGContext, _ path: CGPath, _ color: CGColor) {
    context.setFillColor(color)
    context.addPath(path)
    context.fillPath()
}

func gradient(_ context: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawScreen(_ context: CGContext, in frame: CGRect, corner: CGFloat, rim: CGFloat,
                bezel: CGColor, colors: [CGColor]) {
    fill(context, rounded(frame, radius: corner), bezel)
    let glass = frame.insetBy(dx: rim, dy: rim)
    context.saveGState()
    context.addPath(rounded(glass, radius: corner - rim / 2))
    context.clip()
    gradient(context, colors,
             from: CGPoint(x: glass.minX, y: glass.minY),
             to: CGPoint(x: glass.maxX, y: glass.maxY))
    let reflection = CGMutablePath()
    reflection.move(to: CGPoint(x: glass.minX, y: glass.minY + glass.height * 0.44))
    reflection.addLine(to: CGPoint(x: glass.midX, y: glass.maxY))
    reflection.addLine(to: CGPoint(x: glass.maxX, y: glass.maxY))
    reflection.addLine(to: CGPoint(x: glass.maxX, y: glass.minY + glass.height * 0.55))
    reflection.closeSubpath()
    fill(context, reflection, color(0xf6f9ff, alpha: 0.16))
    context.restoreGState()
}

func drawArtwork(_ context: CGContext, compact: Bool) {
    gradient(context, [color(0x111a49), color(0x303990), color(0x5640a3)],
             from: CGPoint(x: 160, y: 50), to: CGPoint(x: 830, y: 990))

    // The USB-C line joins the bottoms of the displays, behind their frames.
    let cable = CGMutablePath()
    cable.move(to: CGPoint(x: 481, y: 469))
    cable.addCurve(to: CGPoint(x: 571, y: 276), control1: CGPoint(x: 481, y: 339),
                   control2: CGPoint(x: 496, y: 276))
    cable.addLine(to: CGPoint(x: 664, y: 276))
    cable.addQuadCurve(to: CGPoint(x: 748, y: 388), control: CGPoint(x: 748, y: 276))
    context.setStrokeColor(color(0x7eecff))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(compact ? 58 : 44)
    context.addPath(cable)
    context.strokePath()

    let pale = color(0xf4f6ff)
    fill(context, rounded(CGRect(x: 337, y: 418, width: 58, height: 85), radius: 20), pale)
    fill(context, rounded(CGRect(x: 260, y: 387, width: 212, height: 42), radius: 21), pale)
    drawScreen(context, in: CGRect(x: 118, y: 460, width: 550, height: 332), corner: 64,
               rim: compact ? 52 : 38, bezel: pale, colors: [color(0x2649be), color(0x8a9dff)])

    // A narrow shadow separates the overlapping bezels at small sizes.
    let tablet = CGRect(x: 535, y: 358, width: 375, height: 293)
    fill(context, rounded(tablet.insetBy(dx: -15, dy: -15), radius: 73), color(0x101745))
    drawScreen(context, in: tablet, corner: 58, rim: compact ? 48 : 34,
               bezel: color(0xc5f8ff), colors: [color(0x1762ad), color(0x65c7fc)])
}

func png(size: Int, opaque: Bool, draw: (CGContext) -> Void) -> Data {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace, bitmapInfo: alpha.rawValue)!
    let scale = CGFloat(size) / canvas.width
    context.scaleBy(x: scale, y: scale)
    draw(context)
    let data = NSMutableData()
    let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(encoder), "Could not encode the app icon")
    return data as Data
}

let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
// iPadOS applies its own corner mask to the square, opaque icon.
try png(size: 1024, opaque: true) { drawArtwork($0, compact: false) }
    .write(to: output.appendingPathComponent("AppIcon-iPad-1024.png"))

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let name = "icon_\(base)x\(base)\(scale == 1 ? "" : "@2x").png"
        let artwork = png(size: size, opaque: false) { context in
            let tile = canvas.insetBy(dx: 100, dy: 100)
            let shape = rounded(tile, radius: 185)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0, alpha: 0.32))
            fill(context, shape, color(0x111a49))
            context.restoreGState()
            context.addPath(shape)
            context.clip()
            context.translateBy(x: tile.minX, y: tile.minY)
            context.scaleBy(x: tile.width / canvas.width, y: tile.height / canvas.height)
            drawArtwork(context, compact: size <= 32)
        }
        try artwork.write(to: iconset.appendingPathComponent(name))
    }
}

let menuPreview = png(size: 1024, opaque: true) { context in
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSColor(white: 0.94, alpha: 1).setFill()
    canvas.fill()
    for (index, streaming) in [false, true].enumerated() {
        MenuBarGlyph.image(streaming: streaming).draw(
            in: CGRect(x: 95 + CGFloat(index) * 452, y: 384, width: 24 * 16, height: 16 * 16)
        )
    }
    NSGraphicsContext.restoreGraphicsState()
}
try menuPreview.write(to: output.appendingPathComponent("MenuBar-preview.png"))
