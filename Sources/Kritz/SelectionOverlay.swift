import AppKit

/// Borderless window that can become key (needed to receive Esc/Return).
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-screen crosshair selection across *every* display, like Skitch's own capture.
///
/// One borderless overlay window is placed over each `NSScreen`, so the whole desktop
/// dims — not just the main display. The selection is tracked in global screen
/// coordinates (bottom-left origin) so you can drag on any monitor; the view that
/// receives the initial click drives the drag (AppKit captures the mouse) and
/// broadcasts the current rect to the other screens' overlays so they dim in sync.
///
/// If `delay > 0`, after the region is picked it keeps the selection bright and the rest
/// dimmed while a countdown runs (with a tick sound), then reports the rect.
/// Reports the chosen rect (global screen points, bottom-left origin) or `nil` if cancelled.
final class SelectionOverlay {

    private var windows: [OverlayWindow] = []
    private var views: [SelectionView] = []
    private var completion: ((CGRect?) -> Void)?
    private var finished = false

    func begin(delay: TimeInterval, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion

        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.delay = delay
            view.coordinator = self
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()

            windows.append(window)
            views.append(view)
        }

        // Start with the main screen's overlay key so Esc works before any drag; the
        // overlay that gets clicked makes itself key (see SelectionView.mouseDown).
        let keyIndex = NSScreen.screens.firstIndex(where: { $0 == NSScreen.main }) ?? 0
        if windows.indices.contains(keyIndex) {
            let window = windows[keyIndex], view = views[keyIndex]
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Mirrors the in-progress selection onto every overlay except the one driving it.
    func broadcast(globalRect: CGRect, counting: Bool, countdown: Int, from driver: SelectionView) {
        for view in views where view !== driver {
            view.reflect(globalRect: globalRect, counting: counting, countdown: countdown)
        }
    }

    /// Lets clicks fall through on every screen while the countdown runs.
    func setIgnoreMouseEvents(_ ignore: Bool) {
        windows.forEach { $0.ignoresMouseEvents = ignore }
    }

    func finish(with rect: CGRect?) {
        guard !finished else { return }
        finished = true
        views.forEach { $0.cancelTimer() }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        completion?(rect)
        completion = nil
    }
}

/// The dimmed crosshair view. Drag to select; Esc or a click without drag cancels.
/// When a delay is set, it shows a live countdown over the selected region before completing.
///
/// Coordinates are kept in *global* screen points (bottom-left origin); `screenFrame` is
/// this view's screen in that space, so local ↔ global is a simple offset.
final class SelectionView: NSView {

    weak var coordinator: SelectionOverlay?
    var screenFrame: CGRect = .zero
    var delay: TimeInterval = 0

    private enum Phase { case selecting, counting }
    private var phase: Phase = .selecting

    private var startGlobal: CGPoint?
    private var globalRect: CGRect = .zero
    private var isDriver = false

    private var countdownRemaining = 0
    private var countdownTimer: Timer?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private func toGlobal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + screenFrame.minX, y: p.y + screenFrame.minY)
    }
    private func toLocal(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    /// Called on the non-driving overlays so they dim in sync with the driver.
    func reflect(globalRect: CGRect, counting: Bool, countdown: Int) {
        self.globalRect = globalRect
        self.phase = counting ? .counting : .selecting
        self.countdownRemaining = countdown
        needsDisplay = true
    }

    func cancelTimer() { countdownTimer?.invalidate(); countdownTimer = nil }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let activeRect = toLocal(globalRect).intersection(bounds)

        NSColor(white: 0, alpha: 0.35).setFill()
        let dim = NSBezierPath(rect: bounds)
        if activeRect.width > 0, activeRect.height > 0 {
            dim.append(NSBezierPath(rect: activeRect).reversed)
            dim.windingRule = .evenOdd
        }
        dim.fill()

        guard activeRect.width > 0, activeRect.height > 0 else { return }

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: activeRect)
        border.lineWidth = 2
        border.stroke()

        if phase == .counting {
            drawCountdown(in: activeRect)
        } else {
            drawSizeReadout(for: activeRect)
        }
    }

    private func drawSizeReadout(for rect: CGRect) {
        // Always report the full selection size, even if only part of it is on this screen.
        let label = "\(Int(globalRect.width)) × \(Int(globalRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let pill = NSRect(x: rect.midX - textSize.width / 2 - 8,
                          y: max(rect.minY - textSize.height - 12, 6),
                          width: textSize.width + 16, height: textSize.height + 8)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        (label as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4), withAttributes: attrs)
    }

    private func drawCountdown(in rect: CGRect) {
        let label = "\(countdownRemaining)"
        let fontSize = max(28, min(150, min(rect.width, rect.height) * 0.5))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .shadow: shadow
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
        (label as NSString).draw(at: point, withAttributes: attrs)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard phase == .selecting else { return }
        window?.makeKey() // so Esc reaches this screen's overlay during the drag
        isDriver = true
        startGlobal = toGlobal(convert(event.locationInWindow, from: nil))
        globalRect = .zero
        coordinator?.broadcast(globalRect: .zero, counting: false, countdown: 0, from: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard phase == .selecting, let start = startGlobal else { return }
        globalRect = NSRect(from: start, to: toGlobal(convert(event.locationInWindow, from: nil)))
        coordinator?.broadcast(globalRect: globalRect, counting: false, countdown: 0, from: self)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard phase == .selecting else { return }
        guard globalRect.width > 4, globalRect.height > 4 else {
            coordinator?.finish(with: nil) // treated as cancel
            return
        }
        if delay > 0 {
            beginCountdown()
        } else {
            coordinator?.finish(with: globalRect)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc cancels in any phase
            cancelTimer()
            coordinator?.finish(with: nil)
        }
    }

    override func resetCursorRects() {
        if phase == .selecting { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: - Countdown

    private func beginCountdown() {
        phase = .counting
        countdownRemaining = Int(delay)
        // Let clicks fall through to apps underneath (on every screen) while counting.
        coordinator?.setIgnoreMouseEvents(true)
        coordinator?.broadcast(globalRect: globalRect, counting: true, countdown: countdownRemaining, from: self)
        playTick()
        needsDisplay = true

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            countdownRemaining -= 1
            if countdownRemaining <= 0 {
                cancelTimer()
                coordinator?.finish(with: globalRect)
            } else {
                coordinator?.broadcast(globalRect: globalRect, counting: true,
                                       countdown: countdownRemaining, from: self)
                playTick()
                needsDisplay = true
            }
        }
    }

    private func playTick() {
        NSSound(named: NSSound.Name("Tink"))?.play()
    }
}
