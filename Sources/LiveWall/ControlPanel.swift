import SwiftUI
import AVFoundation

/// Which slice of the library the grid is showing.
enum LibraryFilter: Hashable {
    case all
    case untagged
    case tag(String)
}

/// The Wallpaper-Engine-style library window: a category sidebar on the left,
/// thumbnails on the right. Click a tile to apply it, right-click to tag it.
struct ControlPanelView: View {
    @ObservedObject var settings: AppSettings
    /// Called whenever a change should re-render the wallpaper.
    let onApply: () -> Void

    @State private var videos: [URL] = []
    @State private var watcher = FolderWatcher()
    @StateObject private var categories = CategoryStore()
    @State private var filter: LibraryFilter = .all

    // Tag-editing sheets. `newTagTarget` is set when "New Tag…" was chosen
    // from a tile's context menu, so the fresh tag is applied to that video.
    @State private var showNewTag = false
    @State private var newTagName = ""
    @State private var newTagTarget: URL?
    @State private var renameTarget: String?
    @State private var renameName = ""
    @State private var deleteTarget: String?
    @State private var query = ""
    @State private var heroPoster: NSImage?
    @State private var ambient: [Color] = AmbientPalette.fallback
    @State private var titleProgress: Double = 1
    @State private var heroHover: UnitPoint?

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 20)]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .navigationSubtitle("\(filterTitle) · \(filteredVideos.count) wallpaper\(filteredVideos.count == 1 ? "" : "s")")
        .searchable(text: $query, placement: .toolbar, prompt: "Search wallpapers")
        .toolbar { toolbar }
        .frame(minWidth: 960, minHeight: 620)
        .onAppear {
            categories.load(folder: settings.libraryFolder)
            reloadVideos()
            startWatching()
        }
        .onChange(of: settings.libraryFolder) {
            categories.load(folder: settings.libraryFolder)
            filter = .all
            reloadVideos()
            startWatching()
        }
        // The window is created once and only hidden on close, so onAppear
        // never re-fires; rescan whenever the window comes back to front.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in reloadVideos() }
        .onChange(of: settings.spanScreens) { onApply() }
        .onChange(of: settings.fillMode) { onApply() }
        .alert("New Tag", isPresented: $showNewTag) {
            TextField("Tag name", text: $newTagName)
            Button("Add") { commitNewTag() }
            Button("Cancel", role: .cancel) { newTagName = ""; newTagTarget = nil }
        } message: {
            Text(newTagTarget == nil
                 ? "Tags let you group wallpapers. Right-click a video to assign them."
                 : "The new tag will be applied to “\(newTagTarget!.deletingPathExtension().lastPathComponent)”.")
        }
        .alert("Rename Tag", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("Tag name", text: $renameName)
            Button("Rename") {
                if let old = renameTarget {
                    categories.rename(old, to: renameName)
                    if filter == .tag(old) { filter = .tag(renameName.trimmingCharacters(in: .whitespaces)) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete “\(deleteTarget ?? "")”?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { tag in
            Button("Delete Tag", role: .destructive) {
                if filter == .tag(tag) { filter = .all }
                categories.delete(tag)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { tag in
            Text("Removes the tag from \(categories.count(of: tag, in: videos)) video(s). The video files are not touched.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section("Library") {
                Label("All Videos", systemImage: "square.grid.2x2")
                    .badge(videos.count)
                    .tag(LibraryFilter.all)
                Label("Untagged", systemImage: "tag.slash")
                    .badge(categories.untagged(in: videos).count)
                    .tag(LibraryFilter.untagged)
            }
            Section("Tags") {
                if categories.tags.isEmpty {
                    Text("No tags yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(categories.tags, id: \.self) { tag in
                    Label {
                        Text(tag)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(TagPalette.color(for: tag))
                    }
                        .badge(categories.count(of: tag, in: videos))
                        .tag(LibraryFilter.tag(tag))
                        .contextMenu {
                            Button("Rename…") { renameName = tag; renameTarget = tag }
                            Button("Delete", role: .destructive) { deleteTarget = tag }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                newTagTarget = nil
                showNewTag = true
            } label: {
                Label("New Tag", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(12)
        }
    }

    // MARK: - Detail

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: chooseFolder) {
                Label(settings.libraryFolder?.lastPathComponent ?? "Choose Folder…", systemImage: "folder")
            }
            .help("Choose the folder LiveWall reads wallpapers from")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Scaling", selection: $settings.fillMode) {
                Text("Fill").tag(FillMode.fill)
                Text("Fit").tag(FillMode.fit)
                Text("Stretch").tag(FillMode.stretch)
            }
            .pickerStyle(.segmented)
            .help("Fill crops to cover the screen; Fit shows the whole frame with bars; Stretch distorts it to fill exactly")

            Toggle(isOn: $settings.spanScreens) {
                Label("Span Screens", systemImage: "rectangle.split.3x1")
                    .labelStyle(.titleAndIcon)
            }
            .help(settings.spanScreens ? "One video spans every display" : "Each display plays the full video")
        }
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if let current = settings.currentVideo, query.isEmpty {
                    hero(for: current)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity.combined(with: .offset(y: -30))))
                }
                grid
            }
            .padding(24)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: query.isEmpty)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background {
            AmbientBackground(colors: ambient)
                .backgroundExtensionEffect()
                .ignoresSafeArea()
        }
        // Everything that follows the current wallpaper — the aurora colours,
        // the poster frame, the title reveal — updates together.
        .task(id: settings.currentVideo) {
            guard let url = settings.currentVideo else { return }
            titleProgress = 0
            let poster = await ThumbnailCache.image(for: url)
            heroPoster = poster
            withAnimation(.easeOut(duration: 1.2)) { titleProgress = 1 }
            if let poster {
                let palette = AmbientPalette.colors(from: poster)
                withAnimation(.easeInOut(duration: 1.6)) { ambient = palette }
            }
        }
    }

    /// The live, full-width preview of whatever is on the desktop right now.
    /// Video drifts against the cursor for depth, the card leans in 3D, and it
    /// recedes into a blur as you scroll past it.
    private func hero(for url: URL) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let dx = ((heroHover?.x ?? 0.5) - 0.5) * 2
        let dy = ((heroHover?.y ?? 0.5) - 0.5) * 2

        return ZStack(alignment: .bottomLeading) {
            // Color.clear fixes the size; an aspect-fill image laid out
            // directly would grow the hero past its frame.
            Color.clear.overlay {
                ZStack {
                    // Poster frame under the video, so the hero is never black
                    // while the player spins up.
                    if let heroPoster {
                        Image(nsImage: heroPoster)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    LoopingVideoView(url: url)
                        .id(url)
                        .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                }
            }
            .scaleEffect(1.12)
            .offset(x: -dx * 22, y: -dy * 14)
            .clipped()

            LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                   .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Now Playing", systemImage: "dot.radiowaves.left.and.right")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(url.wallpaperName)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .textRenderer(BlurRevealRenderer(progress: titleProgress))
                    let tags = categories.tags(for: url)
                    if !tags.isEmpty {
                        HStack(spacing: 6) { ForEach(tags, id: \.self) { TagChip(tag: $0) } }
                            .opacity(titleProgress)
                            .offset(y: (1 - titleProgress) * 10)
                    }
                }
                .offset(x: dx * 6, y: dy * 4)
                Spacer(minLength: 16)
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glass)
                        .help("Show in Finder")

                        Button(action: shuffle) {
                            Label("Shuffle", systemImage: "shuffle")
                                .symbolEffect(.bounce, value: settings.currentVideo)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(filteredVideos.count < 2)
                        .help("Play a random wallpaper from this view")
                    }
                    .controlSize(.large)
                }
            }
            .environment(\.colorScheme, .dark)
            .padding(28)

            SpecularHighlight(point: heroHover)
        }
        .overlay(alignment: .topTrailing) { displayCard.padding(20) }
        .frame(height: 340)
        .frame(maxWidth: .infinity)
        .background(.black)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.12)) }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
        .tilt(toward: heroHover, maxAngle: 2.5)
        .trackHover($heroHover)
        .visualEffect { content, proxy in
            let minY = proxy.frame(in: .scrollView).minY
            let progress = min(max(-minY / 340, 0), 1)
            return content
                .scaleEffect(1 - progress * 0.12, anchor: .bottom)
                .blur(radius: progress * 16)
                .opacity(1 - progress * 0.8)
                .offset(y: max(0, -minY) * 0.45)
        }
    }

    /// A live miniature of the real monitors, so Fill / Fit / Stretch and
    /// Span Screens show exactly what they'll do.
    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: NSScreen.screens.count > 1 ? "display.2" : "display")
                Text("Your desktop")
                Spacer()
                Text("\(settings.fillMode.title)\(settings.spanScreens && NSScreen.screens.count > 1 ? " · Spanned" : "")")
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .font(.caption.weight(.semibold))
            DisplayPreview(poster: heroPoster, mode: settings.fillMode, span: settings.spanScreens)
                .frame(height: 76)
            if let hint = scalingHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .frame(width: 250)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
        .animation(.smooth, value: settings.fillMode)
        .animation(.smooth, value: settings.spanScreens)
    }

    /// Explains when the scaling buttons can't make a visible difference.
    private var scalingHint: String? {
        guard let poster = heroPoster, poster.size.height > 0 else { return nil }
        let videoAspect = poster.size.width / poster.size.height
        let screens = NSScreen.screens.map(\.frame)
        let union = screens.reduce(CGRect.null) { $0.union($1) }
        let targets = settings.spanScreens ? [union] : screens
        let matches = targets.allSatisfy { abs($0.width / $0.height - videoAspect) / videoAspect < 0.03 }
        if matches { return "This video already matches your screen shape, so Fill, Fit and Stretch look the same." }
        if settings.spanScreens && screens.count > 1 {
            return "Spanning makes one wide canvas: Fill crops, Fit letterboxes, Stretch widens."
        }
        return nil
    }

    private func shuffle() {
        let pool = filteredVideos.filter { $0 != settings.currentVideo }
        guard let next = pool.randomElement() else { return }
        settings.currentVideo = next
        onApply()
    }

    private var filteredVideos: [URL] {
        let base: [URL]
        switch filter {
        case .all:          base = videos
        case .untagged:     base = categories.untagged(in: videos)
        case .tag(let tag): base = videos.filter { categories.has(tag, $0) }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter { url in
            url.wallpaperName.localizedCaseInsensitiveContains(q)
                || categories.tags(for: url).contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var filterTitle: String {
        switch filter {
        case .all:          return "All Wallpapers"
        case .untagged:     return "Untagged"
        case .tag(let tag): return tag
        }
    }

    @ViewBuilder
    private var grid: some View {
        if videos.isEmpty {
            ContentUnavailableView {
                Label("No videos here", systemImage: "film.stack")
            } description: {
                Text("Choose a folder containing .mp4, .mov or .m4v files.")
            } actions: {
                Button("Choose Folder…", action: chooseFolder).buttonStyle(.glassProminent)
            }
            .padding(.top, 60)
        } else if filteredVideos.isEmpty {
            Group {
                if query.isEmpty {
                    ContentUnavailableView(emptyFilterTitle,
                        systemImage: "tag",
                        description: Text("Right-click any video to assign tags."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(query.isEmpty ? filterTitle : "Results")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .contentTransition(.interpolate)
                    Text("\(filteredVideos.count)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .animation(.smooth, value: filteredVideos.count)
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(filteredVideos.enumerated()), id: \.element) { index, url in
                        VideoTile(url: url,
                                  isSelected: url == settings.currentVideo,
                                  tags: categories.tags(for: url),
                                  index: index) {
                            settings.currentVideo = url
                            onApply()
                        }
                        .contextMenu { tagMenu(for: url) }
                        // Tiles ease out of focus as they leave the viewport.
                        .scrollTransition(.interactive, axis: .vertical) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.96)
                                .opacity(phase.isIdentity ? 1 : 0.6)
                        }
                    }
                }
                // A new filter replays the staggered entrance.
                .id(filter)
            }
        }
    }

    private var emptyFilterTitle: String {
        switch filter {
        case .untagged:     return "Everything is tagged"
        case .tag(let tag): return "Nothing tagged “\(tag)”"
        case .all:          return "No videos"
        }
    }

    /// Right-click menu on a tile: one checkable row per tag, plus New Tag.
    @ViewBuilder
    private func tagMenu(for url: URL) -> some View {
        Section("Tags") {
            ForEach(categories.tags, id: \.self) { tag in
                Toggle(tag, isOn: Binding(
                    get: { categories.has(tag, url) },
                    set: { _ in categories.toggle(tag, for: url) }))
            }
        }
        Divider()
        Button("New Tag…") {
            newTagTarget = url
            showNewTag = true
        }
    }

    private func commitNewTag() {
        if let tag = categories.addTag(newTagName) {
            if let target = newTagTarget, !categories.has(tag, target) {
                categories.toggle(tag, for: target)
            }
        }
        newTagName = ""
        newTagTarget = nil
    }

    // MARK: - Library scanning

    private func reloadVideos() {
        categories.reloadIfChanged()
        guard let folder = settings.libraryFolder,
              let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else {
            videos = []
            return
        }
        let exts: Set<String> = ["mp4", "mov", "m4v"]
        videos = items
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Live-refresh the grid as files land in (or vanish from) the library.
    private func startWatching() {
        guard let folder = settings.libraryFolder else {
            watcher.stop()
            return
        }
        watcher.watch(folder) { reloadVideos() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryFolder = url
        }
    }
}
