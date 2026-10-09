import AppKit
import ApplicationServices

/// Where an island activity comes from, so each can be switched on or off.
enum IslandSource: String, CaseIterable, Identifiable {
    case music, claudeCode, chatGPT, claudeApp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .music:      return "Music"
        case .claudeCode: return "Claude Code"
        case .chatGPT:    return "ChatGPT & Codex"
        case .claudeApp:  return "Claude app chats"
        }
    }

    var icon: String {
        switch self {
        case .music:      return "music.note"
        case .claudeCode: return "terminal"
        case .chatGPT:    return "bubble.left.and.text.bubble.right"
        case .claudeApp:  return "sparkles"
        }
    }

    /// Which source an activity reported under `name` belongs to; nil means
    /// a third-party tool, which is always shown.
    static func forActivity(named name: String) -> IslandSource? {
        switch name {
        case "Claude Code":       return .claudeCode
        case "ChatGPT", "Codex":  return .chatGPT
        case "Claude":            return .claudeApp
        default:                  return nil
        }
    }
}

// MARK: - Codex / ChatGPT sessions

/// Follows ChatGPT desktop and Codex CLI sessions through the logs they write
/// to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Each turn logs an
/// `event_msg` of type `task_started` and, when the reply is done,
/// `task_complete` (with `last_agent_message`). Reading the logs needs no
/// permissions and doesn't depend on either app's UI.
@MainActor
final class CodexSessionWatcher {
    var onActivity: (([AnyHashable: Any]) -> Void)?

