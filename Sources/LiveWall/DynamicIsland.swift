import SwiftUI
import AppKit
import Combine

/// A short-lived announcement the island springs open to show.
struct IslandEvent: Equatable {
    let icon: String
    let title: String
    var subtitle: String?
    /// Artwork shown on the right (album art); the wallpaper poster otherwise.
    var image: NSImage?
    var duration: Double = 3
    let id = UUID()

    static func == (a: IslandEvent, b: IslandEvent) -> Bool { a.id == b.id }
}

/// State behind the Dynamic Island. It shows, in priority order: an AI or
/// other tool activity that's running or needs attention, the music that's
/// playing, then the wallpaper. Events open it briefly; hovering expands it
/// into a stack of live cards; otherwise it rests at the top of the screen —
/// around the notch, or as a small pill on a monitor without one (hidden
/// there when nothing is live).
@MainActor
final class IslandModel: ObservableObject {
    enum Mode { case resting, event, expanded }

    /// What the resting pill is about.
    enum Focus: Equatable { case activity(LiveActivity), music, wallpaper }

    @Published private(set) var mode: Mode = .resting
    @Published private(set) var event: IslandEvent?
    @Published var poster: NSImage?
    @Published var pauseReason: WallpaperController.PauseReason?
    @Published var geometry: IslandGeometry

    let settings: AppSettings
    let activities: ActivityCenter
    var onTogglePause: () -> Void = {}
    var onShuffle: () -> Void = {}
    var onOpenControls: () -> Void = {}

    private var dismissTask: Task<Void, Never>?
    private var forward: AnyCancellable?

    init(settings: AppSettings, activities: ActivityCenter, geometry: IslandGeometry) {
        self.settings = settings
        self.activities = activities
        self.geometry = geometry
        // Re-render (and resize) whenever music or activities change.
        forward = activities.objectWillChange.sink { [weak self] _ in
            withAnimation(Self.spring) { self?.objectWillChange.send() }
        }
        activities.onEvent = { [weak self] in self?.announce($0) }
    }

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    var isHovering = false {
        didSet { if isHovering != oldValue { updateMode() } }
    }

    var isPlaying: Bool { pauseReason == nil }

    var focus: Focus {
        if let activity = activities.currentActivity { return .activity(activity) }
        if activities.isMusicPlaying { return .music }
        return .wallpaper
    }

    /// Show an event for a while. A new event replaces the current one and
    /// restarts the timer, so a dragged speed slider reads as one event.
    func announce(_ newEvent: IslandEvent) {
        event = newEvent
        updateMode()
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(newEvent.duration))
            guard !Task.isCancelled else { return }
            event = nil
            updateMode()
        }
    }

    private func updateMode() {
        withAnimation(Self.spring) {
            mode = isHovering ? .expanded : (event != nil ? .event : .resting)
        }
    }

    // MARK: Layout

    enum Metrics {
        static let musicCard: CGFloat = 64
        static let activityRow: CGFloat = 40
        static let wallpaperCard: CGFloat = 104
        static let spacing: CGFloat = 10
        static let padding: CGFloat = 14
        static let maxActivities = 2
    }

    var visibleActivities: [LiveActivity] { Array(activities.activities.prefix(Metrics.maxActivities)) }

    /// The island's current size, which the window controller also uses to
    /// decide where clicks should land.
    var size: CGSize {
        let g = geometry
        switch mode {
        case .resting:
            if g.hasNotch { return CGSize(width: g.notchWidth + 84, height: g.notchHeight) }
            // No notch: a small pill while something is live, otherwise hidden.
            return focus == .wallpaper ? .zero : CGSize(width: 300, height: max(g.menuBarHeight, 30))
        case .event:
            return CGSize(width: max(g.notchWidth + 84, 380), height: g.topInset + 60)
        case .expanded:
            var cards: [CGFloat] = [Metrics.wallpaperCard]
            if activities.nowPlaying != nil { cards.append(Metrics.musicCard) }
            cards += visibleActivities.map { _ in Metrics.activityRow }
            let content = cards.reduce(0, +) + Metrics.spacing * CGFloat(cards.count - 1)
            return CGSize(width: 460, height: g.topInset + content + Metrics.padding * 2)
        }
    }
}

