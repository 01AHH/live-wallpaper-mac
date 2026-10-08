import SwiftUI
import AVFoundation

/// A muted, endlessly looping video for use inside SwiftUI — the live hero
/// preview and the hover previews on library tiles. Pauses itself whenever its
/// window is hidden or fully covered, so the closed control panel costs nothing.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> PlayerView { PlayerView() }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.load(url)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.load(nil)
    }

    final class PlayerView: NSView {
        private let playerLayer = AVPlayerLayer()
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var currentURL: URL?
        private var occlusionObserver: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func load(_ url: URL?) {
            guard url != currentURL else { return }
            currentURL = url
            player?.pause()
            looper = nil
            player = nil
            playerLayer.player = nil
            guard let url else { return }

            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
            player = queue
            playerLayer.player = queue
            updatePlayback()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = nil
            if let window {
                occlusionObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window, queue: .main) { [weak self] _ in self?.updatePlayback() }
            }
            updatePlayback()
        }

        private func updatePlayback() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            if visible { player?.play() } else { player?.pause() }
        }

        deinit {
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        }
    }
}
