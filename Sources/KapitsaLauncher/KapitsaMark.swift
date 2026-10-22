import AppKit
import SwiftUI

/// The Kapitsa Launcher mark: a round-bottomed flask of superfluid helium, whose surface
/// climbs the walls the way the film Kapitsa studied creeps up its container.
/// This file is the single source for the app icon, the sidebar mark and the menu bar symbol,
/// and is compiled into `Scripts/make-icon` as well as the app.
enum KapitsaMark {
    /// The mark's design space (y down), the same as the app icon's 1024-point canvas.
    static let conceptTile = CGRect(x: 100, y: 100, width: 824, height: 824)

    /// The flask's outline and the liquid inside, merged into one shape in concept space (y down).
    static let conceptPath: CGPath = {
        let centre = CGPoint(x: 512, y: 600)
        let radius: CGFloat = 250, neckHalfWidth: CGFloat = 70, neckTop: CGFloat = 210, wall: CGFloat = 56
        // Where the neck meets the bulb.
        let shoulder = (radius * radius - neckHalfWidth * neckHalfWidth).squareRoot()
        let left = CGPoint(x: centre.x - neckHalfWidth, y: centre.y - shoulder)
        let right = CGPoint(x: centre.x + neckHalfWidth, y: centre.y - shoulder)

        let glass = CGMutablePath()
        glass.move(to: CGPoint(x: left.x, y: neckTop))
        glass.addLine(to: left)
        // Angles grow clockwise on screen (y down), so decreasing them passes under the bulb.
        glass.addArc(center: centre, radius: radius,
                     startAngle: atan2(left.y - centre.y, left.x - centre.x),
                     endAngle: atan2(right.y - centre.y, right.x - centre.x), clockwise: true)
        glass.addLine(to: CGPoint(x: right.x, y: neckTop))
        glass.move(to: CGPoint(x: centre.x - 112, y: neckTop))   // the lip
        glass.addLine(to: CGPoint(x: centre.x + 112, y: neckTop))
        let outline = glass.copy(strokingWithWidth: wall, lineCap: .round, lineJoin: .round, miterLimit: 10)

        // The liquid fills the bulb, leaving a gap inside the glass. Its surface dips in the
        // middle and climbs both walls.
        let inner = radius - wall / 2 - 26
        let bulb = CGPath(ellipseIn: CGRect(x: centre.x - inner, y: centre.y - inner,
                                            width: inner * 2, height: inner * 2), transform: nil)
        let below = CGMutablePath()
        below.move(to: CGPoint(x: centre.x - inner - 10, y: centre.y - 175))
        below.addQuadCurve(to: CGPoint(x: centre.x + inner + 10, y: centre.y - 175),
                           control: CGPoint(x: centre.x, y: centre.y - 10))
        below.addLine(to: CGPoint(x: centre.x + inner + 10, y: centre.y + inner + 10))
        below.addLine(to: CGPoint(x: centre.x - inner - 10, y: centre.y + inner + 10))
        below.closeSubpath()
        return outline.union(bulb.intersection(below))
    }()

    /// The mark scaled to fit `rect` without distortion, centred (y down, as in SwiftUI).
    static func path(fitting rect: CGRect) -> CGPath {
        let bounds = conceptPath.boundingBoxOfPath
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return conceptPath.copy(using: &transform) ?? conceptPath
    }

    /// Menu bar symbol: a template image, so macOS tints it for light and dark menu bars.
    static func menuBarImage(pointSize: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path(fitting: rect.insetBy(dx: 0.5, dy: 0.5)))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kapitsa Launcher"
        return image
    }

    /// Draws the app icon (light tile) into a y-up bitmap context of `size` pixels.
    static func drawAppIcon(in context: CGContext, size: CGFloat) {
        let unit = size / 1024
        context.saveGState()
        context.scaleBy(x: unit, y: unit)
        let tileRect = conceptTile
        let tile = CGPath(roundedRect: tileRect, cornerWidth: 186, cornerHeight: 186, transform: nil)

        context.saveGState()   // soft shadow under the tile
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22,
                          color: CGColor(srgbRed: 0.05, green: 0.05, blue: 0.2, alpha: 0.2))
        context.addPath(tile)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()   // tile: white fading to a pale lavender-grey
        context.addPath(tile)
        context.clip()
        drawVerticalGradient(context, top: (1, 1, 1), bottom: (0.918, 0.925, 0.973), in: tileRect)
        context.restoreGState()

        // Mark: concept space (y down) flipped onto the y-up canvas.
        var transform = CGAffineTransform(translationX: 0, y: 1024).scaledBy(x: 1, y: -1)
        let mark = conceptPath.copy(using: &transform) ?? conceptPath
        context.saveGState()
        context.addPath(mark)
        context.clip()
        drawVerticalGradient(context, top: (0.400, 0.420, 0.875), bottom: (0.200, 0.200, 0.560),
                             in: mark.boundingBoxOfPath)
        context.restoreGState()
        context.restoreGState()
    }

    /// The app icon as an image, for runs outside a packaged .app.
    static func appIconImage(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawAppIcon(in: context, size: size)
            return true
        }
    }

    private static func drawVerticalGradient(_ context: CGContext, top: (CGFloat, CGFloat, CGFloat),
                                             bottom: (CGFloat, CGFloat, CGFloat), in rect: CGRect) {
        let colours = [CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1),
                       CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours,
                                        locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    }
}

/// The mark as a SwiftUI shape, for the sidebar and the menu bar window.
struct KapitsaMarkShape: Shape {
    func path(in rect: CGRect) -> Path { Path(KapitsaMark.path(fitting: rect)) }
}