    /// `LIVEWALL_CODEX_SESSIONS` overrides the location (used for testing).
    private let root = ProcessInfo.processInfo.environment["LIVEWALL_CODEX_SESSIONS"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    private var offsets: [URL: UInt64] = [:]
    private var sources: [URL: String] = [:]
    private var lastPrompt: [URL: String] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        scan(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan(initial: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Today's and yesterday's session files touched in the last 15 minutes.
    private func recentFiles() -> [URL] {
        let calendar = Calendar.current
        let fm = FileManager.default
        var files: [URL] = []
        for daysAgo in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in items where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, Date().timeIntervalSince(modified) < 15 * 60 { files.append(url) }
            }
        }
        return files
    }

    private func scan(initial: Bool) {
        for url in recentFiles() {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            let start = offsets[url] ?? 0
            guard end > start else { continue }
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd() else { continue }
            // Only consume complete lines; a partial last line is re-read next time.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let complete = data[data.startIndex...lastNewline]
            offsets[url] = start + UInt64(complete.count)

            var latestState: [AnyHashable: Any]?
            for line in complete.split(separator: UInt8(ascii: "\n")) {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = json["type"] as? String,
                      let payload = json["payload"] as? [String: Any] else { continue }
                if let event = parse(type: type, payload: payload, file: url) { latestState = event }
            }
            // On the first pass only report a session that's mid-turn right
            // now; finished history shouldn't pop up at launch.
            if let latestState, !initial || (latestState["state"] as? String) == "running" {
                onActivity?(latestState)
            }
        }
    }

    private func parse(type: String, payload: [String: Any], file: URL) -> [AnyHashable: Any]? {
        switch type {
        case "session_meta":
            let originator = payload["originator"] as? String ?? ""
            sources[file] = originator.contains("desktop") ? "ChatGPT" : "Codex"
            return nil
        case "response_item":
            if payload["type"] as? String == "message", payload["role"] as? String == "user",
               let content = payload["content"] as? [[String: Any]],
               let text = content.compactMap({ $0["text"] as? String }).last(where: { !$0.hasPrefix("<") }) {
                lastPrompt[file] = text
            }
            return nil
        case "event_msg":
            let id = "codex-" + file.deletingPathExtension().lastPathComponent.suffix(12)
            let source = sources[file] ?? "Codex"
            switch payload["type"] as? String {
            case "user_message":
                if let text = payload["message"] as? String { lastPrompt[file] = text }
                return nil
            case "task_started":
                return ["id": id, "source": source, "state": "running",
                        "title": Self.snippet(lastPrompt[file]) ?? "Working on it"]
            case "task_complete":
                return ["id": id, "source": source, "state": "done",
                        "title": Self.snippet(payload["last_agent_message"] as? String) ?? "Reply ready"]
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func snippet(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 70 ? String(line.prefix(70)) + "…" : line
    }
}

// MARK: - Desktop chat apps (Accessibility)

/// Watches the Claude and ChatGPT desktop apps for a response being written,
/// by looking for their "Stop" button through the Accessibility API — the
/// apps offer no other signal for plain chats. Requires Accessibility
/// permission. Both apps are Chromium-based, which only builds its
/// accessibility tree once asked to via `AXManualAccessibility`.
@MainActor
final class ChatAppWatcher {
    struct App {
        let bundleID: String
        let source: String
    }

    var onActivity: (([AnyHashable: Any]) -> Void)?
    var apps: [App] = []

    private var generating: [String: String] = [:]   // bundle ID → window title
    private var timer: Timer?
    private let queue = DispatchQueue(label: "LiveWall.ChatAppWatcher", qos: .utility)
    private var enabledTrees = Set<pid_t>()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS for Accessibility permission (shows the system prompt once).
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generating.removeAll()
    }

    private func poll() {
        guard Self.isTrusted, !apps.isEmpty else { return }
        let targets = apps.compactMap { app -> (App, pid_t)? in
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first
                .map { (app, $0.processIdentifier) }
        }
        let newPIDs = targets.map(\.1).filter { !enabledTrees.contains($0) }
        enabledTrees.formUnion(newPIDs)

        // The tree walk can take tens of milliseconds; keep it off the main thread.
        queue.async { [weak self] in
            let results = targets.map { app, pid -> (App, String?) in
                let element = AXUIElementCreateApplication(pid)
                if newPIDs.contains(pid) {
                    AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                }
                return (app, Self.generatingWindowTitle(in: element))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.update(results) }
            }
        }
    }

    private func update(_ results: [(App, String?)]) {
        let running = Set(results.map(\.0.bundleID))
        for (app, title) in results {
            let id = "app-" + app.bundleID
            let was = generating[app.bundleID]
            if let title {
                if was == nil {
                    onActivity?(["id": id, "source": app.source, "state": "running", "title": title])
                }
                generating[app.bundleID] = title
            } else if let was {
                generating[app.bundleID] = nil
                onActivity?(["id": id, "source": app.source, "state": "done", "title": was])
            }
        }
        // An app that quit mid-response just stops being tracked.
        for bundleID in generating.keys where !running.contains(bundleID) { generating[bundleID] = nil }
    }

    /// Labels both apps use on the button that stops a response in progress.
    private nonisolated static let stopLabels = ["stop response", "stop generating", "stop streaming", "stop"]

    /// If a window is showing a Stop button, that window's title (the
    /// conversation name); otherwise nil.
    private nonisolated static func generatingWindowTitle(in app: AXUIElement) -> String? {
        func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var result: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        let windows = (value(app, "AXWindows") as? [AXUIElement]) ?? []
        for window in windows {
            var queue = [window]
            var visited = 0
            while !queue.isEmpty && visited < 6000 {
                let element = queue.removeLast()
                visited += 1
                if (value(element, "AXRole") as? String) == "AXButton" {
                    let label = [value(element, "AXDescription"), value(element, "AXTitle")]
                        .compactMap { ($0 as? String)?.lowercased() }
                    if label.contains(where: { stopLabels.contains($0) }) {
                        let title = (value(window, "AXTitle") as? String) ?? ""
                        return title.isEmpty ? "Writing a response" : title
                    }
                }
                queue += (value(element, "AXChildren") as? [AXUIElement]) ?? []
            }
        }
        return nil
    }
}
