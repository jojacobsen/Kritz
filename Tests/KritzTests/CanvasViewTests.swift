import XCTest
import AppKit
@testable import Kritz

/// Regression tests for the two crash / data-loss paths fixed for the "stable"
/// release: a stale selection index on delete, and the export pipeline crashing
/// (instead of failing gracefully) on a degenerate canvas size.
final class CanvasViewTests: XCTestCase {

    /// A real bitmap-backed image of the given size, so the canvas gets a valid pixelSize.
    private func solidImage(_ size: CGSize) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - #1: stale selectedIndex must not crash Delete

    func testDeleteWithStaleIndexDoesNotCrash() {
        let canvas = CanvasView(image: solidImage(CGSize(width: 100, height: 100)))
        canvas.currentTool = .select
        // Simulate the state after a crop/undo emptied the array while a selection
        // was still set — the exact precondition that used to crash on remove(at:).
        canvas.selectedIndex = 7
        XCTAssertTrue(canvas.annotations.isEmpty)

        canvas.deleteSelectedAnnotation()   // must be a no-op, not an out-of-bounds crash

        XCTAssertNil(canvas.selectedIndex)
        XCTAssertTrue(canvas.annotations.isEmpty)
    }

    // MARK: - #2 / #3: export must fail gracefully, never crash, so Save can report it

    func testExportOnValidCanvasSucceeds() {
        let canvas = CanvasView(image: solidImage(CGSize(width: 64, height: 48)))
        XCTAssertNotNil(canvas.exportImage())
        XCTAssertNotNil(canvas.exportPNGData())
        XCTAssertNotNil(canvas.exportJPEGData())
    }

    func testExportOnDegenerateCanvasReturnsNilInsteadOfCrashing() {
        // An empty NSImage has size .zero, so the canvas has no valid pixel size.
        let canvas = CanvasView(image: NSImage())
        XCTAssertNil(canvas.exportImage())
        // These feed the Save path; nil here is what lets Save surface an error
        // dialog instead of silently "succeeding" or crashing.
        XCTAssertNil(canvas.exportPNGData())
        XCTAssertNil(canvas.exportJPEGData())
    }
}
