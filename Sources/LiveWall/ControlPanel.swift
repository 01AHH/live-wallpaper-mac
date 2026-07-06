import SwiftUI
import AVFoundation

/// The Wallpaper-Engine-style library window: pick a folder, see thumbnails,
/// click to apply, and toggle span / fill behaviour.
struct ControlPanelView: View {
    @ObservedObject var settings: AppSettings
    /// Called whenever a change should re-render the wallpaper.
    let onApply: () -> Void

    @State private var videos: [URL] = []
    @State private var watcher = FolderWatcher()

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            grid
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            reloadVideos()
            startWatching()
        }
        .onChange(of: settings.libraryFolder) {
            reloadVideos()
            startWatching()
        }
        // The window is created once and only hidden on close, so onAppear
        // never re-fires; rescan whenever the window comes back to front.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in reloadVideos() }
        .onChange(of: settings.spanScreens) { onApply() }
        .onChange(of: settings.fillMode) { onApply() }
    }

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

    private var grid: some View {
        ScrollView {
            if videos.isEmpty {
                ContentUnavailableView("No videos here",
                    systemImage: "film.stack",
                    description: Text("Choose a folder containing .mp4, .mov or .m4v files."))
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(videos, id: \.self) { url in
                        VideoThumb(url: url, isSelected: url == settings.currentVideo)
                            .onTapGesture {
                                settings.currentVideo = url
                                onApply()
                            }
                    }
                }
                .padding(14)
            }
        }
    }

    private func reloadVideos() {
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

/// A single library tile: an auto-generated video thumbnail + filename.
struct VideoThumb: View {
    let url: URL
    let isSelected: Bool
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
