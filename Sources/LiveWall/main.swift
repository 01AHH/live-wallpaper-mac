import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; lives in the menu bar
// Top-level code runs on the main thread; say so for the main-actor delegate.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