/// Where the island sits. It's always attached to the top edge of the screen:
/// on a notched display it grows out of the notch, and on an external monitor
/// it behaves like a virtual notch, dropping down over the middle of the menu
/// bar rather than floating below it.
struct IslandGeometry: Equatable {
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let menuBarHeight: CGFloat

    /// Space reserved at the top of the island for the notch itself.
    var topInset: CGFloat { hasNotch ? notchHeight : 0 }

    init(screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = screen.frame.width - left.width - right.width
            notchHeight = inset
        } else {
            hasNotch = false
            notchWidth = 0
            notchHeight = 0
        }
        menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
    }
}

// MARK: - View

struct DynamicIslandView: View {
    @ObservedObject var model: IslandModel
    private typealias M = IslandModel.Metrics

    private var activities: ActivityCenter { model.activities }

    private var radius: CGFloat {
        switch model.mode {
        case .resting:  return model.geometry.hasNotch ? 12 : 16
        case .event:    return 26
        case .expanded: return 32
        }
    }

    var body: some View {
        let size = model.size
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                islandShape.fill(.black)
                content
                    .padding(.top, model.geometry.topInset)
                    .opacity(size == .zero ? 0 : 1)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(islandShape)
            .shadow(color: .black.opacity(model.mode == .resting ? 0 : 0.35), radius: 18, y: 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// Square top corners where the island meets the top of the screen (or
    /// the notch), generous rounded bottom corners.
    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                               bottomTrailingRadius: radius, topTrailingRadius: 0,
                               style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .resting:  resting
        case .event:    eventRow
        case .expanded: expanded
        }
    }

    // MARK: Resting

