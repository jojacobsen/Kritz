import AppKit

/// The available annotation tools. Raw values map to toolbar button tags.
enum Tool: Int {
    case arrow = 0
    case text = 1
    case rect = 2
    case ellipse = 3
    case highlighter = 4
    case pixelate = 5
    case crop = 6
    case ruler = 7
    case spotlight = 8
    case counter = 9
    case select = 10
    /// Not a palette tool – a pasted image element.
    case image = 11
}

/// A single annotation drawn on top of the screenshot.
/// Coordinates are stored in the canvas' pixel space (same space used for export),
/// so what you see is exactly what gets saved – no scaling math at export time.
struct Annotation {
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 24
    /// Freehand points, used by the highlighter tool.
    var points: [CGPoint] = []
    /// Badge number, used by the counter tool.
    var number: Int = 0
    /// Bitmap payload, used by pasted image elements.
    var image: NSImage?

    /// A copy translated by `delta` – used when the canvas grows and existing content shifts.
    func shifted(by delta: CGPoint) -> Annotation {
        var copy = self
        copy.start = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
        copy.end = CGPoint(x: end.x + delta.x, y: end.y + delta.y)
        copy.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return copy
    }
}

extension NSRect {
    /// Build a normalised rect from two arbitrary corner points.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x),
                  y: min(a.y, b.y),
                  width: abs(a.x - b.x),
                  height: abs(a.y - b.y))
    }

    /// Area in square points; `.null`/empty rects count as zero.
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
