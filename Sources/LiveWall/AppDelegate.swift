import Cocoa
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var controller = WallpaperController(settings: settings)
    private var statusItem: NSStatusItem!
    private var controlWindow: NSWindow?
    private var island: DynamicIslandController?
    private var islandMenuItem: NSMenuItem?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.rebuild()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        setupStatusItem()
        setupIsland()
        showControls(nil)   // open the panel on launch
    }

    // MARK: - Dynamic Island

    private func setupIsland() {
        let island = DynamicIslandController(settings: settings)
        self.island = island
        let model = island.model

        model.onTogglePause = { [weak self] in
            guard let self else { return }
            controller.userPaused.toggle()
        }
        model.onShuffle = { [weak self] in self?.shuffle() }
        model.onOpenControls = { [weak self] in self?.showControls(nil) }

        controller.onPlaybackChange = { [weak model] reason in
            guard let model else { return }
            let wasUserPaused = model.pauseReason == .user
            model.pauseReason = reason
            // Only announce what the person did. Automatic pauses (a fullscreen
            // app, displays sleeping) change the icon quietly rather than
            // popping up over whatever they're doing.
            if reason == .user {
                model.announce(IslandEvent(icon: "pause.fill", title: "Wallpaper paused"))
            } else if wasUserPaused && reason == nil {
                model.announce(IslandEvent(icon: "play.fill", title: "Wallpaper playing"))
            }
        }

        // @Published publishes before the property changes, so use the value
        // handed to the sink rather than reading settings back.
        settings.$currentVideo
            .removeDuplicates()
            .sink { [weak model] url in
                guard let model, let url else { return }
                Task { @MainActor in
                    model.poster = await ThumbnailCache.image(for: url)
                    model.announce(IslandEvent(icon: "play.rectangle.fill", title: url.wallpaperName,
                                               subtitle: "Now playing"))
                }
            }
            .store(in: &subscriptions)

        settings.$speeds
            .dropFirst()
            .sink { [weak self, weak model] speeds in
                guard let self, let model, let url = settings.currentVideo else { return }
                let speed = speeds[url.lastPathComponent] ?? 1
                model.announce(IslandEvent(
                    icon: speed < 1 ? "tortoise.fill" : speed > 1 ? "hare.fill" : "speedometer",
                    title: "Speed " + speed.formatted(.number.precision(.fractionLength(0...2))) + "×",
                    subtitle: url.wallpaperName, duration: 1.5))
                // The island's speed menu changes settings directly.
                DispatchQueue.main.async { self.controller.apply() }
            }
            .store(in: &subscriptions)

        settings.$islandSources
            .sink { [weak self] sources in
                self?.island?.setSources(sources)
                // Watching the chat apps needs Accessibility permission; ask
                // once, when a source that needs it is on.
                if !sources.isDisjoint(with: [.chatGPT, .claudeApp]) && !ChatAppWatcher.isTrusted {
                    self?.requestAccessibilityOnce()
                }
            }
            .store(in: &subscriptions)

        settings.$showIsland
            .sink { [weak self] show in
                self?.island?.isShown = show
                self?.islandMenuItem?.state = show ? .on : .off
            }
            .store(in: &subscriptions)
    }

    /// A random wallpaper from the library, other than the current one.
    private func shuffle() {
        guard let folder = settings.libraryFolder,
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        let exts: Set<String> = ["mp4", "mov", "m4v"]
        let pool = items.filter { exts.contains($0.pathExtension.lowercased()) && $0 != settings.currentVideo }
        guard let next = pool.randomElement() else { return }
        settings.currentVideo = next
        controller.apply()
    }

    private func requestAccessibilityOnce() {
        let key = "askedForAccessibility"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        ChatAppWatcher.requestPermission()
    }

    @objc private func toggleIsland(_ sender: Any?) {
        settings.showIsland.toggle()
    }

    @objc private func screensChanged() {
        controller.rebuild()
        island?.screensChanged()
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
        let islandItem = NSMenuItem(title: "Show Dynamic Island",
                                    action: #selector(toggleIsland(_:)), keyEquivalent: "")
        islandItem.target = self
        islandItem.state = settings.showIsland ? .on : .off
        islandMenuItem = islandItem
        menu.addItem(islandItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiveWall",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showControls(_ sender: Any?) {
        if controlWindow == nil {
            let root = ControlPanelView(settings: settings) { [weak self] in
                self?.controller.apply()
            }
            let hosting = NSHostingController(rootView: root)
            // Let SwiftUI's .toolbar, .searchable and title reach the window.
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.title = "LiveWall"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.setFrameAutosaveName("LiveWallControls")
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
