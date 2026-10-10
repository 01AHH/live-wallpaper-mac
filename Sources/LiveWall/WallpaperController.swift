import Cocoa
import AVFoundation

/// A window that lives behind the desktop icons and never steals focus.
final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where a video of `content` size lands inside `container` for a fill mode.
/// Shared by the real desktop and the in-app display preview, so the preview
/// is exactly what you'll get.
func videoRect(content: CGSize, in container: CGRect, mode: FillMode) -> CGRect {
    guard content.width > 0, content.height > 0 else { return container }
    let sx = container.width / content.width
    let sy = container.height / content.height
    let scale: CGFloat
    switch mode {
    case .stretch: return container
    case .fill:    scale = max(sx, sy)
    case .fit:     scale = min(sx, sy)
    }
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2,
                  width: size.width, height: size.height)
}

extension NSScreen {
    /// A stable identifier for the physical display (survives reboots and
    /// re-plugging), used to remember which wallpaper each screen shows.
    var stableID: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let number = deviceDescription[key] as? CGDirectDisplayID ?? 0
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return String(number)
    }
}

/// Owns the desktop-level windows and the video players. Reads everything it
/// needs from `AppSettings`. Call `apply()` when settings change — layout
/// changes morph in place and new videos cross-fade, with no teardown — and
/// `rebuild()` only when the screens themselves change.
///
/// Each distinct video plays in one *channel* (one player) that feeds every
/// screen showing it: spanning puts all screens on one channel, and screens
/// with their own wallpapers get their own. A channel pauses only when every
/// screen it feeds is hidden, so a fullscreen app on one display pauses just
/// that display's wallpaper.
final class WallpaperController {
    private final class Channel {
        let url: URL?
        let player: AVQueuePlayer?
        let looper: AVPlayerLooper?

