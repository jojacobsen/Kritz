import AppKit
import CoreImage

/// The drawing surface: shows the screenshot and lets the user add annotations on top.
///
/// Coordinate space ("content space"): bottom-left origin, 1 unit = 1 output pixel. Mouse
/// input, drawing and export all share it, so "what you see is what you save".
///
/// The screenshot is drawn at `imageOrigin` with size `imagePixelSize` inside a white canvas
/// of size `pixelSize`. Drawing past the edge grows the canvas (white fill), nothing is clipped.
final class CanvasView: NSView {

    private var image: NSImage
    private var imagePixelSize: CGSize
    private var imageOrigin: CGPoint = .zero
    /// Full canvas (= export) size. The view bounds match this 1:1.
    private(set) var pixelSize: CGSize

    private(set) var annotations: [Annotation] = []
    private var draft: Annotation?

    var currentTool: Tool = .arrow
    var currentColor: NSColor = .systemRed
    var currentLineWidth: CGFloat = 4

    /// Called after the canvas dimensions change (crop or auto-grow), so the window re-fits.
    var onCanvasResized: (() -> Void)?
    /// Called when crop-pending mode starts (true) or ends (false).
    var onCropStateChanged: ((Bool) -> Void)?
    /// Called when the canvas changes the active tool itself (e.g. after paste).
    var onToolChanged: (() -> Void)?

    // Selection / move / resize (used by the Select tool)
    private enum DragKind { case move, point(isStart: Bool), corner(Corner) }
    private enum Corner { case bl, br, tl, tr }
    private var selectedIndex: Int?
    private var activeDrag: DragKind?
    private var dragStartMouse: CGPoint = .zero
    private var dragStartAnnotation: Annotation?
    private var dragPushedUndo = false

    private weak var activeTextField: NSTextField?
    private var cachedPixelated: CGImage?

    // Undo: full snapshots. The image is a shared reference, so these are cheap.
    private struct CanvasState {
        let image: NSImage
        let imagePixelSize: CGSize
        let imageOrigin: CGPoint
        let pixelSize: CGSize
        let annotations: [Annotation]
    }
    private var undoStack: [CanvasState] = []
    private var redoStack: [CanvasState] = []

    // Crop-pending state
    private enum CropHandle { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside }
    private var cropRect: CGRect?
    private var cropDrawing = false
    private var cropDragHandle: CropHandle?
    private var cropDragStart: CGPoint = .zero
    private var cropRectAtDragStart: CGRect = .zero

    // MARK: - Init

