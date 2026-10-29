import AppKit

// Entry point. Kept tiny on purpose – all logic lives in AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