    /// Leading artwork and trailing status glyph; on a monitor without a notch
    /// there's room for the title in between.
    private var resting: some View {
        HStack(spacing: 10) {
            restingLeading
            if model.geometry.hasNotch {
                Spacer(minLength: model.geometry.notchWidth)
            } else {
                Text(restingTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            restingTrailing
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .padding(.top, -model.geometry.topInset)   // beside the notch, not below it
        .transition(.opacity)
    }

    private var restingTitle: String {
        switch model.focus {
        case .activity(let a): return a.title
        case .music:           return activities.nowPlaying.map { "\($0.title) · \($0.artist)" } ?? ""
        case .wallpaper:       return model.settings.currentVideo?.wallpaperName ?? ""
        }
    }

    @ViewBuilder
    private var restingLeading: some View {
        switch model.focus {
        case .activity(let a):
            Image(systemName: a.state == .attention ? "exclamationmark.bubble.fill" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.accent)
        case .music:
            artwork(activities.artwork, size: CGSize(width: 18, height: 18), radius: 4, fallback: "music.note")
        case .wallpaper:
            artwork(model.poster, size: CGSize(width: 22, height: 14), radius: 4, fallback: "photo")
        }
    }

    @ViewBuilder
    private var restingTrailing: some View {
        switch model.focus {
        case .activity(let a):
            if a.state == .attention {
                Circle().fill(Brand.accent).frame(width: 7, height: 7)
            } else {
                // Static on purpose: a resting island that animates forever
                // redraws its whole window every frame and makes the app stutter.
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Brand.accent)
            }
        case .music:
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.accent)
        case .wallpaper:
            wallpaperGlyph.font(.system(size: 12, weight: .semibold))
        }
    }

    // MARK: Event

    private var eventRow: some View {
        HStack(spacing: 12) {
            if let event = model.event {
                Image(systemName: event.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 32, height: 32)
                    .background(Brand.accent.opacity(0.18), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    if let subtitle = event.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Text(event.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let image = event.image {
                    artwork(image, size: CGSize(width: 36, height: 36), radius: 8, fallback: "music.note")
                } else if event.icon != "sparkles" && !event.icon.hasPrefix("checkmark") && !event.icon.hasPrefix("exclamation") {
                    artwork(model.poster, size: CGSize(width: 54, height: 30), radius: 7, fallback: "photo")
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: M.spacing) {
            ForEach(model.visibleActivities) { activityRow($0) }
            if activities.nowPlaying != nil { musicCard }
            wallpaperCard
        }
        .padding(M.padding)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
    }

    private func activityRow(_ a: LiveActivity) -> some View {
        HStack(spacing: 12) {
            Group {
                switch a.state {
                case .running:   ProgressView().controlSize(.small).tint(Brand.accent)
                case .done:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .attention: Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Brand.accent)
                }
            }
            .font(.system(size: 16))
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.source)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.5))
                Text(a.detail.map { "\(a.title) — \($0)" } ?? a.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(a.updated, style: .relative)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(height: M.activityRow)
    }

    private var musicCard: some View {
        HStack(spacing: 12) {
            artwork(activities.artwork, size: CGSize(width: 52, height: 52), radius: 10, fallback: "music.note")
            VStack(alignment: .leading, spacing: 2) {
                Text(activities.nowPlaying?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(activities.nowPlaying?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            IslandButton(icon: "backward.fill", label: "Previous") { activities.send(.previous) }
            IslandButton(icon: activities.isMusicPlaying ? "pause.fill" : "play.fill",
                         label: activities.isMusicPlaying ? "Pause music" : "Play music",
                         prominent: true) { activities.send(.playPause) }
            IslandButton(icon: "forward.fill", label: "Next") { activities.send(.next) }
        }
        .frame(height: M.musicCard)
    }

    private var wallpaperCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                artwork(model.poster, size: CGSize(width: 86, height: 48), radius: 9, fallback: "photo")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wallpaper")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(Brand.glow)
                    Text(model.settings.currentVideo?.wallpaperName ?? "No wallpaper")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                IslandButton(icon: model.isPlaying ? "pause.fill" : "play.fill",
                             label: model.isPlaying ? "Pause wallpaper" : "Play wallpaper",
                             action: model.onTogglePause)
                IslandButton(icon: "shuffle", label: "Shuffle wallpaper", action: model.onShuffle)
                speedMenu
                Spacer()
                IslandButton(icon: "square.grid.2x2", label: "Open LiveWall", action: model.onOpenControls)
            }
        }
        .frame(height: M.wallpaperCard)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5], id: \.self) { speed in
                Button(speed.formatted(.number.precision(.fractionLength(0...2))) + "×") {
                    if let url = model.settings.currentVideo { model.settings.setSpeed(speed, for: url) }
                }
            }
        } label: {
            Text(currentSpeed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(currentSpeed == 1 ? .white : Brand.accent)
                .frame(width: 44, height: 30)
                .background(.white.opacity(0.1), in: .capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Wallpaper playback speed")
    }

    private var currentSpeed: Double { model.settings.speed(for: model.settings.currentVideo) }

    private var statusText: String {
        switch model.pauseReason {
        case .user:           return "Paused"
        case .hidden:         return "Paused while covered"
        case .displaysAsleep: return "Paused — displays asleep"
        case .battery:        return "Paused on battery"
        case .lowPower:       return "Paused — Low Power Mode"
        case .hot:            return "Paused while your Mac cools down"
        case nil:
            let speed = currentSpeed
            return speed == 1 ? "Playing" : "Playing at \(speed.formatted(.number.precision(.fractionLength(0...2))))×"
        }
    }

    @ViewBuilder
    private var wallpaperGlyph: some View {
        if model.isPlaying {
            Image(systemName: "waveform")
                .foregroundStyle(Brand.accent)
        } else {
            Image(systemName: "pause.fill").foregroundStyle(.white.opacity(0.6))
        }
    }

    private func artwork(_ image: NSImage?, size: CGSize, radius: CGFloat, fallback: String) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.12))
                    Image(systemName: fallback)
                        .font(.system(size: min(size.width, size.height) * 0.4))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A round icon button for the expanded island.
private struct IslandButton: View {
    let icon: String
    let label: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 15 : 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : .white)
                .frame(width: prominent ? 36 : 30, height: prominent ? 36 : 30)
                .background(prominent ? AnyShapeStyle(Brand.accent)
                                      : AnyShapeStyle(.white.opacity(hovering ? 0.2 : 0.1)), in: .circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Window

/// A transparent, click-through panel across the top of one screen that hosts
/// the island. Clicks only land when the cursor is over the island itself, so
/// the menu bar and windows underneath keep working.
@MainActor
final class DynamicIslandController {
    let model: IslandModel
    let activities = ActivityCenter()
    private let codexWatcher = CodexSessionWatcher()
    private let chatAppWatcher = ChatAppWatcher()
    private let panel: NSPanel
    private var monitors: [Any] = []
    private static let canvas = CGSize(width: 560, height: 420)

    /// The display with the menu bar — the external monitor when one is
    /// plugged in and set as main, otherwise the built-in screen.
    private static var hostScreen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private static func frame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - canvas.width / 2, y: screen.frame.maxY - canvas.height,
               width: canvas.width, height: canvas.height)
    }

    init(settings: AppSettings) {
        let screen = Self.hostScreen
        model = IslandModel(settings: settings, activities: activities,
                            geometry: IslandGeometry(screen: screen))

        let frame = Self.frame(on: screen)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: DynamicIslandView(model: model))
        panel.setFrame(frame, display: true)

        codexWatcher.onActivity = { [weak activities] in activities?.report($0) }
        chatAppWatcher.onActivity = { [weak activities] in activities?.report($0) }

        let track: (NSEvent) -> Void = { [weak self] _ in self?.trackMouse() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: track) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { track($0); return $0 }) {
            monitors.append(local)
        }
    }

    /// Apply the person's choice of sources: filter what's shown and only run
    /// the watchers that are needed.
    func setSources(_ sources: Set<IslandSource>) {
        activities.enabledSources = sources
        if sources.contains(.chatGPT) { codexWatcher.start() } else { codexWatcher.stop() }

        var apps: [ChatAppWatcher.App] = []
        if sources.contains(.chatGPT) { apps.append(.init(bundleID: "com.openai.codex", source: "ChatGPT")) }
        if sources.contains(.claudeApp) { apps.append(.init(bundleID: "com.anthropic.claudefordesktop", source: "Claude")) }
        chatAppWatcher.apps = apps
        if apps.isEmpty { chatAppWatcher.stop() } else { chatAppWatcher.start() }
    }

    /// Re-home the island after monitors are plugged in, unplugged or
    /// rearranged.
    func screensChanged() {
        let screen = Self.hostScreen
        model.geometry = IslandGeometry(screen: screen)
        panel.setFrame(Self.frame(on: screen), display: true)
    }

    var isShown = false {
        didSet {
            if isShown { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
    }

    /// The island's rectangle in screen coordinates. When it's hidden (no
    /// notch, nothing live), a thin strip at the top centre of the screen
    /// acts as the hover target that reveals it.
    private var hotRect: NSRect {
        let top = panel.frame.maxY
        let size = model.size
        guard size != .zero else {
            return NSRect(x: panel.frame.midX - 120, y: top - 4, width: 240, height: 4)
        }
        return NSRect(x: panel.frame.midX - size.width / 2, y: top - size.height,
                      width: size.width, height: size.height)
    }

    private func trackMouse() {
        guard isShown else { return }
        let inside = hotRect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        model.isHovering = inside
    }
}
