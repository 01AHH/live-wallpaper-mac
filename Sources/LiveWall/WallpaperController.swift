import Cocoa
import AVFoundation

/// A window that lives behind the desktop icons and never steals focus.
final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the desktop-level windows and the shared video player. Reads everything
/// it needs from `AppSettings`; call `rebuild()` whenever settings or screens change.
final class WallpaperController {
    private var windows: [WallpaperWindow] = []
    private var loopers: [AVPlayerLooper] = []
    private var players: [AVQueuePlayer] = []
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func rebuild() {
        teardown()

        let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }

        // One shared player keeps every screen's layer perfectly in sync.
        let sharedPlayer = makePlayer(for: settings.currentVideo)
        let gravity: AVLayerVideoGravity = settings.fillMode == .fill ? .resizeAspectFill : .resizeAspect

        for screen in NSScreen.screens {
            let win = makeWindow(for: screen, level: desktopLevel)
            let content = win.contentView!

            if let sharedPlayer {
                let layer = AVPlayerLayer(player: sharedPlayer)
                layer.videoGravity = gravity
                layer.frame = settings.spanScreens
                    ? CGRect(x: unionFrame.minX - screen.frame.minX,
                             y: unionFrame.minY - screen.frame.minY,
                             width: unionFrame.width,
                             height: unionFrame.height)   // continuous across all screens
                    : content.bounds                       // each screen shows the full clip
                content.layer?.addSublayer(layer)
            } else {
                attachGradient(to: content)               // no video selected → visible fallback
            }

            win.orderFront(nil)
            windows.append(win)
        }

        sharedPlayer?.play()
        NSLog("LiveWall: \(windows.count) screen(s), span=\(settings.spanScreens), mode=\(settings.fillMode.rawValue), source=\(settings.currentVideo?.lastPathComponent ?? "gradient")")
    }

    // MARK: - Building blocks

    private func makePlayer(for url: URL?) -> AVQueuePlayer? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let player = AVQueuePlayer()
        player.isMuted = true
        loopers.append(AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url)))
        players.append(player)
        return player
    }

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

    private func attachGradient(to view: NSView) {
        let grad = CAGradientLayer()
        grad.frame = view.bounds
        grad.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        grad.colors = [NSColor.systemPurple.cgColor, NSColor.systemBlue.cgColor, NSColor.systemTeal.cgColor]
        view.layer?.addSublayer(grad)

        let anim = CABasicAnimation(keyPath: "colors")
        anim.toValue = [NSColor.systemTeal.cgColor, NSColor.systemPink.cgColor, NSColor.systemIndigo.cgColor]
        anim.duration = 6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        grad.add(anim, forKey: "colorShift")
    }

    private func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        loopers.removeAll()
        players.removeAll()
    }
}
