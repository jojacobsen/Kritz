import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Kritz keeps a single editor window and reuses it for every capture, so a run of
    /// screenshots doesn't pile up (or need closing) one window at a time.
    private var editor: EditorWindowController?
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

    /// Hides Kritz's window for the duration of a capture so it doesn't cover the shot.
    private func withWindowsHidden(_ work: (@escaping (NSImage?) -> Void) -> Void) {
        let wasVisible = editor?.window?.isVisible == true
        if wasVisible { editor?.window?.orderOut(nil) }
        work { [weak self] image in
            if wasVisible { self?.editor?.window?.orderFront(nil) }
            self?.handleCaptured(image)
        }
    }

    private func handleCaptured(_ image: NSImage?) {
        guard let image else { return } // nil = cancelled
        if let editor {
            // Reuse the open window; it prompts to save unsaved work before replacing.
            editor.showWindow(nil)
            editor.loadCapture(image)
        } else {
            let editor = EditorWindowController(image: image)
            editor.onClose = { [weak self] _ in self?.editor = nil }
            self.editor = editor
            editor.showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - About

    @objc func showAbout(_ sender: Any?) {
        let body = NSMutableParagraphStyle()
        body.alignment = .center
        body.lineSpacing = 2

        let credits = NSMutableAttributedString()
        func line(_ text: String, size: CGFloat = 11, color: NSColor = .labelColor) {
            credits.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
                .paragraphStyle: body
            ]))
        }

        line(L("A lightweight, native screenshot annotation app for macOS. An open-source replacement for the discontinued Skitch.") + "\n\n")
        line(L("No cloud, no login, no subscription.") + "\n\n", color: .secondaryLabelColor)
        line("MIT License · © 2026 Johannes Jacob\n", size: 10, color: .secondaryLabelColor)

        let link = "https://github.com/jojacobsen/Kritz"
        credits.append(NSAttributedString(string: link, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: link)!,
            .paragraphStyle: body
        ]))

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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
        let about = NSMenuItem(title: L("About Kritz"), action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
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
        fileMenu.addItem(NSMenuItem(title: L("Print…"),
                                    action: #selector(EditorWindowController.printDocument(_:)),
                                    keyEquivalent: "p"))

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
