import AppKit

/// Two displays matching the app icon. The template follows the menu bar's
/// light or dark appearance, and the front screen fills in while streaming.
enum MenuBarGlyph {
    static func image(streaming: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let monitor = NSBezierPath(roundedRect: CGRect(x: 1.75, y: 5.75, width: 13.5, height: 8.5),
                                       xRadius: 2, yRadius: 2)
            monitor.lineWidth = 1.5
            monitor.stroke()
            NSBezierPath(roundedRect: CGRect(x: 7.75, y: 3.25, width: 1.5, height: 2.75),
                         xRadius: 0.75, yRadius: 0.75).fill()
            NSBezierPath(roundedRect: CGRect(x: 5.25, y: 2.75, width: 6.5, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()

            let tablet = CGRect(x: 12, y: 2.25, width: 10.25, height: 8)
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setBlendMode(.clear)
                let gap = tablet.insetBy(dx: -1.5, dy: -1.5)
                context.addPath(CGPath(roundedRect: gap, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
                context.restoreGState()
            }
            let outline = NSBezierPath(roundedRect: tablet, xRadius: 2, yRadius: 2)
            if streaming {
                outline.fill()
            } else {
                outline.lineWidth = 1.5
                outline.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = streaming ? "AutoSidecar Companion (streaming)" : "AutoSidecar Companion"
        return image
    }
}
