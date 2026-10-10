import SwiftUI

/// One wallpaper from the online gallery's `catalog.json`.
struct GalleryWallpaper: Decodable, Identifiable, Hashable {
    struct Licence: Decodable, Hashable { let name: String; let url: URL? }

    let id: String
    let title: String
    let description: String
    let tags: [String]
    let credit: String
    let licence: Licence
    let video: URL
    let poster: URL
    let bytes: Int
    /// The licence hasn't been checked — shown with a warning.
    let unverified: Bool?

    var isUnverified: Bool { unverified == true }

    /// The file name it's saved under in the library.
    var fileName: String { "\(id).mp4" }
}

/// Loads the online catalog and downloads wallpapers into the library.
@MainActor
final class GalleryStore: NSObject, ObservableObject {
    static let catalogURL = URL(string: "https://livewallpapermac.vercel.app/catalog.json")!
    /// Download counts and votes shown on the website (web/stats).
    static let statsURL = URL(string: "https://livewall-stats.livewall-gallery.workers.dev")!

    /// Count a download made from inside the app, so the website's "Most
    /// downloaded" reflects it. (Downloads started from the website are
    /// already counted there.)
    func recordDownload(_ wallpaper: GalleryWallpaper) {
        var request = URLRequest(url: Self.statsURL.appendingPathComponent("download"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": [wallpaper.id]])
        URLSession.shared.dataTask(with: request).resume()
    }

    @Published private(set) var wallpapers: [GalleryWallpaper] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// Download progress (0…1) for wallpapers currently downloading.
    @Published private(set) var progress: [String: Double] = [:]

    private var tasks: [Int: (GalleryWallpaper, URL)] = [:]
    private var completions: [Int: (Result<URL, Error>) -> Void] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func load() async {
        guard wallpapers.isEmpty, !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.catalogURL)
            struct Catalog: Decodable { let wallpapers: [GalleryWallpaper] }
            wallpapers = try JSONDecoder().decode(Catalog.self, from: data).wallpapers
        } catch {
            self.error = "Couldn't reach the gallery. Check your connection and try again."
        }
    }

    func retry() async {
        wallpapers = []
        await load()
    }

    /// Download into `folder`, reporting progress; calls back with the saved file.
    func download(_ wallpaper: GalleryWallpaper, into folder: URL,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        guard progress[wallpaper.id] == nil else { return }
        progress[wallpaper.id] = 0
        let task = session.downloadTask(with: wallpaper.video)
        tasks[task.taskIdentifier] = (wallpaper, folder.appendingPathComponent(wallpaper.fileName))
        completions[task.taskIdentifier] = completion
        task.resume()
    }
}

extension GalleryStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData _: Int64, totalBytesWritten written: Int64,
                                totalBytesExpectedToWrite expected: Int64) {
        MainActor.assumeIsolated {
            guard let (wallpaper, _) = tasks[downloadTask.taskIdentifier] else { return }
            let total = expected > 0 ? Double(expected) : Double(wallpaper.bytes)
            progress[wallpaper.id] = min(Double(written) / max(total, 1), 1)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so move it now.
        MainActor.assumeIsolated {
            guard let (_, destination) = tasks[downloadTask.taskIdentifier] else { return }
            let result = Result {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                return destination
            }
            finish(downloadTask.taskIdentifier, result)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated { finish(task.taskIdentifier, .failure(error)) }
    }

    private func finish(_ id: Int, _ result: Result<URL, Error>) {
        guard let (wallpaper, _) = tasks.removeValue(forKey: id) else { return }
        progress[wallpaper.id] = nil
        completions.removeValue(forKey: id)?(result)
    }
}

/// The "Online Gallery" page: openly licensed wallpapers to add to the library.
struct OnlineGalleryView: View {
    @ObservedObject var store: GalleryStore
    /// File names already in the library, to show "In Library".
    let libraryFiles: Set<String>
    let onDownload: (GalleryWallpaper) -> Void
    let onUse: (GalleryWallpaper) -> Void

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: Brand.Spacing.gridColumn)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Online Gallery").font(Brand.Font.section)
                Text("Free 4K wallpapers, each public domain or openly licensed and credited to its source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if store.isLoading && store.wallpapers.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("Gallery unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await store.retry() } }.buttonStyle(.glassProminent)
                }
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: Brand.Spacing.gridRow) {
                    ForEach(store.wallpapers) { wallpaper in
                        tile(wallpaper)
                    }
                }
            }
        }
        .task { await store.load() }
    }

    private func tile(_ w: GalleryWallpaper) -> some View {
        let inLibrary = libraryFiles.contains(w.fileName)
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: w.poster) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.white.opacity(0.06))
                    }
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(.white.opacity(0.08)) }
                .overlay(alignment: .bottomTrailing) { action(for: w, inLibrary: inLibrary).padding(10) }

            Text(w.title).font(Brand.Font.tileTitle).lineLimit(1)
            if w.isUnverified {
                Label("Licence unverified", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Brand.accent)
                    .help("This wallpaper's source and licence haven't been checked — you may need a licence to use it.")
            } else {
                Text("\(w.credit) · \(w.licence.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(w.credit) — \(w.licence.name)")
            }
        }
    }

    @ViewBuilder
    private func action(for w: GalleryWallpaper, inLibrary: Bool) -> some View {
        if let progress = store.progress[w.id] {
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 70)
                Text("\(Int(progress * 100))%").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .environment(\.colorScheme, .dark)
        } else if inLibrary {
            Button { onUse(w) } label: { Label("Use", systemImage: "play.fill") }
                .buttonStyle(.glass)
                .environment(\.colorScheme, .dark)
        } else {
            Button { onDownload(w) } label: {
                Label("Get · \(w.bytes / 1_000_000) MB", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.glassProminent)
        }
    }
}
