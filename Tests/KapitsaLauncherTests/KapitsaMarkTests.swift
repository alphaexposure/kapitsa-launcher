import AppKit
import XCTest
@testable import KapitsaLauncher

final class KapitsaMarkTests: XCTestCase {
    func testMarkFitsInsideTheIconTile() {
        let bounds = KapitsaMark.conceptPath.boundingBoxOfPath
        XCTAssertFalse(bounds.isEmpty)
        XCTAssertTrue(KapitsaMark.conceptTile.contains(bounds))
    }

    func testPathFitsRequestedRect() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let bounds = KapitsaMark.path(fitting: rect).boundingBoxOfPath
        XCTAssertLessThanOrEqual(bounds.width, 24.001)
        XCTAssertLessThanOrEqual(bounds.height, 24.001)
        XCTAssertGreaterThan(max(bounds.width, bounds.height), 23.9)
    }

    func testMenuBarImageIsATemplate() {
        let image = KapitsaMark.menuBarImage()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
    }

    func testAppIconDrawsOpaqueCentre() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        KapitsaMark.drawAppIcon(in: context.cgContext, size: 64)
        context.flushGraphics()
        XCTAssertEqual(bitmap.colorAt(x: 32, y: 32)?.alphaComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01)
    }
}
