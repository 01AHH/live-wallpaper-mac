import Foundation

/// How the video is scaled into each screen / the spanning canvas.
enum FillMode: String, CaseIterable, Identifiable, Codable {
    case fill   // resizeAspectFill — no bars, crops overflow
    case fit    // resizeAspect     — whole frame, letterbox bars
    case stretch // resize          — fills exactly, distorts aspect ratio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill:    return "Fill"
        case .fit:     return "Fit"
        case .stretch: return "Stretch"
        }
    }

    var label: String {
        switch self {
        case .fill:    return "Fill (crop)"
        case .fit:     return "Fit (bars)"
        case .stretch: return "Stretch (distort)"
        }
    }
}

/// Observable, persisted app state. Mutating any property writes through to
/// UserDefaults; the AppDelegate watches these to rebuild the wallpaper.
final class AppSettings: ObservableObject {
    @Published var libraryFolder: URL? { didSet { persist() } }
    @Published var currentVideo: URL?  { didSet { persist() } }
    @Published var spanScreens: Bool   { didSet { persist() } }
    @Published var fillMode: FillMode  { didSet { persist() } }
    /// Playback speed per video, keyed by filename (like categories.json),
    /// so each wallpaper remembers its own pace. Missing means 1×.
    @Published private(set) var speeds: [String: Double] { didSet { persist() } }

    /// Whether the Dynamic Island is shown at the top of the screen.
    @Published var showIsland: Bool { didSet { persist() } }

    static let speedRange: ClosedRange<Double> = 0.25...1.5

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
        speeds        = defaults.dictionary(forKey: Keys.speeds) as? [String: Double] ?? [:]
        showIsland    = defaults.object(forKey: Keys.showIsland) as? Bool ?? true
    }

    func speed(for url: URL?) -> Double {
        guard let url else { return 1 }
        return speeds[url.lastPathComponent] ?? 1
    }

    func setSpeed(_ speed: Double, for url: URL) {
        let clamped = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        // Store only non-default speeds so the dictionary stays small.
        speeds[url.lastPathComponent] = abs(clamped - 1) < 0.001 ? nil : clamped
    }

    private func persist() {
        defaults.set(libraryFolder, forKey: Keys.libraryFolder)
        defaults.set(currentVideo, forKey: Keys.currentVideo)
        defaults.set(spanScreens, forKey: Keys.spanScreens)
        defaults.set(fillMode.rawValue, forKey: Keys.fillMode)
        defaults.set(speeds, forKey: Keys.speeds)
        defaults.set(showIsland, forKey: Keys.showIsland)
    }

    private enum Keys {
        static let libraryFolder = "libraryFolder"
        static let currentVideo  = "currentVideo"
        static let spanScreens   = "spanScreens"
        static let fillMode      = "fillMode"
        static let speeds        = "videoSpeeds"
        static let showIsland    = "showDynamicIsland"
    }
}
