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

    var canRepeat: Bool { lastRect != nil }

    /// `delay` in seconds; 0 = capture immediately after the region is chosen.
    /// The selection overlay itself runs the countdown (keeping the region bright), so by the
    /// time we get `rect` back the countdown has already finished. `rect` is in global screen
    /// coordinates, so the region can be picked on any connected display.
    func capture(delay: TimeInterval, completion: @escaping (NSImage?) -> Void) {
        let overlay = SelectionOverlay()
        selection = overlay
        overlay.begin(delay: delay) { [weak self] rect in
            self?.selection = nil
            guard let rect else { completion(nil); return } // cancelled
            self?.lastRect = rect
            self?.grab(globalRect: rect, completion: completion)
        }
    }

    /// Re-captures the most recently selected region without asking again.
    func repeatLast(completion: @escaping (NSImage?) -> Void) {
        guard let rect = lastRect else { completion(nil); return }
        grab(globalRect: rect, completion: completion)
    }

    /// The display the selection falls on the most (selections that straddle two monitors
    /// are captured from whichever one holds the larger part).
    private func screen(for globalRect: CGRect) -> NSScreen? {
        NSScreen.screens.max {
            $0.frame.intersection(globalRect).area < $1.frame.intersection(globalRect).area
        } ?? NSScreen.main
    }

    /// `screencapture -D` index for a screen (1 = main, 2 = secondary …). Mapped via the
    /// active display list, whose first entry is the main display — matching `-D`'s numbering.
    private func displayNumber(for screen: NSScreen) -> Int? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.firstIndex(of: id).map { $0 + 1 }
    }

    private func grab(globalRect: CGRect, completion: @escaping (NSImage?) -> Void) {
        guard let screen = screen(for: globalRect) else { completion(nil); return }
        let scale = screen.backingScaleFactor
        let screenHeight = screen.frame.height
        // Region relative to the target screen's own bottom-left origin.
        let rect = globalRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let displayArgs = displayNumber(for: screen).map { ["-D", "\($0)"] } ?? []
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kritz-\(UUID().uuidString).png")

        // Small delay so any overlay is gone from the compositor before the grab.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // No -x: let screencapture play the native shutter sound on capture.
            process.arguments = displayArgs + [tmpURL.path] // full target display

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
