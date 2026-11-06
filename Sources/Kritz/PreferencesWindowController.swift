import AppKit
import Carbon.HIToolbox

/// A click-to-record control for a keyboard shortcut. Click it, then press the desired
/// combo (at least one of ⌘/⌥/⌃). Esc cancels recording; Delete/Backspace clears.
final class HotKeyRecorderView: NSView {
    var shortcut: HotKeyShortcut? { didSet { updateTitle() } }
    var onChange: ((HotKeyShortcut?) -> Void)?

    private let button = NSButton()
    private var monitor: Any?
    private var isRecording = false { didSet { updateTitle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { stopRecording() }

    private func updateTitle() {
        if isRecording {
            button.title = L("Type shortcut…")
        } else {
            button.title = shortcut?.displayString ?? L("Click to record shortcut")
        }
    }

    @objc private func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil // swallow the event while recording
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording() // cancel, keep the current shortcut
        case kVK_Delete, kVK_ForwardDelete:
            shortcut = nil
            onChange?(nil)
            stopRecording()
        default:
            guard let recorded = HotKeyShortcut.from(event: event) else {
                NSSound.beep() // needs at least one of ⌘/⌥/⌃
                return
            }
            shortcut = recorded
            onChange?(recorded)
            stopRecording()
        }
    }
}

/// A small Settings window; currently just the global capture shortcut.
final class PreferencesWindowController: NSWindowController {
    /// Called whenever the stored shortcut changes, so the app can re-register it.
    var onShortcutChange: ((HotKeyShortcut?) -> Void)?

    private let recorder = HotKeyRecorderView(frame: .zero)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        recorder.shortcut = HotKeyShortcut.stored
        recorder.onChange = { [weak self] shortcut in
            if let shortcut { shortcut.save() } else { HotKeyShortcut.clearStored() }
            self?.onShortcutChange?(shortcut)
        }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let label = NSTextField(labelWithString: L("Global capture shortcut:"))
        let clear = NSButton(title: L("Clear"), target: self, action: #selector(clearShortcut))
        clear.bezelStyle = .rounded
        let caption = NSTextField(wrappingLabelWithString:
            L("Press this shortcut from any app to start a capture."))
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor

        for v in [label, recorder, clear, caption] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),

            recorder.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            recorder.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            clear.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 8),
            clear.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            clear.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            caption.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            caption.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
        ])
    }

    @objc private func clearShortcut() {
        recorder.shortcut = nil
        HotKeyShortcut.clearStored()
        onShortcutChange?(nil)
    }
}
