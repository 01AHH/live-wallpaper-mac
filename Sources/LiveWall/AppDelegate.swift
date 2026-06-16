import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var controller = WallpaperController(settings: settings)
    private var statusItem: NSStatusItem!
    private var controlWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.rebuild()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        setupStatusItem()
        showControls(nil)   // open the panel on launch
    }

    @objc private func screensChanged() {
        controller.rebuild()
    }

    /// Re-launching an already-running menu-bar app (double-click in Finder,
    /// clicking the Dock/Launchpad icon) sends this instead of a fresh launch.
    /// Reopen and de-minimize the control window rather than appearing to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls(nil)
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "LiveWall")

        let menu = NSMenu()
        let controls = NSMenuItem(title: "Wallpaper Controls…",
                                  action: #selector(showControls(_:)), keyEquivalent: ",")
        controls.target = self
        menu.addItem(controls)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiveWall",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showControls(_ sender: Any?) {
        if controlWindow == nil {
            let root = ControlPanelView(settings: settings) { [weak self] in
                self?.controller.rebuild()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "LiveWall"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 560))
            window.center()
            window.isReleasedWhenClosed = false
            controlWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if controlWindow?.isMiniaturized == true {
            controlWindow?.deminiaturize(nil)
        }
        controlWindow?.makeKeyAndOrderFront(nil)
    }
}
