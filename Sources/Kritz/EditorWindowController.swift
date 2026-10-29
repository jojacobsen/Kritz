import AppKit
import UniformTypeIdentifiers

/// One window = one screenshot being annotated.
/// Layout mirrors Skitch: a vertical tool palette on the left, the canvas in the middle,
/// a thin status bar at the bottom. Icons are SF Symbols; the active tool gets a soft
/// accent-tinted pill, like a modern macOS sidebar.
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    var onClose: ((EditorWindowController) -> Void)?

    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private var toolButtons: [NSButton] = []
    private let lineWidths: [CGFloat] = [2, 4, 8, 14]
    private let lineWidthButton = HoverButton()
    private let colorWell = NSColorWell()

    private let zoomLabel = NSTextField(labelWithString: "")
    private let dimLabel = NSTextField(labelWithString: "")
    private let cropBar = NSVisualEffectView()

    private let sidebarWidth: CGFloat = 64
    private let statusBarHeight: CGFloat = 26
    private let topBarHeight: CGFloat = 48

    init(image: NSImage) {
        canvas = CanvasView(image: image)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kritz"
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        canvas.onCanvasResized = { [weak self] in self?.zoomToFit() }
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        let H = content.bounds.height, W = content.bounds.width

        let topBar = makeTopBar()
        topBar.frame = NSRect(x: 0, y: H - topBarHeight, width: W, height: topBarHeight)
        topBar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(topBar)

        let sidebar = makeSidebar()
        sidebar.frame = NSRect(x: 0, y: statusBarHeight,
                               width: sidebarWidth, height: H - statusBarHeight - topBarHeight)
        sidebar.autoresizingMask = [.height]
        content.addSubview(sidebar)

        let statusBar = makeStatusBar()
        statusBar.frame = NSRect(x: 0, y: 0, width: W, height: statusBarHeight)
        statusBar.autoresizingMask = [.width]
        content.addSubview(statusBar)

        scrollView.frame = NSRect(x: sidebarWidth, y: statusBarHeight,
                                  width: W - sidebarWidth,
                                  height: H - statusBarHeight - topBarHeight)
        scrollView.autoresizingMask = [.width, .height]
        // Centering clip view so a small screenshot sits in the middle, not bottom-left.
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = .underPageBackgroundColor
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 4
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        content.addSubview(scrollView)

        // Subtle hairline dividers (frame-based – see addHairline) between the chrome and canvas.
        addHairline(to: content, // under the top bar
                    frame: NSRect(x: 0, y: H - topBarHeight - 1, width: W, height: 1),
                    autoresizing: [.width, .minYMargin])
        addHairline(to: content, // right of the tool palette
                    frame: NSRect(x: sidebarWidth, y: statusBarHeight,
                                  width: 1, height: H - statusBarHeight - topBarHeight),
                    autoresizing: [.height, .maxXMargin])
        addHairline(to: content, // above the status bar
                    frame: NSRect(x: 0, y: statusBarHeight, width: W, height: 1),
                    autoresizing: [.width, .maxYMargin])

        setupCropBar(in: content)
        canvas.onCropStateChanged = { [weak self] active in
            self?.cropBar.isHidden = !active
        }
        canvas.onToolChanged = { [weak self] in self?.highlightSelectedTool() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(magnificationChanged),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        window.makeFirstResponder(canvas)
        highlightSelectedTool()
        DispatchQueue.main.async { [weak self] in self?.zoomToFit() }
    }

    private func makeTopBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.distribution = .gravityAreas
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])

        // Capture group (centered, highlighted)
        let camera = captureButton(symbol: "camera.viewfinder", fallback: "◉", tip: L("New Screenshot"),
                                   action: #selector(AppDelegate.newScreenshot(_:)), target: nil, filled: true)
        let timer = captureButton(symbol: "timer", fallback: "⏱", tip: L("Timer"),
                                  action: #selector(showTimerMenu(_:)), target: self, filled: false)
        stack.addView(camera, in: .center)
        stack.addView(timer, in: .center)

        // Edit + output (right)
        let undo = iconButton(symbol: "arrow.uturn.backward", fallback: "↩︎", tip: L("Undo"),
                              action: #selector(undo(_:)), target: self)
        let redo = iconButton(symbol: "arrow.uturn.forward", fallback: "↪︎", tip: L("Redo"),
                              action: #selector(redo(_:)), target: self)
        let copy = iconButton(symbol: "doc.on.doc", fallback: "⧉", tip: L("Copy"),
                              action: #selector(copyImage(_:)), target: self)
        let save = iconButton(symbol: "square.and.arrow.down", fallback: "▼", tip: L("Save"),
                              action: #selector(saveDocument(_:)), target: self)
        [undo, redo].forEach { stack.addView($0, in: .trailing) }
        stack.addView(verticalDivider(height: 22), in: .trailing)
        [copy, save].forEach { stack.addView($0, in: .trailing) }
        return bar
    }

    /// A short vertical hairline used to group buttons inside a horizontal stack.
    private func verticalDivider(height: CGFloat) -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: height)
        ])
        return line
    }

    /// A 1pt hairline as a plain frame-based view. Deliberately NOT Auto Layout:
    /// constraint-based separators inside the frame-based bars would engage the
    /// window's fitting size and collapse the content area on display.
    private func addHairline(to content: NSView, frame: NSRect, autoresizing: NSView.AutoresizingMask) {
        let line = NSView(frame: frame)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.autoresizingMask = autoresizing
        content.addSubview(line)
    }

    private func makeSidebar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .sidebar
        bar.blendingMode = .behindWindow

        // Scrollable so the (now longer) tool list never clips on short windows.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor)
        ])
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])

        // Drawing tools
        let specs: [(String, String, Tool, String)] = [
            ("cursorarrow", "⬉", .select, L("Select")),
            ("arrow.up.left", "➤", .arrow, L("Arrow")),
            ("textformat", "A", .text, L("Text")),
            ("rectangle", "▭", .rect, L("Rectangle")),
            ("circle", "◯", .ellipse, L("Ellipse")),
            ("highlighter", "✎", .highlighter, L("Highlighter")),
            ("number.circle", "①", .counter, L("Counter")),
            ("ruler", "📏", .ruler, L("Ruler")),
            ("circle.dashed.inset.filled", "◍", .spotlight, L("Spotlight")),
            ("mosaic", "▦", .pixelate, L("Pixelate")),
            ("crop", "⌗", .crop, L("Crop"))
        ]
        for (symbol, fallback, tool, tip) in specs {
            let b = toolButton(symbol: symbol, fallback: fallback, tag: tool.rawValue, tip: tip)
            toolButtons.append(b)
            stack.addArrangedSubview(b)
            // Group the Select tool apart from the drawing tools.
            if tool == .select { stack.addArrangedSubview(separator()) }
        }

        stack.addArrangedSubview(separator())

        // Colour + eyedropper + line width
        colorWell.color = canvas.currentColor
        colorWell.target = self
        colorWell.action = #selector(changeColor(_:))
        if #available(macOS 13.0, *) { colorWell.colorWellStyle = .minimal }
        colorWell.toolTip = L("Color")
        NSLayoutConstraint.activate([
            colorWell.widthAnchor.constraint(equalToConstant: 30),
            colorWell.heightAnchor.constraint(equalToConstant: 26)
        ])
        stack.addArrangedSubview(colorWell)

        let pipette = iconButton(symbol: "eyedropper", fallback: "🎨", tip: L("Color picker"),
                                 action: #selector(pickColor(_:)), target: self)
        stack.addArrangedSubview(pipette)

        configureLineWidthButton()
        stack.addArrangedSubview(lineWidthButton)

        return bar
    }

    private func setupCropBar(in content: NSView) {
        cropBar.material = .hudWindow
        cropBar.blendingMode = .withinWindow
        cropBar.wantsLayer = true
        cropBar.layer?.cornerRadius = 10
        cropBar.isHidden = true

        let cancel = NSButton(title: "  \(L("Cancel"))", target: self, action: #selector(cancelCrop(_:)))
        cancel.bezelStyle = .rounded
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) {
            cancel.image = img; cancel.imagePosition = .imageLeading
        }
        let apply = NSButton(title: "  \(L("Apply"))", target: self, action: #selector(applyCrop(_:)))
        apply.bezelStyle = .rounded
        apply.contentTintColor = .controlAccentColor
        if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) {
            apply.image = img; apply.imagePosition = .imageLeading
        }

        let stack = NSStackView(views: [cancel, apply])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        cropBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cropBar.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cropBar.centerYAnchor)
        ])

        let width: CGFloat = 230, height: CGFloat = 40
        cropBar.frame = NSRect(x: (content.bounds.width - width) / 2,
                               y: content.bounds.height - topBarHeight - height - 14, width: width, height: height)
        cropBar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.addSubview(cropBar)
    }

    private func makeStatusBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow

        zoomLabel.font = .systemFont(ofSize: 11)
        zoomLabel.textColor = .secondaryLabelColor
        dimLabel.font = .systemFont(ofSize: 11)
        dimLabel.textColor = .secondaryLabelColor
        dimLabel.alignment = .right

        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        dimLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(zoomLabel)
        bar.addSubview(dimLabel)
        NSLayoutConstraint.activate([
            zoomLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            zoomLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            dimLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            dimLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    // MARK: - Button styling

    private func symbolImage(_ symbol: String, _ tip: String,
                             weight: NSFont.Weight = .semibold, size: CGFloat = 18) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let out = image.withSymbolConfiguration(config)
        out?.isTemplate = true
        return out
    }

    private func baseButton(tip: String) -> HoverButton {
        let b = HoverButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.setButtonType(.momentaryChange)
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.imagePosition = .imageOnly
        b.toolTip = tip
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 40),
            b.heightAnchor.constraint(equalToConstant: 34)
        ])
        return b
    }

    private func toolButton(symbol: String, fallback: String, tag: Int, tip: String) -> NSButton {
        let b = baseButton(tip: tip)
        b.tag = tag
        b.target = self
        b.action = #selector(selectTool(_:))
        if let image = symbolImage(symbol, tip) { b.image = image } else { b.title = fallback }
        b.contentTintColor = .secondaryLabelColor
        return b
    }

    /// Prominent capture control: `filled` = solid accent with white glyph (primary),
    /// otherwise a soft accent-tinted pill (secondary). Used for the centered capture group.
    private func captureButton(symbol: String, fallback: String, tip: String,
                               action: Selector, target: AnyObject?, filled: Bool) -> NSButton {
        let b = baseButton(tip: tip)
        if let image = symbolImage(symbol, tip, weight: .semibold, size: 18) {
            b.image = image
        } else {
            b.title = fallback
        }
        b.target = target
        b.action = action
        if filled {
            b.restingColor = .controlAccentColor
            b.contentTintColor = .white
        } else {
            b.restingColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            b.contentTintColor = .controlAccentColor
        }
        return b
    }

    private func iconButton(symbol: String, fallback: String, tip: String,
                            action: Selector, target: AnyObject?, accent: Bool = false) -> NSButton {
        let b = baseButton(tip: tip)
        b.target = target
        b.action = action
        if let image = symbolImage(symbol, tip) { b.image = image } else { b.title = fallback }
        b.contentTintColor = accent ? .controlAccentColor : .secondaryLabelColor
        return b
    }

    private func configureLineWidthButton() {
        lineWidthButton.isBordered = false
        lineWidthButton.bezelStyle = .regularSquare
        lineWidthButton.setButtonType(.momentaryChange)
        lineWidthButton.wantsLayer = true
        lineWidthButton.layer?.cornerRadius = 10
        lineWidthButton.imagePosition = .imageOnly
        lineWidthButton.toolTip = L("Line width")
        lineWidthButton.target = self
        lineWidthButton.action = #selector(showLineWidthMenu(_:))
        lineWidthButton.image = lineWidthIcon(canvas.currentLineWidth)
        NSLayoutConstraint.activate([
            lineWidthButton.widthAnchor.constraint(equalToConstant: 40),
            lineWidthButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return line
    }

    /// A template image of a rounded horizontal line of the given stroke width.
    private func lineWidthIcon(_ width: CGFloat) -> NSImage {
        let size = NSSize(width: 30, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.labelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 5, y: size.height / 2))
        path.line(to: NSPoint(x: size.width - 5, y: size.height / 2))
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func highlightSelectedTool() {
        for button in toolButtons {
            let on = button.tag == canvas.currentTool.rawValue
            (button as? HoverButton)?.restingColor = on
                ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                : .clear
            button.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        }
    }

    // MARK: - Zoom / status

    private func zoomToFit() {
        let available = scrollView.contentView.bounds.size
        guard canvas.pixelSize.width > 0, canvas.pixelSize.height > 0 else { return }
        let scale = min(available.width / canvas.pixelSize.width,
                        available.height / canvas.pixelSize.height,
                        1.0)
        scrollView.magnification = max(scale, scrollView.minMagnification)
        updateStatus()
    }

    private func updateStatus() {
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded())) %"
        dimLabel.stringValue = "\(Int(canvas.pixelSize.width)) × \(Int(canvas.pixelSize.height)) px"
    }

    // MARK: - Actions

    @objc private func selectTool(_ sender: NSButton) {
        canvas.commitTextEditing()
        canvas.cancelCrop()
        canvas.clearSelection()
        canvas.currentTool = Tool(rawValue: sender.tag) ?? .arrow
        highlightSelectedTool()
        window?.makeFirstResponder(canvas)
    }

    @objc private func applyCrop(_ sender: Any?) { canvas.applyCrop() }
    @objc private func cancelCrop(_ sender: Any?) { canvas.cancelCrop() }

    @objc private func changeColor(_ sender: NSColorWell) {
        canvas.currentColor = sender.color
    }

    @objc private func showLineWidthMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, width) in lineWidths.enumerated() {
            let item = NSMenuItem(title: "", action: #selector(selectLineWidth(_:)), keyEquivalent: "")
            item.image = lineWidthIcon(width)
            item.tag = index
            item.target = self
            if width == canvas.currentLineWidth { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func selectLineWidth(_ sender: NSMenuItem) {
        let index = min(max(sender.tag, 0), lineWidths.count - 1)
        canvas.currentLineWidth = lineWidths[index]
        lineWidthButton.image = lineWidthIcon(canvas.currentLineWidth)
    }

    @objc private func showTimerMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for seconds in AppDelegate.timerPresets {
            let item = NSMenuItem(title: String(format: L("After %d seconds"), seconds),
                                  action: #selector(AppDelegate.newScreenshotTimed(_:)), keyEquivalent: "")
            item.tag = seconds
            item.target = nil // responder chain → AppDelegate
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func magnificationChanged() { updateStatus() }

    @objc private func pickColor(_ sender: Any?) {
        NSColorSampler().show { [weak self] picked in
            guard let self, let picked else { return }
            canvas.currentColor = picked
            colorWell.color = picked
            if let rgb = picked.usingColorSpace(.sRGB) {
                let hex = String(format: "#%02X%02X%02X",
                                 Int((rgb.redComponent * 255).rounded()),
                                 Int((rgb.greenComponent * 255).rounded()),
                                 Int((rgb.blueComponent * 255).rounded()))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
            }
        }
    }

    @objc func undo(_ sender: Any?) { canvas.undo() }
    @objc func redo(_ sender: Any?) { canvas.redo() }

    @objc func copyImage(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([canvas.exportImage()])
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window else { return }
        let size = canvas.pixelSize
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = canvas.exportImage()
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.orientation = size.width >= size.height ? .landscape : .portrait
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        let op = NSPrintOperation(view: imageView, printInfo: info)
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func saveDocument(_ sender: Any?) { save() }

    /// Presents the save sheet. Calls `completion(true)` once the file is written.
    private func save(completion: ((Bool) -> Void)? = nil) {
        guard let window else { completion?(false); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "\(L("Screenshot")).png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { completion?(false); return }
            let ext = url.pathExtension.lowercased()
            let data = (ext == "jpg" || ext == "jpeg") ? canvas.exportJPEGData() : canvas.exportPNGData()
            var ok = false
            if let data { ok = (try? data.write(to: url)) != nil }
            if ok { canvas.isDirty = false }
            completion?(ok)
        }
    }

    @objc func recognizeText(_ sender: Any?) {
        guard let cg = canvas.flattenedCGImage() else { return }
        Recognition.recognizeText(in: cg) { [weak self] text in
            self?.presentRecognition(result: text, emptyMessage: L("No text found"))
        }
    }

    @objc func readQRCode(_ sender: Any?) {
        guard let cg = canvas.flattenedCGImage() else { return }
        presentRecognition(result: Recognition.readQRCode(in: cg) ?? "",
                           emptyMessage: L("No QR code found"))
    }

    private func presentRecognition(result: String, emptyMessage: String) {
        guard let window else { return }
        let alert = NSAlert()
        if result.isEmpty {
            alert.messageText = emptyMessage
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            alert.messageText = L("Copied to clipboard")
            alert.informativeText = result
        }
        alert.beginSheetModal(for: window)
    }

    // MARK: - NSWindowDelegate

    private var forceClose = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forceClose || !canvas.isDirty { return true }
        let alert = NSAlert()
        alert.messageText = L("Save changes before closing?")
        alert.informativeText = L("Your annotations will be lost if you don't save them.")
        alert.addButton(withTitle: L("Save"))         // first = default (rightmost)
        alert.addButton(withTitle: L("Cancel"))       // Esc
        alert.addButton(withTitle: L("Don't Save"))   // leftmost
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: // Save
                self.save { ok in
                    if ok { self.forceClose = true; self.window?.close() }
                }
            case .alertThirdButtonReturn: // Don't Save
                self.forceClose = true
                self.window?.close()
            default:
                break // Cancel: keep the window open
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// A borderless icon button with a subtle hover highlight, for a livelier toolbar.
final class HoverButton: NSButton {
    /// The background shown when the pointer is not over the button
    /// (clear for normal tools, an accent tint when selected/primary).
    var restingColor: NSColor = .clear {
        didSet { if !hovering { layer?.backgroundColor = restingColor.cgColor } }
    }
    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        let hover = restingColor.alphaComponent < 0.05
            ? NSColor.labelColor.withAlphaComponent(0.08)
            : (restingColor.blended(withFraction: 0.15, of: .white) ?? restingColor)
        layer?.backgroundColor = hover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = restingColor.cgColor
    }
}

/// Flipped container so the sidebar's scrollable stack starts at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Keeps the document view centered when it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}
