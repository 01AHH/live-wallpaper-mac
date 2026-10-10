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
    private let gallery = GalleryStore()
    private var menuActions: [MenuAction] = []

    private var onboardingWindow: NSWindow?
    /// Escape hatches for the welcome: a key monitor and app-activation
    /// observers, removed when it closes.
    private var onboardingKeyMonitor: Any?
    private var onboardingObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened from the .dmg or Downloads: offer to move into Applications
        // and relaunch from there.
        if ApplicationsMover.moveIfNeeded() { return }

        controller.rebuild()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        setupStatusItem()
        setupIsland()
        setupPowerRules()
        enableLaunchAtLoginOnFirstRun()
        if settings.hasOnboarded {
            showControls(nil)   // open the panel on launch
        } else {
            showWelcome()
        }
    }

    // MARK: - Welcome

    /// The full-screen first-run welcome (also replayable from the menu bar).
    func showWelcome() {
        guard onboardingWindow == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        island?.isShown = false   // the welcome covers the whole screen
        let view = OnboardingView(
            settings: settings, gallery: gallery,
            onChooseWallpaper: { [weak self] wallpaper, done in self?.chooseFirstWallpaper(wallpaper, done: done) },
            onOpenControls: { [weak self] in self?.showControls(nil) },
            onFinish: { [weak self] in self?.closeWelcome() })
        let window = OnboardingWindow(contentRect: screen.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        window.level = .statusBar
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentView = FirstMouseHostingView(rootView: view)
        window.setFrame(screen.frame, display: true)
        window.alphaValue = 0
        onboardingWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.6; window.animator().alphaValue = 1 }
        installWelcomeEscapeHatches(window)
    }

    /// However the welcome gets stuck, there's always a way out. LiveWall has
    /// no app menu, so ⌘Q does nothing on its own — catch Esc, ⌘Q, ⌘W and
    /// ⌘. here, before SwiftUI's focus gets a say. And when another app comes
    /// forward (a link opened in the browser, ⌘-Tab), drop the welcome to an
    /// ordinary window so it can't trap the screen.
    private func installWelcomeEscapeHatches(_ window: NSWindow) {
        onboardingKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let command = event.modifierFlags.contains(.command)
            let key = event.charactersIgnoringModifiers?.lowercased()
            let escape = event.keyCode == 53
            guard escape || (command && ["q", "w", "."].contains(key)) else { return event }
            self?.settings.hasOnboarded = true
            self?.closeWelcome()
            return nil
        }
        let center = NotificationCenter.default
        onboardingObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { window.level = .normal }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    window.level = .statusBar
                    window.makeKeyAndOrderFront(nil)
                }
            },
        ]
    }

    private func closeWelcome() {
        guard let window = onboardingWindow else { return }
        onboardingWindow = nil
        if let onboardingKeyMonitor { NSEvent.removeMonitor(onboardingKeyMonitor) }
        onboardingKeyMonitor = nil
        onboardingObservers.forEach(NotificationCenter.default.removeObserver)
        onboardingObservers = []
        // Stop taking clicks straight away, so even a fade that never
        // completes can't leave an invisible wall over the screen.
        window.ignoresMouseEvents = true
        var closed = false
        let tearDown = { [weak self] in
            guard !closed else { return }
            closed = true
            window.orderOut(nil)
            window.contentView = nil   // stops the background video
            self?.island?.isShown = self?.settings.showIsland ?? true
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; window.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { tearDown() } })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { tearDown() } }
    }

    /// Download a gallery wallpaper into the library and put it on every
    /// display, so the welcome's background and the desktop both show it.
    private func chooseFirstWallpaper(_ wallpaper: GalleryWallpaper, done: @escaping (URL?) -> Void) {
        let folder = settings.libraryFolder ?? AppSettings.defaultLibrary()
        if settings.libraryFolder == nil { settings.libraryFolder = folder }
        let existing = folder.appendingPathComponent(wallpaper.fileName)
        let use = { [weak self] (file: URL) in
            guard let self else { return }
            settings.setVideo(file, forScreen: nil)
            controller.apply()
            done(file)
        }
        if FileManager.default.fileExists(atPath: existing.path) { use(existing); return }
        gallery.download(wallpaper, into: folder) { [weak self] result in
            guard let self, case .success(let file) = result else { done(nil); return }
            let categories = CategoryStore()
            categories.load(folder: folder)
            for tag in wallpaper.tags {
                let name = categories.addTag(tag) ?? tag
                if !categories.has(name, file) { categories.toggle(name, for: file) }
            }
            gallery.recordDownload(wallpaper)
            use(file)
        }
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
                // Watching Claude app chats needs Accessibility permission; ask
                // once, when that source is turned on. (ChatGPT works from its
                // session logs, and only uses Accessibility if already allowed.)
                if sources.contains(.claudeApp) && !ChatAppWatcher.isTrusted {
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

    // MARK: - Adding wallpapers from the website

    /// Handles `livewall://add?ids=a,b,c` links from the online gallery's
    /// "Add to LiveWall" buttons: download each wallpaper into the library,
    /// with its tags, and start the first one if nothing is playing.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "livewall" && url.host == "add" {
            let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ids" || $0.name == "id" }?.value?
                .split(separator: ",").map(String.init) ?? []
            Task { await addFromGallery(ids) }
        }
    }

    private func addFromGallery(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        let folder = settings.libraryFolder ?? AppSettings.defaultLibrary()
        if settings.libraryFolder == nil { settings.libraryFolder = folder }

        await gallery.load()
        let wanted = ids.compactMap { id in gallery.wallpapers.first { $0.id == id } }
        let model = island?.model
        guard !wanted.isEmpty else {
            model?.announce(IslandEvent(icon: "exclamationmark.triangle.fill",
                                        title: "Couldn't find those wallpapers", subtitle: "Online Gallery"))
            return
        }

        // Skip anything already in the library.
        let toFetch = wanted.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        model?.announce(IslandEvent(icon: "arrow.down.circle.fill",
                                    title: toFetch.isEmpty ? "Already in your library"
                                        : toFetch.count == 1 ? "Adding \(toFetch[0].title)…" : "Adding \(toFetch.count) wallpapers…",
                                    subtitle: "Online Gallery", duration: 4))

        let categories = CategoryStore()
        categories.load(folder: folder)
        var added: [URL] = []
        for wallpaper in toFetch {
            let file: URL? = await withCheckedContinuation { continuation in
                gallery.download(wallpaper, into: folder) { result in
                    continuation.resume(returning: try? result.get())
                }
            }
            guard let file else { continue }
            for tag in wallpaper.tags {
                let name = categories.addTag(tag) ?? tag
                if !categories.has(name, file) { categories.toggle(name, for: file) }
            }
            added.append(file)
            model?.announce(IslandEvent(icon: "checkmark.circle.fill", title: wallpaper.title,
                                        subtitle: "Added to your library", duration: 2.5))
        }

        // One chosen wallpaper: play it. Several: start one only if nothing's playing.
        let first = wanted.first.map { folder.appendingPathComponent($0.fileName) }
        let nothingPlaying = settings.currentVideo.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        if let first, wanted.count == 1 || nothingPlaying, FileManager.default.fileExists(atPath: first.path) {
            settings.currentVideo = first
            controller.apply()
        }
        if added.count > 1 {
            model?.announce(IslandEvent(icon: "checkmark.circle.fill", title: "\(added.count) wallpapers added",
                                        subtitle: "Online Gallery", duration: 3))
        }
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
        menu.addItem(item("Show Welcome…") { [weak self] in self?.showWelcome() })
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
            let root = ControlPanelView(settings: settings, gallery: gallery) { [weak self] in
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
