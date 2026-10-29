import AppKit

/// Borderless window that can become key (needed to receive Esc/Return).
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-screen crosshair selection, like Skitch's own capture.
/// If `delay > 0`, after the region is picked it keeps the selection bright and the rest
/// dimmed while a countdown runs (with a tick sound), then reports the rect.
/// Reports the chosen rect (in screen points, bottom-left origin) or `nil` if cancelled.
final class SelectionOverlay {

    private var window: OverlayWindow?

    func begin(on screen: NSScreen, delay: TimeInterval, completion: @escaping (CGRect?) -> Void) {
        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.delay = delay
        view.onComplete = { [weak self] rect in
            self?.window?.orderOut(nil)
            self?.window = nil
            completion(rect)
        }
        window.contentView = view

        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { window.makeFirstResponder(view) }
        self.window = window
    }
}

/// The dimmed crosshair view. Drag to select; Esc or a click without drag cancels.
/// When a delay is set, it shows a live countdown over the selected region before completing.
final class SelectionView: NSView {

    var onComplete: ((CGRect?) -> Void)?
    var delay: TimeInterval = 0

    private enum Phase { case selecting, counting }
    private var phase: Phase = .selecting

    private var startPoint: CGPoint?
    private var currentRect: CGRect = .zero
    private var finalRect: CGRect = .zero

    private var countdownRemaining = 0
    private var countdownTimer: Timer?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let activeRect = phase == .counting ? finalRect : currentRect

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
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
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
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard phase == .selecting, let start = startPoint else { return }
        currentRect = NSRect(from: start, to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard phase == .selecting else { return }
        guard currentRect.width > 4, currentRect.height > 4 else {
            onComplete?(nil) // treated as cancel
            return
        }
        if delay > 0 {
            beginCountdown()
        } else {
            onComplete?(currentRect)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc cancels in any phase
            countdownTimer?.invalidate()
            onComplete?(nil)
        }
    }

    override func resetCursorRects() {
        if phase == .selecting { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: - Countdown

    private func beginCountdown() {
        phase = .counting
        finalRect = currentRect
        countdownRemaining = Int(delay)
        // Let clicks fall through to apps underneath while the countdown runs.
        window?.ignoresMouseEvents = true
        playTick()
        needsDisplay = true

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            countdownRemaining -= 1
            if countdownRemaining <= 0 {
                countdownTimer?.invalidate()
                onComplete?(finalRect)
            } else {
                playTick()
                needsDisplay = true
            }
        }
    }

    private func playTick() {
        NSSound(named: NSSound.Name("Tink"))?.play()
    }
}
