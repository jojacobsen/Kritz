import AppKit
import Carbon.HIToolbox

/// One system-wide hot key, registered via the Carbon Hot Key API. This works from any
/// app without the Accessibility permission (unlike an `NSEvent` global monitor) and
/// fires `action` on the main thread when pressed. To change the key, replace the
/// instance (deinit unregisters the old one first).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void
    private static let signature = OSType(0x4B525A54) // 'KRZT'
    private let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: 1)

    /// `keyCode` is a virtual key code; `carbonModifiers` is an OR of cmdKey/shiftKey/…
    /// Returns nil if the handler can't be installed or the combo can't be registered
    /// (e.g. it's reserved by the system).
    init?(keyCode: UInt32, carbonModifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var firedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            if firedID.signature == GlobalHotKey.signature {
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                me.action()   // Carbon dispatches on the main run loop
            }
            return noErr
        }, 1, &eventType, userData, &eventHandler)
        guard installStatus == noErr else { return nil }

        let registerStatus = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID,
                                                 GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr, hotKeyRef != nil else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

/// A recorded keyboard shortcut (virtual key code + modifiers), with persistence and a
/// Mac-style display string. Stored in UserDefaults so it survives relaunches.
struct HotKeyShortcut: Equatable {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    /// Glyph/label for the key (e.g. "2", "A", "←"), captured when recorded.
    let keyLabel: String

    /// The default shortcut applied on first launch: ⇧⌘2 (next to the macOS
    /// screenshot shortcuts ⇧⌘3/4/5, which are reserved).
    static let `default` = HotKeyShortcut(keyCode: UInt16(kVK_ANSI_2),
                                          modifierFlags: [.command, .shift],
                                          keyLabel: "2")

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifierFlags.contains(.command) { m |= UInt32(cmdKey) }
        if modifierFlags.contains(.shift)   { m |= UInt32(shiftKey) }
        if modifierFlags.contains(.option)  { m |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// e.g. "⇧⌘2". Order matches Apple's menu convention (⌃⌥⇧⌘).
    var displayString: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option)  { s += "⌥" }
        if modifierFlags.contains(.shift)   { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    // MARK: - Build from an event

    /// Builds a shortcut from a key-down event, requiring at least one of ⌘/⌥/⌃ (a bare
    /// key or Shift-only combo is rejected as a global hot key). Returns nil otherwise.
    static func from(event: NSEvent) -> HotKeyShortcut? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.contains(.command) || mods.contains(.option) || mods.contains(.control) else {
            return nil
        }
        return HotKeyShortcut(keyCode: event.keyCode, modifierFlags: mods,
                              keyLabel: label(for: event))
    }

    private static func label(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        let chars = event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "key \(event.keyCode)" : chars.uppercased()
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "⏎", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "␣",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Help: "?⃝",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    // MARK: - Persistence

    private static let configuredKey = "GlobalCaptureHotKey.configured"
    private static let keyCodeKey = "GlobalCaptureHotKey.keyCode"
    private static let modifiersKey = "GlobalCaptureHotKey.modifiers"
    private static let labelKey = "GlobalCaptureHotKey.label"

    /// The stored shortcut, or nil if the user cleared it. On first launch (nothing
    /// stored yet) the default is installed and returned.
    static var stored: HotKeyShortcut? {
        let d = UserDefaults.standard
        guard d.bool(forKey: configuredKey) else {
            HotKeyShortcut.default.save()
            return .default
        }
        let code = d.integer(forKey: keyCodeKey)
        guard code >= 0 else { return nil } // explicitly cleared
        let mods = NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: modifiersKey)))
        let label = d.string(forKey: labelKey) ?? ""
        return HotKeyShortcut(keyCode: UInt16(code), modifierFlags: mods, keyLabel: label)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(true, forKey: Self.configuredKey)
        d.set(Int(keyCode), forKey: Self.keyCodeKey)
        d.set(Int(modifierFlags.rawValue), forKey: Self.modifiersKey)
        d.set(keyLabel, forKey: Self.labelKey)
    }

    /// Records that the user cleared the shortcut (so the default isn't re-applied).
    static func clearStored() {
        let d = UserDefaults.standard
        d.set(true, forKey: configuredKey)
        d.set(-1, forKey: keyCodeKey)
    }
}
