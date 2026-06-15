import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; lives in the menu bar
let delegate = AppDelegate()
app.delegate = delegate
app.run()
