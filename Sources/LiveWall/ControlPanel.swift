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

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            VStack(spacing: 0) {
                controls
                Divider()
                grid
            }
        }
        .frame(minWidth: 900, minHeight: 560)
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
                    Label(tag, systemImage: "tag")
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
                Label("New Tag…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: - Detail

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder")
            }

            Text(settings.libraryFolder?.lastPathComponent ?? "No folder")
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Toggle("Span screens", isOn: $settings.spanScreens)
                .toggleStyle(.switch)

            Picker("", selection: $settings.fillMode) {
                ForEach(FillMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(12)
    }

    private var filteredVideos: [URL] {
        switch filter {
        case .all:          return videos
        case .untagged:     return categories.untagged(in: videos)
        case .tag(let tag): return videos.filter { categories.has(tag, $0) }
        }
    }

    private var grid: some View {
        ScrollView {
            if videos.isEmpty {
                ContentUnavailableView("No videos here",
                    systemImage: "film.stack",
                    description: Text("Choose a folder containing .mp4, .mov or .m4v files."))
                    .padding(.top, 60)
            } else if filteredVideos.isEmpty {
                ContentUnavailableView(emptyFilterTitle,
                    systemImage: "tag",
                    description: Text("Right-click any video to assign tags."))
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredVideos, id: \.self) { url in
                        VideoThumb(url: url,
                                   isSelected: url == settings.currentVideo,
                                   tags: categories.tags(for: url))
                            .onTapGesture {
                                settings.currentVideo = url
                                onApply()
                            }
                            .contextMenu { tagMenu(for: url) }
                    }
                }
                .padding(14)
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

/// A single library tile: an auto-generated video thumbnail, filename, and
/// the tags it carries.
struct VideoThumb: View {
    let url: URL
    let isSelected: Bool
    var tags: [String] = []
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.gray.opacity(0.15))
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            Text(url.deletingPathExtension().lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)

            Text(tags.isEmpty ? " " : tags.joined(separator: " · "))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .task(id: url) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        if let cg = try? await gen.image(at: time).image {
            image = NSImage(cgImage: cg, size: .zero)
        }
    }
}
