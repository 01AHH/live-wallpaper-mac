import AppKit
import Foundation

/// A music app LiveWall can follow and control. Both broadcast track changes
/// as distributed notifications, so following them needs no permissions;
/// controlling them goes through AppleScript (macOS asks once per app).
enum MusicApp: String {
    case spotify = "Spotify"
    case music = "Music"

    var notification: Notification.Name {
        switch self {
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music:   return Notification.Name("com.apple.Music.playerInfo")
        }
    }
}

struct NowPlaying: Equatable {
    var app: MusicApp
    var title: String
    var artist: String
    var album: String?
    var isPlaying: Bool
    var trackID: String?
}

/// A long-running task reported by another tool — typically an AI agent such
/// as Claude Code — through LiveWall's activity notification.
struct LiveActivity: Equatable, Identifiable {
    enum State: String { case running, done, attention }

    let id: String
    var source: String
    var title: String
    var detail: String?
    var state: State
    var updated = Date()
}

/// Collects everything the Dynamic Island can show besides the wallpaper:
/// what's playing in Spotify or Music, and activities other tools report.
///
/// Any tool can report an activity by posting the distributed notification
/// `com.livewall.activity` with string keys `id`, `source`, `title`, `state`
/// (`running` / `done` / `attention`) and optional `detail` — see
/// `scripts/livewall-activity`.
@MainActor
final class ActivityCenter: ObservableObject {
    static let activityNotification = Notification.Name("com.livewall.activity")

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var activities: [LiveActivity] = []

    /// Something worth announcing happened (new track, task finished…).
    var onEvent: ((IslandEvent) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var artworkKey: String?

    init() {
        let center = DistributedNotificationCenter.default()
        for app in [MusicApp.spotify, .music] {
            observers.append(center.addObserver(forName: app.notification, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.musicChanged(app: app, info: info) }
            })
        }
        observers.append(center.addObserver(forName: Self.activityNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.activityReported(info) }
        })
    }

    /// The most important running activity, if any.
    var currentActivity: LiveActivity? {
        activities.first { $0.state == .attention } ?? activities.first { $0.state == .running }
    }

    var isMusicPlaying: Bool { nowPlaying?.isPlaying == true }

    // MARK: - Music

    private func musicChanged(app: MusicApp, info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? "Stopped"
        guard state != "Stopped", let title = info["Name"] as? String else {
            if nowPlaying?.app == app { nowPlaying = nil; artwork = nil }
            return
        }
        let track = NowPlaying(app: app, title: title,
                               artist: info["Artist"] as? String ?? "",
                               album: info["Album"] as? String,
                               isPlaying: state == "Playing",
                               trackID: info["Track ID"] as? String)
        let isNewTrack = track.title != nowPlaying?.title || track.artist != nowPlaying?.artist
        nowPlaying = track

        if isNewTrack {
            Task {
                await loadArtwork(for: track)
                if track.isPlaying {
                    onEvent?(IslandEvent(icon: "music.note", title: track.title,
                                         subtitle: track.artist, image: artwork))
                }
            }
        }
    }

    /// Spotify's artwork comes from its public oEmbed endpoint; Music's from
    /// the iTunes Search API by artist and album. Neither needs a login.
    private func loadArtwork(for track: NowPlaying) async {
        let key = "\(track.artist)|\(track.album ?? track.title)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil

        var imageURL: URL?
        if track.app == .spotify, let id = track.trackID, id.hasPrefix("spotify:track:") {
            let trackURL = "https://open.spotify.com/track/" + id.dropFirst("spotify:track:".count)
            var oembed = URLComponents(string: "https://open.spotify.com/oembed")!
            oembed.queryItems = [URLQueryItem(name: "url", value: trackURL)]
            if let data = try? await URLSession.shared.data(from: oembed.url!).0,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let thumb = json["thumbnail_url"] as? String {
                imageURL = URL(string: thumb)
            }
        } else {
            var search = URLComponents(string: "https://itunes.apple.com/search")!
            search.queryItems = [URLQueryItem(name: "term", value: "\(track.artist) \(track.album ?? track.title)"),
                                 URLQueryItem(name: "entity", value: "album"),
                                 URLQueryItem(name: "limit", value: "1")]
            if let data = try? await URLSession.shared.data(from: search.url!).0,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let first = (json["results"] as? [[String: Any]])?.first,
               let art = first["artworkUrl100"] as? String {
                imageURL = URL(string: art.replacingOccurrences(of: "100x100", with: "600x600"))
            }
        }
        guard artworkKey == key, let imageURL,
              let data = try? await URLSession.shared.data(from: imageURL).0 else { return }
        artwork = NSImage(data: data)
    }

    enum MusicCommand: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    func send(_ command: MusicCommand) {
        guard let app = nowPlaying?.app else { return }
        let source = "tell application \"\(app.rawValue)\" to \(command.rawValue)"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("LiveWall: music control failed: \(error)") }
        }
    }

    // MARK: - Activities

    private func activityReported(_ info: [AnyHashable: Any]) {
        guard let title = info["title"] as? String else { return }
        let source = info["source"] as? String ?? "Activity"
        let id = info["id"] as? String ?? source
        let state = LiveActivity.State(rawValue: info["state"] as? String ?? "") ?? .running
        let activity = LiveActivity(id: id, source: source, title: title,
                                    detail: info["detail"] as? String, state: state)

        let previous = activities.first { $0.id == id }
        activities.removeAll { $0.id == id }
        activities.insert(activity, at: 0)

        // Announce changes of state, not every progress update.
        if previous?.state != state {
            switch state {
            case .running:
                onEvent?(IslandEvent(icon: "sparkles", title: title, subtitle: source))
            case .attention:
                onEvent?(IslandEvent(icon: "exclamationmark.bubble.fill", title: title,
                                     subtitle: "\(source) needs you", duration: 6))
            case .done:
                onEvent?(IslandEvent(icon: "checkmark.circle.fill", title: title,
                                     subtitle: "\(source) finished", duration: 4))
            }
        }

        // Finished activities linger briefly, then clear.
        if state == .done {
            Task {
                try? await Task.sleep(for: .seconds(8))
                activities.removeAll { $0.id == id && $0.state == .done }
            }
        }
    }
}
