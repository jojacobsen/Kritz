import AppKit
import Sparkle
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Kritz keeps a single editor window and reuses it for every capture, so a run of
    /// screenshots doesn't pile up (or need closing) one window at a time.
    private var editor: EditorWindowController?
    private let capture = CaptureController()
    private var updaterController: SPUStandardUpdaterController?   // Sparkle auto-updater
    private var globalHotKey: GlobalHotKey?
    private var preferencesWC: PreferencesWindowController?

    static let timerPresets = [3, 5, 10]

    /// Sparkle needs a real .app bundle; the bare SwiftPM binary has no Info.plist feed keys.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        if isBundled {
            // Sparkle: starts the updater, which checks for updates on its schedule
            // (SUEnableAutomaticChecks / SUScheduledCheckInterval in Info.plist).
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        registerGlobalHotKey()
        NSApp.activate(ignoringOtherApps: true)
        startCapture(after: 0)
    }

    @objc func checkForUpdates(_ sender: Any?) { updaterController?.updater.checkForUpdates() }

    // MARK: - Global capture hot key

    /// (Re-)registers the system-wide capture shortcut from the stored preference.
    /// Setting `globalHotKey` to nil first unregisters any previous key, so the new
    /// RegisterEventHotKey doesn't fail with "already exists".
    private func registerGlobalHotKey() {
        globalHotKey = nil
        guard let shortcut = HotKeyShortcut.stored else { return }
        globalHotKey = GlobalHotKey(keyCode: UInt32(shortcut.keyCode),
                                    carbonModifiers: shortcut.carbonModifiers) { [weak self] in
            self?.newScreenshot(nil)
        }
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWC == nil {
            let wc = PreferencesWindowController()
            wc.onShortcutChange = { [weak self] _ in self?.registerGlobalHotKey() }
            preferencesWC = wc
        }
        preferencesWC?.showWindow(nil)
        preferencesWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Kritz keeps running with no window after the editor is closed (or a capture is
    /// cancelled). Re-opening it — Dock icon, Spotlight, or `open` — must then do
    /// something visible: bring back the editor window if one exists, otherwise start a
    /// fresh capture like a launch does. Without this, re-opening only moves focus to
    /// Kritz (the menu bar changes) while nothing appears on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true } // a window (or the capture overlay) is already on screen
        if let window = editor?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            editor?.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            startCapture(after: 0)
        }
        return true
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
        guard ensureScreenRecordingPermission() else { return }
        withWindowsHidden { done in capture.capture(delay: delay, completion: done) }
    }

    @objc func repeatLastCapture(_ sender: Any?) {
        guard ensureScreenRecordingPermission() else { return }
        withWindowsHidden { [weak self] done in self?.capture.repeatLast(completion: done) }
    }

    /// Hides Kritz's window for the duration of a capture so it doesn't cover the shot.
    private func withWindowsHidden(_ work: (@escaping (CaptureResult) -> Void) -> Void) {
        let wasVisible = editor?.window?.isVisible == true
        if wasVisible { editor?.window?.orderOut(nil) }
        work { [weak self] result in
            if wasVisible { self?.editor?.window?.orderFront(nil) }
            self?.handleCaptured(result)
        }
    }

    private func handleCaptured(_ result: CaptureResult) {
        let image: NSImage
        switch result {
        case .cancelled:
            return
        case .failed(let reason):
            presentCaptureError(reason)
            return
        case .image(let captured):
            image = captured
        }
        present(image: image)
    }

    /// Shows `image` in the editor, reusing the one open window (prompting to save any
    /// unsaved work first) or creating it. Shared by screen captures and File ▸ Open.
    private func present(image: NSImage) {
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

    // MARK: - Open an existing image

    @objc func openImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = L("Open")
        NSApp.activate(ignoringOtherApps: true)
        let load: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let image = NSImage(contentsOf: url), image.size.width >= 1, image.size.height >= 1 else {
                self.presentOpenError()
                return
            }
            self.present(image: image)
        }
        // Sheet it on the editor window when one is open; otherwise a free-standing panel.
        if let window = editor?.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: load)
        } else {
            load(panel.runModal())
        }
    }

    private func presentOpenError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Could not open the image")
        alert.informativeText = L("The file could not be read as an image. Please choose a different file.")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Permission & errors

    /// Returns true if Kritz may record the screen. On first denial it triggers the
    /// system prompt and guides the user to System Settings instead of silently
    /// producing a blank capture.
    private func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Adds Kritz to the Screen Recording list / shows the system prompt.
        CGRequestScreenCaptureAccess()
        presentPermissionAlert()
        return false
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Kritz needs Screen Recording permission")
        alert.informativeText = L("To capture your screen, enable Kritz under System Settings → Privacy & Security → Screen Recording, then try again.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentCaptureError(_ reason: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Screenshot failed")
        alert.informativeText = reason ?? L("The screen capture could not be completed. Please try again.")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        let updates = NSMenuItem(title: L("Check for Updates…"),
                                 action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: L("Settings…"),
                                  action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
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

        let open = NSMenuItem(title: L("Open Image…"),
                              action: #selector(openImage(_:)), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)

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
