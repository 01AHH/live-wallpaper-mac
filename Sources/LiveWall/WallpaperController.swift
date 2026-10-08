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

/// Owns the desktop-level windows and the shared video player. Reads everything
/// it needs from `AppSettings`. Call `apply()` when settings change — layout
/// changes morph in place and new videos cross-fade, with no teardown — and
/// `rebuild()` only when the screens themselves change.
final class WallpaperController {
    private struct Surface {
        let window: WallpaperWindow
        let screen: NSScreen
        var layer: CALayer?
    }

    private var surfaces: [Surface] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?
    private var hasLoaded = false
    private var readyObservers: [NSKeyValueObservation] = []
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func rebuild() {
        teardown()
        let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        surfaces = NSScreen.screens.map { screen in
            let win = makeWindow(for: screen, level: desktopLevel)
            win.orderFront(nil)
            return Surface(window: win, screen: screen)
        }
        apply(animated: false)
    }

    /// Bring the desktop in line with the current settings.
    func apply(animated: Bool = true) {
        if !hasLoaded || settings.currentVideo != loadedURL {
            swapVideo(animated: animated && hasLoaded)
        } else {
            layout(animated: animated)
        }
        updateRate()
        NSLog("LiveWall: \(surfaces.count) screen(s), span=\(settings.spanScreens), mode=\(settings.fillMode.rawValue), source=\(settings.currentVideo?.lastPathComponent ?? "gradient")")
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

    // MARK: - Video swapping

    /// Replace the playing video. With `animated`, the new video fades in over
    /// the old one once its first frame is ready, so there's never a black flash.
    private func swapVideo(animated: Bool) {
        let url = settings.currentVideo
        loadedURL = url
        hasLoaded = true
        readyObservers.removeAll()

        let oldPlayer = player
        let oldLayers = surfaces.map(\.layer)
        let newPlayer = makePlayer(for: url)
        player = newPlayer

        for i in surfaces.indices {
            let content = surfaces[i].window.contentView!
            let layer: CALayer
            if let newPlayer {
                let playerLayer = AVPlayerLayer(player: newPlayer)
                playerLayer.videoGravity = gravity
                playerLayer.frame = frame(for: surfaces[i].screen)
                layer = playerLayer
            } else {
                layer = makeGradient(bounds: content.bounds)   // no video selected → visible fallback
            }
            layer.opacity = animated ? 0 : 1
            content.layer?.addSublayer(layer)
            surfaces[i].layer = layer
        }
        updateRate()

        let retire = {
            oldLayers.forEach { $0?.removeFromSuperlayer() }
            oldPlayer?.pause()
        }
        guard animated else { retire(); return }

        let newLayers = surfaces.compactMap(\.layer)
        let fadeIn = {
            CATransaction.begin()
            CATransaction.setCompletionBlock(retire)
            for layer in newLayers {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.9
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.opacity = 1
                layer.add(fade, forKey: "crossfade")
            }
            CATransaction.commit()
        }

        // Wait for a real frame before fading, so we never fade in black.
        if let first = newLayers.first as? AVPlayerLayer, !first.isReadyForDisplay {
            readyObservers.append(first.observe(\.isReadyForDisplay) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    self?.readyObservers.removeAll()
                    fadeIn()
                }
            })
        } else {
            fadeIn()
        }
    }

    /// Apply the current video's speed. `defaultRate` makes the player
    /// resume at this speed after loops and stalls, not snap back to 1×.
    private func updateRate() {
        guard let player else { return }
        let rate = Float(settings.speed(for: settings.currentVideo))
        player.defaultRate = rate
        player.rate = rate
    }

    // MARK: - Building blocks

    private func makePlayer(for url: URL?) -> AVQueuePlayer? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
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
        player?.pause()
        player = nil
        looper = nil
        loadedURL = nil
        hasLoaded = false
    }
}
