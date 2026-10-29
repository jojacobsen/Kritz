import AppKit

/// Capture pipeline:
///   1. Show our own crosshair overlay → user drags a region.
///   2. If a delay is set, run a visible countdown (so the user can set up the scene,
///      e.g. open a menu). This is why the timer works the way you'd expect:
///      pick the box first, *then* the timer runs, *then* it captures.
///   3. Grab the whole display with `screencapture` and crop to the chosen region.
///      Cropping in our own coordinate space avoids screencapture's `-R` ambiguities.
final class CaptureController {

    private var selection: SelectionOverlay?
    private var lastRect: CGRect?
    private var lastScreen: NSScreen?

    var canRepeat: Bool { lastRect != nil }

    /// `delay` in seconds; 0 = capture immediately after the region is chosen.
    /// The selection overlay itself runs the countdown (keeping the region bright), so by the
    /// time we get `rect` back the countdown has already finished.
    func capture(delay: TimeInterval, completion: @escaping (NSImage?) -> Void) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let overlay = SelectionOverlay()
        selection = overlay
        overlay.begin(on: screen, delay: delay) { [weak self] rect in
            self?.selection = nil
            guard let rect else { completion(nil); return } // cancelled
            self?.lastRect = rect
            self?.lastScreen = screen
            self?.grab(rect: rect, screen: screen, completion: completion)
        }
    }

    /// Re-captures the most recently selected region without asking again.
    func repeatLast(completion: @escaping (NSImage?) -> Void) {
        guard let rect = lastRect, let screen = lastScreen else { completion(nil); return }
        grab(rect: rect, screen: screen, completion: completion)
    }

    private func grab(rect: CGRect, screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        let scale = screen.backingScaleFactor
        let screenHeight = screen.frame.height
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kritz-\(UUID().uuidString).png")

        // Small delay so any overlay is gone from the compositor before the grab.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // No -x: let screencapture play the native shutter sound on capture.
            process.arguments = [tmpURL.path] // full main display

            process.terminationHandler = { _ in
                DispatchQueue.main.async {
                    defer { try? FileManager.default.removeItem(at: tmpURL) }
                    guard let full = NSImage(contentsOf: tmpURL),
                          let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        completion(nil); return
                    }
                    // Convert region (screen points, bottom-left origin) → image pixels (top-left).
                    var px = CGRect(x: rect.minX * scale,
                                    y: (screenHeight - rect.maxY) * scale,
                                    width: rect.width * scale,
                                    height: rect.height * scale).integral
                    px = px.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                    guard px.width >= 1, px.height >= 1, let cropped = cg.cropping(to: px) else {
                        completion(nil); return
                    }
                    let size = NSSize(width: px.width / scale, height: px.height / scale)
                    completion(NSImage(cgImage: cropped, size: size))
                }
            }

            do { try process.run() } catch {
                NSLog("Kritz: screencapture failed: \(error)")
                completion(nil)
            }
        }
    }
}
