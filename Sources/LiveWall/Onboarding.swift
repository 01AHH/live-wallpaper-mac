import SwiftUI
import AppKit
import ServiceManagement

/// The first-run experience: a full-screen welcome in the spirit of Arc and
/// Raycast. Big, quiet type on black, then a few steps that make the Mac
/// yours — the first wallpaper plays full-screen behind the welcome the
/// moment it's chosen.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var gallery: GalleryStore
    /// Download a gallery wallpaper into the library and put it on the desktop.
    let onChooseWallpaper: (GalleryWallpaper, @escaping (URL?) -> Void) -> Void
    let onOpenControls: () -> Void
    let onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, wallpaper, island, effortless, done }

    @State private var step: Step = .welcome
    @State private var titleProgress: Double = 0
    @State private var showSecondLine = false
    @State private var showBegin = false
    @State private var chosen: GalleryWallpaper?
    @State private var chosenFile: URL?
    @State private var downloading: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                content
                    .frame(maxWidth: 980)
                    .padding(.horizontal, 48)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 24)).combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .offset(y: -16))))
                Spacer(minLength: 0)
                progressDots.padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onExitCommand { finish() }
        .task { await runWelcome() }
    }

    // MARK: Background

    /// Black at first; once a wallpaper is chosen it plays full-screen
    /// behind everything, softened so the type stays readable.
    private var background: some View {
        ZStack {
            Color.black
            if let chosenFile {
                LoopingVideoView(url: chosenFile)
                    .transition(.opacity.animation(.easeInOut(duration: 1.6)))
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.25), .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
            } else if step != .welcome {
                RadialGradient(colors: [Brand.accent.opacity(0.18), .clear],
                               center: .top, startRadius: 0, endRadius: 900)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: chosenFile)
        .animation(.easeInOut(duration: 1.2), value: step)
    }

    private var topBar: some View {
        HStack {
            if step != .welcome && step != .done {
                Button { go(Step(rawValue: step.rawValue - 1) ?? .welcome) } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if step != .done {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Skip the welcome (Esc)")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .frame(height: 80)
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s == step ? Color.white : .white.opacity(0.25))
                    .frame(width: s == step ? 22 : 6, height: 6)
            }
        }
        .animation(Brand.spring, value: step)
        .opacity(step == .welcome && !showBegin ? 0 : 1)
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:    welcome
        case .wallpaper:  wallpaperStep
        case .island:     islandStep
        case .effortless: effortlessStep
        case .done:       doneStep
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Text("Welcome to your new Mac.")
                .font(.system(size: 64, weight: .semibold))
                .tracking(-1.5)
                .foregroundStyle(.white)
                .textRenderer(BlurRevealRenderer(progress: titleProgress))
            Text("Welcome to a more personalised experience.")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))
                .opacity(showSecondLine ? 1 : 0)
                .offset(y: showSecondLine ? 0 : 14)
                .blur(radius: showSecondLine ? 0 : 6)
            primaryButton("Let's begin") { go(.wallpaper) }
                .padding(.top, 34)
                .opacity(showBegin ? 1 : 0)
                .scaleEffect(showBegin ? 1 : 0.94)
        }
        .multilineTextAlignment(.center)
    }

    private var wallpaperStep: some View {
        VStack(spacing: 26) {
            heading("Choose your first wallpaper",
                    "It plays right on your desktop, behind your icons. Change it any time.")
            let picks = Array(gallery.wallpapers.filter { !$0.isUnverified }.prefix(6))
            if picks.isEmpty {
                if gallery.error != nil {
                    Text("Couldn't reach the gallery — you can add wallpapers later.")
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ProgressView().controlSize(.large).padding(40)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                    ForEach(picks) { pick in wallpaperChoice(pick) }
                }
            }
            HStack(spacing: 14) {
                if chosenFile == nil {
                    secondaryButton("Skip for now") { go(.island) }
                }
                primaryButton(chosenFile == nil ? "Continue" : "Love it — continue") { go(.island) }
                    .disabled(chosenFile == nil)
                    .opacity(chosenFile == nil ? 0.4 : 1)
            }
        }
        .task { await gallery.load() }
    }

    private func wallpaperChoice(_ pick: GalleryWallpaper) -> some View {
        let selected = chosen?.id == pick.id
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            guard downloading == nil else { return }
            chosen = pick
            downloading = pick.id
            onChooseWallpaper(pick) { file in
                downloading = nil
                if let file { withAnimation { chosenFile = file } }
            }
        } label: {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: pick.poster) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color.white.opacity(0.06) }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(pick.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .shadow(radius: 6)
                }
                .overlay {
                    if downloading == pick.id {
                        ZStack {
                            Color.black.opacity(0.45)
                            ProgressView(value: gallery.progress[pick.id] ?? 0)
                                .progressViewStyle(.circular)
                                .tint(.white)
                        }
                    }
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(selected ? Brand.accent : .white.opacity(0.12), lineWidth: selected ? 3 : 1)
                }
                .scaleEffect(selected ? 1.03 : 1)
                .animation(Brand.spring, value: selected)
        }
        .buttonStyle(.plain)
    }

    private var islandStep: some View {
        VStack(spacing: 30) {
            heading("Meet your Dynamic Island",
                    "A quiet pill at the top of your screen. It lights up when something's happening — and stays out of the way when it isn't.")
            islandDemo
            VStack(spacing: 10) {
                sourceToggle(.music, "Music", "What's playing in Spotify or Apple Music, with controls")
                sourceToggle(.claudeCode, "Claude Code", "When Claude is working, needs you, or is done")
                sourceToggle(.chatGPT, "ChatGPT & Codex", "When a ChatGPT or Codex task is running")
            }
            .frame(maxWidth: 560)
            primaryButton("Continue") { go(.effortless) }
        }
    }

    /// A little island that cycles through what it can show.
    private var islandDemo: some View {
        TimelineView(.periodic(from: .now, by: 2.6)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 2.6) % 3
            let (icon, title, subtitle): (String, String, String) = [
                ("music.note", "Weightless", "Marconi Union"),
                ("sparkles", "Refactoring the wallpaper controller", "Claude Code"),
                ("play.rectangle.fill", "Blue Horizon", "Now playing"),
            ][phase]
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 32, height: 32)
                    .background(Brand.accent.opacity(0.18), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: 380, height: 60)
            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26, style: .continuous))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .id(phase)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            .animation(Brand.spring, value: phase)
        }
    }

    private func sourceToggle(_ source: IslandSource, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { settings.islandSources.contains(source) },
            set: { on in if on { settings.islandSources.insert(source) } else { settings.islandSources.remove(source) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .toggleStyle(.switch)
        .tint(Brand.accent)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var effortlessStep: some View {
        VStack(spacing: 30) {
            heading("Make it effortless",
                    "LiveWall starts with your Mac and steps back when your battery or fans need it.")
            VStack(spacing: 10) {
                settingToggle("Open at login", "Your wallpaper is there every time you start up", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        launchAtLogin = on
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }))
                settingToggle("Pause in Low Power Mode", "Saves battery when your Mac asks it to", isOn: $settings.pauseInLowPower)
                settingToggle("Pause on battery", "Only play while plugged in", isOn: $settings.pauseOnBattery)
            }
            .frame(maxWidth: 560)
            primaryButton("Continue") { go(.done) }
        }
    }

    private func settingToggle(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .toggleStyle(.switch)
        .tint(Brand.accent)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var doneStep: some View {
        VStack(spacing: 22) {
            Text("You're all set.")
                .font(.system(size: 60, weight: .semibold))
                .tracking(-1.5)
                .foregroundStyle(.white)
            Text("LiveWall lives in your menu bar, top right. Open it any time to change your wallpaper, give each display its own, or browse the gallery.")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: 620)
            HStack(spacing: 14) {
                secondaryButton("Browse the gallery") {
                    NSWorkspace.shared.open(URL(string: "https://livewallpapermac.vercel.app")!)
                }
                primaryButton("Open LiveWall") {
                    finish()
                    onOpenControls()
                }
            }
            .padding(.top, 18)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: Building blocks

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 44, weight: .semibold))
                .tracking(-1)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.62))
                .frame(maxWidth: 620)
        }
        .multilineTextAlignment(.center)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 28).padding(.vertical, 13)
                .background(.white, in: .capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 24).padding(.vertical, 13)
                .background(.white.opacity(0.1), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Flow

    /// The opening: the title sharpens in letter by letter, then the second
    /// line rises, then the button.
    private func runWelcome() async {
        try? await Task.sleep(for: .milliseconds(600))
        withAnimation(.easeOut(duration: 1.8)) { titleProgress = 1 }
        try? await Task.sleep(for: .milliseconds(1900))
        withAnimation(.easeOut(duration: 1.1)) { showSecondLine = true }
        try? await Task.sleep(for: .milliseconds(1300))
        withAnimation(Brand.spring) { showBegin = true }
    }

    private func go(_ next: Step) {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { step = next }
    }

    private func finish() {
        settings.hasOnboarded = true
        onFinish()
    }
}

