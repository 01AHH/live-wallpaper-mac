import Cocoa
import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var controller = WallpaperController(settings: settings)
    private var statusItem: NSStatusItem!
    private var controlWindow: NSWindow?
    private var island: DynamicIslandController?
    private var subscriptions: Set<AnyCancellable> = []
    private let power = PowerMonitor()
    private var menuActions: [MenuAction] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.rebuild()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        setupStatusItem()
        setupIsland()
        setupPowerRules()
        enableLaunchAtLoginOnFirstRun()
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

    // MARK: - Launch at login

    /// A wallpaper app should be there when the Mac starts, so turn launch at
    /// login on the first time LiveWall runs; after that it's the person's
    /// choice (menu bar, or System Settings → General → Login Items).
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetUpLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Only an installed app bundle can register; a dev build would fail.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("LiveWall: launch at login change failed: \(error)")
        }
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

    // MARK: - Power rules

    private func setupPowerRules() {
        power.onChange = { [weak self] in self?.applyPowerRules() }
        // @Published fires before the value changes, so apply on the next turn.
        Publishers.Merge3(settings.$pauseOnBattery, settings.$pauseInLowPower, settings.$pauseWhenHot)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyPowerRules() } }
            .store(in: &subscriptions)
    }

    /// Heat wins over Low Power Mode, which wins over battery, so the reason
    /// shown is the most pressing one.
    private func applyPowerRules() {
        if settings.pauseWhenHot && power.isHot {
            controller.powerPause = .hot
        } else if settings.pauseInLowPower && power.isLowPowerMode {
            controller.powerPause = .lowPower
        } else if settings.pauseOnBattery && power.isOnBattery {
            controller.powerPause = .battery
        } else {
            controller.powerPause = nil
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "LiveWall")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Quick controls, rebuilt each time the menu opens so names, checkmarks
    /// and the pause state are always current.
    fileprivate func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menuActions.removeAll()

        let name = settings.currentVideo?.wallpaperName ?? "No wallpaper"
        let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let reason = controller.pauseReason {
            header.title = "\(name) — \(Self.describe(reason))"
        }
        menu.addItem(header)

        let paused = controller.userPaused
        menu.addItem(item(paused ? "Resume Wallpaper" : "Pause Wallpaper", key: "p") { [weak self] in
            self?.controller.userPaused.toggle()
        })
        menu.addItem(item("Next Wallpaper", key: "n") { [weak self] in self?.shuffle() })

        let speedMenu = NSMenu()
        let current = settings.speed(for: settings.currentVideo)
        for speed in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5] {
            speedMenu.addItem(item(speed.formatted(.number.precision(.fractionLength(0...2))) + "×",
                                   checked: abs(speed - current) < 0.001) { [weak self] in
                guard let self, let url = settings.currentVideo else { return }
                settings.setSpeed(speed, for: url)
            })
        }
        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)

        menu.addItem(.separator())
        menu.addItem(item("Wallpaper Controls…", key: ",") { [weak self] in self?.showControls(nil) })
        menu.addItem(item("Show Dynamic Island", checked: settings.showIsland) { [weak self] in
            self?.settings.showIsland.toggle()
        })

        let powerMenu = NSMenu()
        powerMenu.addItem(item("Pause on Battery", checked: settings.pauseOnBattery) { [weak self] in
            self?.settings.pauseOnBattery.toggle()
        })
        powerMenu.addItem(item("Pause in Low Power Mode", checked: settings.pauseInLowPower) { [weak self] in
            self?.settings.pauseInLowPower.toggle()
        })
        powerMenu.addItem(item("Pause When Mac Is Hot", checked: settings.pauseWhenHot) { [weak self] in
            self?.settings.pauseWhenHot.toggle()
        })
        powerMenu.addItem(.separator())
        let now = [power.isOnBattery ? "on battery" : "plugged in",
                   power.isLowPowerMode ? "Low Power Mode" : nil,
                   power.isHot ? "running hot" : nil].compactMap { $0 }.joined(separator: ", ")
        let status = NSMenuItem(title: "Now: " + now, action: nil, keyEquivalent: "")
        status.isEnabled = false
        powerMenu.addItem(status)
        let powerItem = NSMenuItem(title: "Power Saving", action: nil, keyEquivalent: "")
        powerItem.submenu = powerMenu
        menu.addItem(powerItem)

        menu.addItem(item("Launch at Login", checked: SMAppService.mainApp.status == .enabled) { [weak self] in
            self?.toggleLaunchAtLogin(nil)
        })

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiveWall",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, key: String = "", checked: Bool? = nil,
                      _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        menuActions.append(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
        item.target = action
        if let checked { item.state = checked ? .on : .off }
        return item
    }

    private static func describe(_ reason: WallpaperController.PauseReason) -> String {
        switch reason {
        case .user:           return "Paused"
        case .hidden:         return "Paused while covered"
        case .displaysAsleep: return "Paused, displays asleep"
        case .battery:        return "Paused on battery"
        case .lowPower:       return "Paused in Low Power Mode"
        case .hot:            return "Paused while cooling down"
        }
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

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}

/// Lets a menu item run a closure.
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
