import Foundation

/// How the video is scaled into each screen / the spanning canvas.
enum FillMode: String, CaseIterable, Identifiable, Codable {
    case fill   // resizeAspectFill — no bars, crops overflow
    case fit    // resizeAspect     — whole frame, letterbox bars

    var id: String { rawValue }
    var label: String { self == .fill ? "Fill (crop)" : "Fit (bars)" }
}

/// Observable, persisted app state. Mutating any property writes through to
/// UserDefaults; the AppDelegate watches these to rebuild the wallpaper.
final class AppSettings: ObservableObject {
    @Published var libraryFolder: URL? { didSet { persist() } }
    @Published var currentVideo: URL?  { didSet { persist() } }
    @Published var spanScreens: Bool   { didSet { persist() } }
    @Published var fillMode: FillMode  { didSet { persist() } }

    private let defaults = UserDefaults.standard

    init() {
        // Sensible first-run defaults pointing at the user's wallpaper folder.
        let media = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Projects/LiveWall/Media", isDirectory: true)

        libraryFolder = defaults.url(forKey: Keys.libraryFolder) ?? media
        currentVideo  = defaults.url(forKey: Keys.currentVideo)
            ?? media.appendingPathComponent("golden-field.mp4")
        spanScreens   = defaults.object(forKey: Keys.spanScreens) as? Bool ?? true
        fillMode      = FillMode(rawValue: defaults.string(forKey: Keys.fillMode) ?? "") ?? .fill
    }

    private func persist() {
        defaults.set(libraryFolder, forKey: Keys.libraryFolder)
        defaults.set(currentVideo, forKey: Keys.currentVideo)
        defaults.set(spanScreens, forKey: Keys.spanScreens)
        defaults.set(fillMode.rawValue, forKey: Keys.fillMode)
    }

    private enum Keys {
        static let libraryFolder = "libraryFolder"
        static let currentVideo  = "currentVideo"
        static let spanScreens   = "spanScreens"
        static let fillMode      = "fillMode"
    }
}