    init(image: NSImage) {
        self.image = image
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            imagePixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            imagePixelSize = image.size
        }
        pixelSize = imagePixelSize
        super.init(frame: NSRect(origin: .zero, size: pixelSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { pixelSize }
    override var acceptsFirstResponder: Bool { true }

    var isCropping: Bool { cropRect != nil }
    private var contentBounds: CGRect { CGRect(origin: .zero, size: pixelSize) }
    private var viewScale: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(rect: bounds).fill()
        image.draw(in: CGRect(origin: imageOrigin, size: imagePixelSize))
        for annotation in annotations { drawAnnotation(annotation) }
        if let draft { drawAnnotation(draft) }
        if let cropRect { drawCrop(cropRect) }
        drawSelection()
    }

    private func drawAnnotation(_ a: Annotation) {
        a.color.setStroke()
        a.color.setFill()
        switch a.tool {
        case .rect:
            let path = NSBezierPath(rect: NSRect(from: a.start, to: a.end))
            path.lineWidth = a.lineWidth
            path.lineJoinStyle = .round
            path.stroke()
        case .ellipse:
            let path = NSBezierPath(ovalIn: NSRect(from: a.start, to: a.end))
            path.lineWidth = a.lineWidth
            path.stroke()
        case .arrow:
            drawArrow(from: a.start, to: a.end, lineWidth: a.lineWidth)
        case .text:
            drawText(a)
        case .highlighter:
            drawHighlighter(a)
        case .pixelate:
            drawPixelate(NSRect(from: a.start, to: a.end))
        case .ruler:
            drawRuler(a)
        case .spotlight:
            drawSpotlight(NSRect(from: a.start, to: a.end))
        case .counter:
            drawCounter(a)
        case .image:
            a.image?.draw(in: NSRect(from: a.start, to: a.end))
        case .crop, .select:
            break // not stored as drawable annotations
        }
    }

    private func counterRadius(_ a: Annotation) -> CGFloat { max(13, a.lineWidth * 3) }

    private func drawCounter(_ a: Annotation) {
        let r = counterRadius(a)
        let rect = CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r)
        a.color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let label = "\(a.number)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let ts = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: a.start.x - ts.width / 2, y: a.start.y - ts.height / 2),
                                 withAttributes: attrs)
    }

    private func drawRuler(_ a: Annotation) {
        a.color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = max(1.5, a.lineWidth * 0.6)
        path.move(to: a.start)
        path.line(to: a.end)
        let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
        let perp = angle + .pi / 2
        let tick: CGFloat = 8
        for pt in [a.start, a.end] {
            path.move(to: CGPoint(x: pt.x + cos(perp) * tick, y: pt.y + sin(perp) * tick))
            path.line(to: CGPoint(x: pt.x - cos(perp) * tick, y: pt.y - sin(perp) * tick))
        }
        path.stroke()
        let dist = Int(hypot(a.end.x - a.start.x, a.end.y - a.start.y).rounded())
        drawPill("\(dist) px", at: CGPoint(x: (a.start.x + a.end.x) / 2, y: (a.start.y + a.end.y) / 2))
    }

    private func drawSpotlight(_ rect: CGRect) {
        NSColor(white: 0, alpha: 0.5).setFill()
        let path = NSBezierPath(rect: bounds)
        if rect.width > 0, rect.height > 0 {
            path.append(NSBezierPath(rect: rect).reversed)
            path.windingRule = .evenOdd
        }
        path.fill()
    }

    private func drawPill(_ text: String, at center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let ts = (text as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: center.x - ts.width / 2 - 6, y: center.y - ts.height / 2 - 3,
                          width: ts.width + 12, height: ts.height + 6)
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attrs)
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(14, lineWidth * 3.4)
        let shaftEnd = CGPoint(x: end.x - cos(angle) * headLength * 0.6,
                               y: end.y - sin(angle) * headLength * 0.6)
        let shaft = NSBezierPath()
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.move(to: start)
        shaft.line(to: shaftEnd)
        shaft.stroke()

        let left = CGPoint(x: end.x - cos(angle - .pi / 7) * headLength,
                           y: end.y - sin(angle - .pi / 7) * headLength)
        let right = CGPoint(x: end.x - cos(angle + .pi / 7) * headLength,
                            y: end.y - sin(angle + .pi / 7) * headLength)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: left)
        head.line(to: right)
        head.close()
        head.fill()
    }

    private func drawText(_ a: Annotation) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: a.fontSize),
            .foregroundColor: a.color
        ]
        (a.text as NSString).draw(at: a.start, withAttributes: attrs)
    }

    private func drawHighlighter(_ a: Annotation) {
        guard let first = a.points.first else { return }
        let path = NSBezierPath()
        path.lineWidth = max(14, a.lineWidth * 4)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        for point in a.points.dropFirst() { path.line(to: point) }
        a.color.withAlphaComponent(0.35).setStroke()
        path.stroke()
    }

    private func drawPixelate(_ rect: NSRect) {
        guard rect.width > 1, rect.height > 1, let pixelated = pixelatedImage() else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSImage(cgImage: pixelated, size: imagePixelSize)
            .draw(in: CGRect(origin: imageOrigin, size: imagePixelSize))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCrop(_ rect: CGRect) {
        NSColor(white: 0, alpha: 0.5).setFill()
        let dim = NSBezierPath(rect: bounds)
        if rect.width > 0, rect.height > 0 {
            dim.append(NSBezierPath(rect: rect).reversed)
            dim.windingRule = .evenOdd
        }
        dim.fill()
        guard rect.width > 0, rect.height > 0 else { return }

        let stroke = 1.5 / viewScale
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = stroke
        border.stroke()

        // Rule-of-thirds guides
        NSColor(white: 1, alpha: 0.4).setStroke()
        let thirds = NSBezierPath()
        thirds.lineWidth = stroke / 2
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            thirds.move(to: CGPoint(x: x, y: rect.minY)); thirds.line(to: CGPoint(x: x, y: rect.maxY))
            thirds.move(to: CGPoint(x: rect.minX, y: y)); thirds.line(to: CGPoint(x: rect.maxX, y: y))
        }
        thirds.stroke()

        // Handles
        let hs = 9 / viewScale
        for point in handlePoints(rect) {
            let hr = CGRect(x: point.x - hs / 2, y: point.y - hs / 2, width: hs, height: hs)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: hr, xRadius: hs / 4, yRadius: hs / 4).fill()
            NSColor.controlAccentColor.setStroke()
            let hp = NSBezierPath(roundedRect: hr, xRadius: hs / 4, yRadius: hs / 4)
            hp.lineWidth = 1 / viewScale
            hp.stroke()
        }

        // Dimensions
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 / viewScale, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let pill = NSRect(x: rect.midX - textSize.width / 2 - 8 / viewScale,
                          y: min(rect.maxY + 6 / viewScale, bounds.height - textSize.height - 6 / viewScale),
                          width: textSize.width + 16 / viewScale, height: textSize.height + 6 / viewScale)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5 / viewScale, yRadius: 5 / viewScale).fill()
        (label as NSString).draw(at: NSPoint(x: pill.minX + 8 / viewScale, y: pill.minY + 3 / viewScale), withAttributes: attrs)
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
         CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.midY)]
    }

    // MARK: - Pixelation cache

    private var baseCGImage: CGImage? {
        var rect = NSRect(origin: .zero, size: imagePixelSize)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func pixelatedImage() -> CGImage? {
        if let cachedPixelated { return cachedPixelated }
        guard let cg = baseCGImage else { return nil }
        let ciImage = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIPixellate",
                                    parameters: [kCIInputImageKey: ciImage, kCIInputScaleKey: 18.0]),
              let output = filter.outputImage else { return nil }
        cachedPixelated = CIContext().createCGImage(output, from: ciImage.extent)
        return cachedPixelated
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch currentTool {
        case .text: beginTextEditing(at: p); return
        case .crop: cropMouseDown(p); return
        case .counter: placeCounter(p); return
        case .select: selectMouseDown(p); return
        default: break
        }
        commitTextEditing()
        selectedIndex = nil
        var a = Annotation(tool: currentTool, start: p, end: p, color: currentColor, lineWidth: currentLineWidth)
        if currentTool == .highlighter { a.points = [p] }
        draft = a
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if currentTool == .crop { cropMouseDragged(p); return }
        if currentTool == .select { selectMouseDragged(p); return }
        guard draft != nil else { return }
        if draft?.tool == .highlighter { draft?.points.append(p) } else { draft?.end = p }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if currentTool == .crop { cropMouseUp(p); return }
        if currentTool == .select { selectMouseUp(p); return }
        guard var finished = draft else { return }
        draft = nil

        switch finished.tool {
        case .highlighter:
            finished.points.append(p)
            if finished.points.count > 1 { commit(finished) }
        default:
            finished.end = p
            if hypot(p.x - finished.start.x, p.y - finished.start.y) > 2 { commit(finished) }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if cropRect != nil {
            switch event.keyCode {
            case 36, 76: applyCrop(); return   // Return / keypad Enter
            case 53: cancelCrop(); return      // Esc
            default: break
            }
        }
        // Delete / Backspace removes the selected element.
        if currentTool == .select, let idx = selectedIndex,
           event.keyCode == 51 || event.keyCode == 117 {
            pushUndo()
            annotations.remove(at: idx)
            selectedIndex = nil
            needsDisplay = true
            return
        }
        if event.keyCode == 53 { selectedIndex = nil; needsDisplay = true } // Esc deselects
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        let cursor: NSCursor = (currentTool == .crop) ? .crosshair : .arrow
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Commit + auto-grow

    private func commit(_ annotation: Annotation) {
        pushUndo()
        let shift = expandCanvas(toInclude: boundingRect(of: annotation))
        annotations.append(annotation.shifted(by: shift))
    }

    private func placeCounter(_ p: CGPoint) {
        commitTextEditing()
        var a = Annotation(tool: .counter, start: p, end: p, color: currentColor, lineWidth: currentLineWidth)
        a.number = (annotations.filter { $0.tool == .counter }.map { $0.number }.max() ?? 0) + 1
        commit(a)
        needsDisplay = true
    }

    private func boundingRect(of a: Annotation) -> CGRect {
        switch a.tool {
        case .highlighter:
            let base = pointsBounds(a.points)
            let pad = max(14, a.lineWidth * 4) / 2
            return base.insetBy(dx: -pad, dy: -pad)
        case .text:
            let size = (a.text as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: a.fontSize)])
            return CGRect(origin: a.start, size: size)
        case .counter:
            let r = counterRadius(a)
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r)
        case .ruler:
            return NSRect(from: a.start, to: a.end).insetBy(dx: -12, dy: -12)
        default:
            return NSRect(from: a.start, to: a.end).insetBy(dx: -a.lineWidth, dy: -a.lineWidth)
        }
    }

    private func pointsBounds(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Grows the canvas (white fill) so `rect` fits, shifting existing content if needed.
    /// Returns the shift to apply to the new annotation.
    @discardableResult
    private func expandCanvas(toInclude rect: CGRect) -> CGPoint {
        if contentBounds.contains(rect) { return .zero }
        let minX = min(0, rect.minX)
        let minY = min(0, rect.minY)
        let maxX = max(pixelSize.width, rect.maxX)
        let maxY = max(pixelSize.height, rect.maxY)
        let shift = CGPoint(x: -minX, y: -minY)
        if shift != .zero {
            imageOrigin = CGPoint(x: imageOrigin.x + shift.x, y: imageOrigin.y + shift.y)
            annotations = annotations.map { $0.shifted(by: shift) }
        }
        pixelSize = CGSize(width: maxX - minX, height: maxY - minY)
        frame = NSRect(origin: .zero, size: pixelSize)
        invalidateIntrinsicContentSize()
        onCanvasResized?()
        return shift
    }

    // MARK: - Text editing

    private func beginTextEditing(at point: CGPoint) {
        commitTextEditing()
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y, width: 240, height: 30))
        field.font = NSFont.boldSystemFont(ofSize: 24)
        field.textColor = currentColor
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = L("Text …")
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) { commitTextEditing() }

    func commitTextEditing() {
        guard let field = activeTextField else { return }
        let text = field.stringValue
        let origin = field.frame.origin
        field.removeFromSuperview()
        activeTextField = nil
        guard !text.isEmpty else { return }
        var a = Annotation(tool: .text, start: origin, end: origin,
                           color: field.textColor ?? currentColor, lineWidth: currentLineWidth)
        a.text = text
        commit(a)
        needsDisplay = true
    }

    // MARK: - Undo

    private func currentState() -> CanvasState {
        CanvasState(image: image, imagePixelSize: imagePixelSize, imageOrigin: imageOrigin,
                    pixelSize: pixelSize, annotations: annotations)
    }

    private func pushUndo() {
        undoStack.append(currentState())
        redoStack.removeAll()
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    private func apply(_ state: CanvasState) {
        let sizeChanged = pixelSize != state.pixelSize
        image = state.image
        imagePixelSize = state.imagePixelSize
        imageOrigin = state.imageOrigin
        pixelSize = state.pixelSize
        annotations = state.annotations
        cachedPixelated = nil
        frame = NSRect(origin: .zero, size: pixelSize)
        invalidateIntrinsicContentSize()
        if sizeChanged { onCanvasResized?() }
        needsDisplay = true
    }

    func undo() {
        if let field = activeTextField { field.removeFromSuperview(); activeTextField = nil }
        if cropRect != nil { cancelCrop(); return }
        guard let state = undoStack.popLast() else { return }
        redoStack.append(currentState())
        apply(state)
    }

    func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append(currentState())
        apply(state)
    }

    // MARK: - Crop (interactive, with handles)

    private func cropMouseDown(_ p: CGPoint) {
        if let r = cropRect, let handle = cropHandle(at: p, in: r) {
            cropDragHandle = handle
            cropDragStart = p
            cropRectAtDragStart = r
            cropDrawing = false
        } else {
            cropDrawing = true
            cropDragStart = p
            cropRect = CGRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    private func cropMouseDragged(_ p: CGPoint) {
        if cropDrawing {
            cropRect = NSRect(from: cropDragStart, to: p).intersection(contentBounds)
        } else if let handle = cropDragHandle {
            let delta = CGPoint(x: p.x - cropDragStart.x, y: p.y - cropDragStart.y)
            cropRect = adjustedCropRect(cropRectAtDragStart, handle: handle, delta: delta)
        }
        needsDisplay = true
    }

    private func cropMouseUp(_ p: CGPoint) {
        if cropDrawing {
            cropDrawing = false
            if let r = cropRect, r.width > 8, r.height > 8 {
                cropRect = r.intersection(contentBounds)
                onCropStateChanged?(true)
            } else {
                cropRect = nil
                onCropStateChanged?(false)
            }
        }
        cropDragHandle = nil
        needsDisplay = true
    }

    private func cropHandle(at p: CGPoint, in rect: CGRect) -> CropHandle? {
        let tol = 12 / viewScale
        let order: [CropHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        for (point, handle) in zip(handlePoints(rect), order) {
            if abs(p.x - point.x) <= tol, abs(p.y - point.y) <= tol { return handle }
        }
        return rect.contains(p) ? .inside : nil
    }

    private func adjustedCropRect(_ rect: CGRect, handle: CropHandle, delta: CGPoint) -> CGRect {
        if handle == .inside {
            var r = rect.offsetBy(dx: delta.x, dy: delta.y)
            r.origin.x = min(max(r.minX, 0), pixelSize.width - r.width)
            r.origin.y = min(max(r.minY, 0), pixelSize.height - r.height)
            return r
        }
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let left: Set<CropHandle> = [.left, .topLeft, .bottomLeft]
        let right: Set<CropHandle> = [.right, .topRight, .bottomRight]
        let top: Set<CropHandle> = [.top, .topLeft, .topRight]
        let bottom: Set<CropHandle> = [.bottom, .bottomLeft, .bottomRight]
        if left.contains(handle) { minX += delta.x }
        if right.contains(handle) { maxX += delta.x }
        if top.contains(handle) { maxY += delta.y }
        if bottom.contains(handle) { minY += delta.y }
        minX = min(max(minX, 0), maxX - 8)
        maxX = max(min(maxX, pixelSize.width), minX + 8)
        minY = min(max(minY, 0), maxY - 8)
        maxY = max(min(maxY, pixelSize.height), minY + 8)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func applyCrop() {
        guard let r = cropRect else { return }
        cropRect = nil
        crop(to: r)
        onCropStateChanged?(false)
    }

    func cancelCrop() {
        guard cropRect != nil else { return }
        cropRect = nil
        onCropStateChanged?(false)
        needsDisplay = true
    }

    /// Flattens the current state, crops it to `rect` and makes that the new base image.
    private func crop(to rect: NSRect) {
        let clamped = rect.intersection(contentBounds)
        guard clamped.width > 4, clamped.height > 4 else { return }

        let flat = exportImage()
        var proposed = NSRect(origin: .zero, size: pixelSize)
        guard let cg = flat.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }

        let scaleX = CGFloat(cg.width) / pixelSize.width
        let scaleY = CGFloat(cg.height) / pixelSize.height
        let cgRect = CGRect(x: clamped.minX * scaleX,
                            y: (pixelSize.height - clamped.maxY) * scaleY,
                            width: clamped.width * scaleX,
                            height: clamped.height * scaleY).integral
        guard let cropped = cg.cropping(to: cgRect) else { return }

        pushUndo()
        let newSize = CGSize(width: clamped.width, height: clamped.height)
        image = NSImage(cgImage: cropped, size: newSize)
        imagePixelSize = newSize
        imageOrigin = .zero
        pixelSize = newSize
        annotations.removeAll()
        cachedPixelated = nil
        frame = NSRect(origin: .zero, size: newSize)
        invalidateIntrinsicContentSize()
        onCanvasResized?()
        needsDisplay = true
    }

    // MARK: - Selection / move / resize

    func clearSelection() {
        selectedIndex = nil
        activeDrag = nil
        needsDisplay = true
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), pixelSize.width), y: min(max(p.y, 0), pixelSize.height))
    }

    private func selectMouseDown(_ p: CGPoint) {
        if let idx = selectedIndex, annotations.indices.contains(idx),
           let kind = handleHit(p, annotations[idx]) {
            activeDrag = kind
        } else if let idx = hitTestAnnotation(p) {
            selectedIndex = idx
            activeDrag = .move
        } else {
            selectedIndex = nil
            activeDrag = nil
        }
        dragStartMouse = p
        dragStartAnnotation = selectedIndex.flatMap { annotations.indices.contains($0) ? annotations[$0] : nil }
        dragPushedUndo = false
        needsDisplay = true
    }

    private func selectMouseDragged(_ p: CGPoint) {
        guard let drag = activeDrag, let idx = selectedIndex,
              let base = dragStartAnnotation, annotations.indices.contains(idx) else { return }
        if !dragPushedUndo { pushUndo(); dragPushedUndo = true }
        let delta = CGPoint(x: p.x - dragStartMouse.x, y: p.y - dragStartMouse.y)
        switch drag {
        case .move:
            annotations[idx] = base.shifted(by: delta)
        case .point(let isStart):
            var a = base
            if isStart { a.start = clampToBounds(p) } else { a.end = clampToBounds(p) }
            annotations[idx] = a
        case .corner(let corner):
            var a = base
            let r = NSRect(from: base.start, to: base.end)
            let opposite = oppositeCorner(corner, in: r)
            let newRect = NSRect(from: opposite, to: clampToBounds(p))
            a.start = CGPoint(x: newRect.minX, y: newRect.minY)
            a.end = CGPoint(x: newRect.maxX, y: newRect.maxY)
            annotations[idx] = a
        }
        needsDisplay = true
    }

    private func selectMouseUp(_ p: CGPoint) {
        activeDrag = nil
        dragStartAnnotation = nil
        needsDisplay = true
    }

    private func handles(for a: Annotation) -> [(DragKind, CGPoint)] {
        switch a.tool {
        case .arrow, .ruler:
            return [(.point(isStart: true), a.start), (.point(isStart: false), a.end)]
        case .rect, .ellipse, .spotlight, .pixelate, .image:
            let r = NSRect(from: a.start, to: a.end)
            return [(.corner(.bl), CGPoint(x: r.minX, y: r.minY)),
                    (.corner(.br), CGPoint(x: r.maxX, y: r.minY)),
                    (.corner(.tl), CGPoint(x: r.minX, y: r.maxY)),
                    (.corner(.tr), CGPoint(x: r.maxX, y: r.maxY))]
        default:
            return []
        }
    }

    private func oppositeCorner(_ corner: Corner, in r: CGRect) -> CGPoint {
        switch corner {
        case .bl: return CGPoint(x: r.maxX, y: r.maxY)
        case .br: return CGPoint(x: r.minX, y: r.maxY)
        case .tl: return CGPoint(x: r.maxX, y: r.minY)
        case .tr: return CGPoint(x: r.minX, y: r.minY)
        }
    }

    private func handleHit(_ p: CGPoint, _ a: Annotation) -> DragKind? {
        let tol = 10 / viewScale
        for (kind, point) in handles(for: a) {
            if abs(p.x - point.x) <= tol, abs(p.y - point.y) <= tol { return kind }
        }
        return nil
    }

    private func hitTestAnnotation(_ p: CGPoint) -> Int? {
        for idx in annotations.indices.reversed() where annotationContains(annotations[idx], p) {
            return idx
        }
        return nil
    }

    private func annotationContains(_ a: Annotation, _ p: CGPoint) -> Bool {
        switch a.tool {
        case .arrow, .ruler:
            return distanceToSegment(p, a.start, a.end) <= max(8, a.lineWidth) + 4
        case .highlighter:
            guard a.points.count > 1 else { return false }
            for i in 1..<a.points.count where
                distanceToSegment(p, a.points[i - 1], a.points[i]) <= max(14, a.lineWidth * 4) / 2 + 2 {
                return true
            }
            return false
        case .text:
            let size = (a.text as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: a.fontSize)])
            return CGRect(origin: a.start, size: size).insetBy(dx: -4, dy: -4).contains(p)
        case .counter:
            return hypot(p.x - a.start.x, p.y - a.start.y) <= counterRadius(a) + 2
        case .rect, .ellipse, .spotlight, .pixelate, .image:
            return NSRect(from: a.start, to: a.end).insetBy(dx: -4, dy: -4).contains(p)
        default:
            return false
        }
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        if dx == 0, dy == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func selectionBounds(_ a: Annotation) -> CGRect {
        switch a.tool {
        case .text:
            let size = (a.text as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: a.fontSize)])
            return CGRect(origin: a.start, size: size)
        case .counter:
            let r = counterRadius(a)
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r)
        case .highlighter:
            return pointsBounds(a.points)
        default:
            return NSRect(from: a.start, to: a.end)
        }
    }

    private func drawSelection() {
        guard currentTool == .select, let idx = selectedIndex, annotations.indices.contains(idx) else { return }
        let a = annotations[idx]
        let points = handles(for: a)
        if points.isEmpty {
            let box = NSBezierPath(rect: selectionBounds(a).insetBy(dx: -3, dy: -3))
            box.lineWidth = 1 / viewScale
            box.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            box.stroke()
        } else {
            let hs = 10 / viewScale
            for (_, point) in points {
                let hr = CGRect(x: point.x - hs / 2, y: point.y - hs / 2, width: hs, height: hs)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: hr).fill()
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: hr)
                ring.lineWidth = 2 / viewScale
                ring.stroke()
            }
        }
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([exportImage()])
    }

    @objc func paste(_ sender: Any?) {
        guard let image = NSImage(pasteboard: .general) else { return }
        var size = image.size
        let scale = min(1, pixelSize.width * 0.8 / size.width, pixelSize.height * 0.8 / size.height)
        size = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (pixelSize.width - size.width) / 2, y: (pixelSize.height - size.height) / 2)
        var a = Annotation(tool: .image, start: origin,
                           end: CGPoint(x: origin.x + size.width, y: origin.y + size.height),
                           color: .clear, lineWidth: 0)
        a.image = image
        commit(a)
        selectedIndex = annotations.count - 1
        currentTool = .select
        onToolChanged?()
        needsDisplay = true
    }

    // MARK: - Export

    func exportImage() -> NSImage {
        commitTextEditing()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(pixelSize.width),
                                   pixelsHigh: Int(pixelSize.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = pixelSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: pixelSize)).fill()
        image.draw(in: CGRect(origin: imageOrigin, size: imagePixelSize))
        for annotation in annotations { drawAnnotation(annotation) }
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: pixelSize)
        out.addRepresentation(rep)
        return out
    }

    func exportPNGData() -> Data? {
        exportImage().representations.compactMap { $0 as? NSBitmapImageRep }.first?
            .representation(using: .png, properties: [:])
    }

    func exportJPEGData() -> Data? {
        exportImage().representations.compactMap { $0 as? NSBitmapImageRep }.first?
            .representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// Flattened image as CGImage – input for OCR / QR recognition.
    func flattenedCGImage() -> CGImage? {
        var rect = NSRect(origin: .zero, size: pixelSize)
        return exportImage().cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
