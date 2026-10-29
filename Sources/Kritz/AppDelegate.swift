import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var editors: [EditorWindowController] = []
    private let capture = CaptureController()

    static let timerPresets = [3, 5, 10]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        NSApp.activate(ignoringOtherApps: true)
        startCapture(after: 0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Capture

    @objc func newScreenshot(_ sender: Any?) {
        startCapture(after: 0)
    }

    /// Timed capture. The sender's `tag` carries the delay in seconds.
    @objc func newScreenshotTimed(_ sender: NSMenuItem) {
        startCapture(after: TimeInterval(sender.tag))
    }

    private func startCapture(after delay: TimeInterval) {
        withWindowsHidden { done in capture.capture(delay: delay, completion: done) }
    }

    @objc func repeatLastCapture(_ sender: Any?) {
        withWindowsHidden { [weak self] done in self?.capture.repeatLast(completion: done) }
    }

    /// Hides Kritz's windows for the duration of a capture so they don't cover the shot.
    private func withWindowsHidden(_ work: (@escaping (NSImage?) -> Void) -> Void) {
        let toRestore = editors.filter { $0.window?.isVisible == true }
        toRestore.forEach { $0.window?.orderOut(nil) }
        work { [weak self] image in
            toRestore.forEach { $0.window?.orderFront(nil) }
            self?.handleCaptured(image)
        }
    }

    private func handleCaptured(_ image: NSImage?) {
        guard let image else { return } // nil = cancelled
        let editor = EditorWindowController(image: image)
        editor.onClose = { [weak self] controller in
            self?.editors.removeAll { $0 === controller }
        }
        editors.append(editor)
        editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L("About Kritz"), action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide Kritz"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("Quit Kritz"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: L("File"))
        fileItem.submenu = fileMenu

        let new = NSMenuItem(title: L("New Screenshot"),
                             action: #selector(newScreenshot(_:)), keyEquivalent: "n")
        new.target = self
        fileMenu.addItem(new)

        let timerItem = NSMenuItem(title: L("Timed Capture"), action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        for seconds in AppDelegate.timerPresets {
            let item = NSMenuItem(title: String(format: L("After %d seconds"), seconds),
                                  action: #selector(newScreenshotTimed(_:)), keyEquivalent: "")
            item.tag = seconds
            item.target = self
            timerMenu.addItem(item)
        }
        timerItem.submenu = timerMenu
        fileMenu.addItem(timerItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: L("Save…"),
                                    action: #selector(EditorWindowController.saveDocument(_:)),
                                    keyEquivalent: "s"))

        // Edit menu
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L("Edit"))
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: L("Undo"),
                                    action: #selector(EditorWindowController.undo(_:)),
                                    keyEquivalent: "z"))
        let redo = NSMenuItem(title: L("Redo"),
                              action: #selector(EditorWindowController.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        let copyImage = NSMenuItem(title: L("Copy Image"),
                                   action: #selector(EditorWindowController.copyImage(_:)),
                                   keyEquivalent: "c")
        copyImage.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(copyImage)
        editMenu.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        // Tools menu
        let toolsItem = NSMenuItem()
        mainMenu.addItem(toolsItem)
        let toolsMenu = NSMenu(title: L("Tools"))
        toolsItem.submenu = toolsMenu
        toolsMenu.addItem(NSMenuItem(title: L("Recognize Text (OCR)"),
                                     action: #selector(EditorWindowController.recognizeText(_:)), keyEquivalent: ""))
        toolsMenu.addItem(NSMenuItem(title: L("Read QR Code"),
                                     action: #selector(EditorWindowController.readQRCode(_:)), keyEquivalent: ""))
        toolsMenu.addItem(.separator())
        let repeatItem = NSMenuItem(title: L("Repeat Last Area"),
                                    action: #selector(repeatLastCapture(_:)), keyEquivalent: "r")
        repeatItem.keyEquivalentModifierMask = [.command, .shift]
        repeatItem.target = self
        toolsMenu.addItem(repeatItem)

        NSApp.mainMenu = mainMenu
    }
}