        init(url: URL?) {
            self.url = url
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                player = nil
                looper = nil
                return
            }
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            self.player = player
        }
    }

    private struct Surface {
        let window: WallpaperWindow
        let screen: NSScreen
        let id: String
        var layer: CALayer?
        var channelURL: URL??          // nil = nothing shown yet
        var isVisible = true
    }

    private var surfaces: [Surface] = []
    private var channels: [URL?: Channel] = [:]
    private var readyObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var displaysAsleep = false
    private var pendingVisibilityCheck: DispatchWorkItem?

    /// Paused by the person (from the Dynamic Island or menu), independent of
    /// the automatic visibility pausing.
    var userPaused = false {
        didSet { if userPaused != oldValue { updateRates(); reportPlayback() } }
    }

    /// Why playback is currently stopped, or nil while it's playing.
    enum PauseReason { case user, hidden, displaysAsleep, battery, lowPower, hot }

    /// Set from the power rules (battery, Low Power Mode, heat), or nil.
    var powerPause: PauseReason? {
        didSet { if powerPause != oldValue { updateRates(); reportPlayback() } }
    }

    /// Reasons that stop every screen at once.
    private var globalPause: PauseReason? {
        if userPaused { return .user }
        if displaysAsleep { return .displaysAsleep }
        return powerPause
    }

    /// Why nothing is playing, or nil while at least one screen plays.
    var pauseReason: PauseReason? {
        if let globalPause { return globalPause }
        if !surfaces.isEmpty && !surfaces.contains(where: \.isVisible) { return .hidden }
        return nil
    }

    /// Called whenever playback starts or stops, with the reason it stopped.
    var onPlaybackChange: ((PauseReason?) -> Void)?
    private var lastReported: PauseReason??
    private func reportPlayback() {
        let reason = pauseReason
        guard lastReported == nil || lastReported! != reason else { return }
        lastReported = reason
        onPlaybackChange?(reason)
    }

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings

        // Occlusion covers fullscreen Spaces and covering windows; Space
        // switches are re-checked too, since that's when it usually changes.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refreshVisibility),
                           name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(refreshVisibility),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displaysDidSleep),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displaysDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    // MARK: - Visibility

    @objc private func displaysDidSleep() {
        displaysAsleep = true
        refreshVisibility()
    }

    @objc private func displaysDidWake() {
        displaysAsleep = false
        refreshVisibility()
    }

    /// Occlusion flickers for a few hundred milliseconds while windows and
    /// Spaces settle, so act only once it has held steady.
    @objc private func refreshVisibility() {
        pendingVisibilityCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.applyVisibility() }
        pendingVisibilityCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }

    private func applyVisibility() {
        var changed = false
        for i in surfaces.indices {
            let visible = surfaces[i].window.occlusionState.contains(.visible)
            if visible != surfaces[i].isVisible {
                surfaces[i].isVisible = visible
                changed = true
                NSLog("LiveWall: \(surfaces[i].screen.localizedName) \(visible ? "visible — resuming" : "hidden — pausing")")
            }
        }
        guard changed else { return }
        updateRates()
        reportPlayback()
    }

    func rebuild() {
        teardown()
        let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        surfaces = NSScreen.screens.map { screen in
            let win = makeWindow(for: screen, level: desktopLevel)
            win.orderFront(nil)
            return Surface(window: win, screen: screen, id: screen.stableID)
        }
        apply(animated: false)
        refreshVisibility()
    }

    // MARK: - Applying settings

    /// The video a screen should show right now.
    private func desiredVideo(for surface: Surface) -> URL? {
        settings.spanScreens ? settings.currentVideo : settings.video(forScreen: surface.id)
    }

    /// Bring the desktop in line with the current settings.
    func apply(animated: Bool = true) {
        // Channels for every video that should be on screen; reuse the ones
        // already playing so unchanged screens don't restart.
        let wanted = Set(surfaces.map { desiredVideo(for: $0) })
        for url in wanted where channels[url] == nil {
            channels[url] = Channel(url: url)
        }

        for i in surfaces.indices {
            let url = desiredVideo(for: surfaces[i])
            if surfaces[i].channelURL != .some(url) {
                attach(channels[url]!, to: i, animated: animated && surfaces[i].layer != nil)
            }
        }
        layout(animated: animated)

        // Drop channels no screen uses any more (their layers fade out first).
        for url in channels.keys where !wanted.contains(url) {
            let channel = channels.removeValue(forKey: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { channel?.player?.pause() }
        }
        updateRates()
        reportPlayback()

        let summary = surfaces.map { "\($0.screen.localizedName)=\(desiredVideo(for: $0)?.lastPathComponent ?? "gradient")" }
        NSLog("LiveWall: span=\(settings.spanScreens), mode=\(settings.fillMode.rawValue), \(summary.joined(separator: ", "))")
    }

    // MARK: - Layout

    private var gravity: AVLayerVideoGravity {
        switch settings.fillMode {
        case .fill:    return .resizeAspectFill
        case .fit:     return .resizeAspect
        case .stretch: return .resize
        }
    }

    /// The player layer's frame within a screen's window.
    private func frame(for screen: NSScreen) -> CGRect {
        guard settings.spanScreens else { return CGRect(origin: .zero, size: screen.frame.size) }
        // One continuous canvas across all screens, positioned so each window
        // shows its own slice of it.
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGRect(x: union.minX - screen.frame.minX, y: union.minY - screen.frame.minY,
                      width: union.width, height: union.height)
    }

    private func layout(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.7 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.1, 1))
        CATransaction.setDisableActions(!animated)
        for surface in surfaces {
            guard let layer = surface.layer as? AVPlayerLayer else { continue }
            layer.frame = frame(for: surface.screen)
            layer.videoGravity = gravity
        }
        CATransaction.commit()
    }

    // MARK: - Switching a screen's video

    /// Point one screen at a channel. With `animated`, the new video fades in
    /// over the old one once its first frame is ready — never a black flash.
    private func attach(_ channel: Channel, to index: Int, animated: Bool) {
        let content = surfaces[index].window.contentView!
        let oldLayer = surfaces[index].layer

        let layer: CALayer
        if let player = channel.player {
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = gravity
            playerLayer.frame = frame(for: surfaces[index].screen)
            layer = playerLayer
        } else {
            layer = makeGradient(bounds: content.bounds)   // no video selected → visible fallback
        }
        layer.opacity = animated ? 0 : 1
        content.layer?.addSublayer(layer)
        surfaces[index].layer = layer
        surfaces[index].channelURL = .some(channel.url)

        guard animated else { oldLayer?.removeFromSuperlayer(); return }

        let fadeIn = {
            CATransaction.begin()
            CATransaction.setCompletionBlock { oldLayer?.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.9
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.opacity = 1
            layer.add(fade, forKey: "crossfade")
            CATransaction.commit()
        }
        // Wait for a real frame before fading, so we never fade in black.
        if let playerLayer = layer as? AVPlayerLayer, !playerLayer.isReadyForDisplay {
            let key = ObjectIdentifier(playerLayer)
            readyObservers[key] = playerLayer.observe(\.isReadyForDisplay) { [weak self] observed, _ in
                guard observed.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    self?.readyObservers[key] = nil
                    fadeIn()
                }
            }
        } else {
            fadeIn()
        }
    }

    /// Play each channel at its video's speed while any screen it feeds is
    /// visible. `defaultRate` makes a player resume at that speed after
    /// loops and stalls, not snap back to 1×.
    private func updateRates() {
        let global = globalPause
        for channel in channels.values {
            guard let player = channel.player else { continue }
            let rate = Float(settings.speed(for: channel.url))
            let seen = surfaces.contains { $0.channelURL == .some(channel.url) && $0.isVisible }
            player.defaultRate = rate
            player.rate = (global == nil && seen) ? rate : 0
        }
    }

    // MARK: - Building blocks

    private func makeWindow(for screen: NSScreen, level: NSWindow.Level) -> WallpaperWindow {
        let win = WallpaperWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
        win.level = level
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.isOpaque = true
        win.backgroundColor = .black
        win.setFrame(screen.frame, display: true)

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layerContentsRedrawPolicy = .duringViewResize
        win.contentView = content
        return win
    }

    private func makeGradient(bounds: CGRect) -> CALayer {
        let grad = CAGradientLayer()
        grad.frame = bounds
        grad.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        grad.colors = [NSColor.systemPurple.cgColor, NSColor.systemBlue.cgColor, NSColor.systemTeal.cgColor]

        let anim = CABasicAnimation(keyPath: "colors")
        anim.toValue = [NSColor.systemTeal.cgColor, NSColor.systemPink.cgColor, NSColor.systemIndigo.cgColor]
        anim.duration = 6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        grad.add(anim, forKey: "colorShift")
        return grad
    }

    private func teardown() {
        readyObservers.removeAll()
        surfaces.forEach { $0.window.orderOut(nil) }
        surfaces.removeAll()
        channels.values.forEach { $0.player?.pause() }
        channels.removeAll()
        lastReported = nil
    }
}