/// A borderless window that can still take keyboard focus.
final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Move to Applications

/// Offers to move LiveWall into /Applications when it's opened from
/// anywhere else (straight from the .dmg, or from Downloads), copies it,
/// relaunches the copy, and ejects the installer disk.
///
/// Returns true when a relaunch is under way and this instance should stop.
@MainActor
enum ApplicationsMover {
    static func moveIfNeeded() -> Bool {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let path = bundle.path
        let home = NSHomeDirectory()
        guard Bundle.main.bundleIdentifier != nil,
              !path.hasPrefix("/Applications/"),
              !path.hasPrefix(home + "/Applications/"),
              !path.contains("/.build/")
        else { return false }

        let alert = NSAlert()
        alert.messageText = "Move LiveWall to Applications?"
        alert.informativeText = "LiveWall works best from your Applications folder — it can start with your Mac and stay up to date. It'll reopen from there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.icon = NSApp.applicationIconImage
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let destination = URL(fileURLWithPath: "/Applications/LiveWall.app")
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: bundle, to: destination)
            // The copy keeps the download's quarantine flag; clear it so the
            // moved app opens without asking again.
            let strip = Process()
            strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            strip.arguments = ["-dr", "com.apple.quarantine", destination.path]
            try? strip.run()
            strip.waitUntilExit()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move LiveWall"
            failure.informativeText = "Drag LiveWall into Applications yourself. (\(error.localizedDescription))"
            failure.runModal()
            return false
        }

        // Relaunch from Applications, eject the installer disk, and quit.
        // (Apps opened from a downloaded disk image run from a hidden
        // translocated copy, so find the installer by its volume name.)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
                for volume in volumes where volume.hasPrefix("LiveWall") {
                    let eject = Process()
                    eject.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    eject.arguments = ["detach", "/Volumes/\(volume)", "-quiet"]
                    try? eject.run()
                }
                NSApp.terminate(nil)
            }
        }
        return true
    }
}
