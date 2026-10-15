import AppKit
import ApplicationServices

/// Where an island activity comes from, so each can be switched on or off.
enum IslandSource: String, CaseIterable, Identifiable {
    case music, claudeCode, chatGPT, claudeApp
    /// Not a source of activities itself: how much of the Claude and ChatGPT
    /// plan limits is used. Off unless chosen. (Saved as "usage".)
    case planLimits = "usage"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .music:      return "Music"
        case .claudeCode: return "Claude Code"
        case .chatGPT:    return "ChatGPT & Codex"
        case .claudeApp:  return "Claude app chats"
        case .planLimits: return "Claude & ChatGPT plan limits"
        }
    }

    var icon: String {
        switch self {
        case .music:      return "music.note"
        case .claudeCode: return "terminal"
        case .chatGPT:    return "bubble.left.and.text.bubble.right"
        case .claudeApp:  return "sparkles"
        case .planLimits: return "gauge.with.dots.needle.50percent"
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
            // Desktop sessions open the ChatGPT app on click; the CLI's
            // terminal isn't recorded in the log, so those can't be opened.
            let app = source == "ChatGPT" ? "com.openai.codex" : ""
            switch payload["type"] as? String {
            case "user_message":
                if let text = payload["message"] as? String { lastPrompt[file] = text }
                return nil
            case "task_started":
                return ["id": id, "source": source, "state": "running", "app": app,
                        "title": Self.snippet(lastPrompt[file]) ?? "Working on it"]
            case "task_complete":
                return ["id": id, "source": source, "state": "done", "app": app,
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

/// Watches the Claude and ChatGPT desktop apps for chats writing a response,
/// through the Accessibility API — the apps offer no other signal for plain
/// chats. Claude's sidebar marks every chat that's writing as "Running", so
/// each one shows, even those in the background; otherwise (ChatGPT, or
/// Claude with its sidebar hidden) a "Stop" button gives away the chat on
/// screen. Requires Accessibility permission. Both apps are Chromium-based,
/// which only builds its accessibility tree once asked to via
/// `AXManualAccessibility`.
@MainActor
final class ChatAppWatcher {
    struct App {
        let bundleID: String
        let source: String
    }

    var onActivity: (([AnyHashable: Any]) -> Void)?
    /// An activity this watcher reported no longer applies.
    var onClear: ((String) -> Void)?
    var apps: [App] = []

    private var generating: [String: (app: App, chat: String)] = [:]   // activity ID → chat
    private var reportedMissingPermission = false
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
        reportedMissingPermission = false
    }

    private static let permissionActivityID = "app-accessibility"

    private func poll() {
        guard !apps.isEmpty else { return }
        guard Self.isTrusted else { reportMissingPermission(); return }
        if reportedMissingPermission {
            reportedMissingPermission = false
            onClear?(Self.permissionActivityID)
        }
        let targets = apps.compactMap { app -> (App, pid_t)? in
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first
                .map { (app, $0.processIdentifier) }
        }
        let newPIDs = targets.map(\.1).filter { !enabledTrees.contains($0) }
        enabledTrees.formUnion(newPIDs)

        // The tree walk can take tens of milliseconds; keep it off the main thread.
        queue.async { [weak self] in
            let results = targets.map { app, pid -> (App, [String]) in
                let element = AXUIElementCreateApplication(pid)
                if newPIDs.contains(pid) {
                    AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                }
                return (app, Self.generatingChats(in: element))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.update(results) }
            }
        }
    }

    /// Without Accessibility, Claude chats can't be seen at all. macOS also
    /// drops the permission whenever an unsigned build of LiveWall changes,
    /// while System Settings still shows it as on, so say so in the island
    /// rather than going quiet. (ChatGPT works from its logs regardless.)
    private func reportMissingPermission() {
        guard !reportedMissingPermission, apps.contains(where: { $0.source == "Claude" }) else { return }
        reportedMissingPermission = true
        onActivity?(["id": Self.permissionActivityID, "source": "Claude", "state": "attention",
                     "title": "Allow Accessibility to see your chats",
                     "url": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
    }

    private func update(_ results: [(App, [String])]) {
        var seen = Set<String>()
        for (app, chats) in results {
            for chat in chats {
                let id = "app-\(app.bundleID)-\(chat)"
                seen.insert(id)
                if generating[id] == nil {
                    onActivity?(["id": id, "source": app.source, "state": "running", "title": chat,
                                 "app": app.bundleID, "window": chat])
                }
                generating[id] = (app, chat)
            }
        }
        let running = Set(results.map(\.0.bundleID))
        for (id, entry) in generating where !seen.contains(id) {
            generating[id] = nil
            if running.contains(entry.app.bundleID) {
                onActivity?(["id": id, "source": entry.app.source, "state": "done", "title": entry.chat,
                             "app": entry.app.bundleID, "window": entry.chat])
            } else {
                // The app quit mid-response, so the chat won't finish.
                onClear?(id)
            }
        }
    }

    /// Bring a chat to the front: raise the window titled after it, and where
    /// the chat is listed in the app's sidebar, open it from there. Needs
    /// Accessibility; without it the app just comes forward as it was.
    static func focus(chat: String, of pid: pid_t) {
        guard isTrusted else { return }
        let app = AXUIElementCreateApplication(pid)
        raiseWindow(titled: chat, in: app)
        if let row = sidebarRow(named: chat, in: app) {
            AXUIElementPerformAction(row, kAXPressAction as CFString)
        }
    }

    /// Raise the window whose title matches (or contains) `title`, so a
    /// click lands on the right chat or terminal.
    private static func raiseWindow(titled title: String, in app: AXUIElement) {
        let windows = (value(app, "AXWindows") as? [AXUIElement]) ?? []
        let wanted = title.lowercased()
        let titled = windows.map { ($0, ((value($0, "AXTitle") as? String) ?? "").lowercased()) }
        guard let match = titled.first(where: { $0.1 == wanted })
                ?? titled.first(where: { !$0.1.isEmpty && $0.1.contains(wanted) }) else { return }
        AXUIElementPerformAction(match.0, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(match.0, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Labels both apps use on the button that stops a response in progress.
    private nonisolated static let stopLabels = ["stop response", "stop generating", "stop streaming", "stop"]
    /// What Claude's sidebar calls a chat that's writing a response.
    private nonisolated static let runningStatus = "running"
    /// Claude titles its chat page "<chat name> - Claude".
    private nonisolated static let pageTitleSuffix = " - Claude"

    private nonisolated static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    /// The chats writing a response right now, by name: every sidebar row
    /// marked "Running", plus the chat on screen if it shows a Stop button
    /// (named after its page, or failing that its window).
    private nonisolated static func generatingChats(in app: AXUIElement) -> [String] {
        var chats: [String] = []
        let windows = (value(app, "AXWindows") as? [AXUIElement]) ?? []
        for window in windows {
            var queue = [(element: window, inSidebar: false)]
            var visited = 0
            var pageTitle: String?
            var showsStop = false
            while !queue.isEmpty && visited < 6000 {
                let (element, inSidebar) = queue.removeLast()
                visited += 1
                let role = value(element, "AXRole") as? String
                let title = (value(element, "AXTitle") as? String) ?? ""
                if role == "AXWebArea", title.hasSuffix(pageTitleSuffix) {
                    pageTitle = String(title.dropLast(pageTitleSuffix.count))
                }
                if role == "AXButton" {
                    if inSidebar, !title.isEmpty, let row = rowContents(element) {
                        if row.status == runningStatus { chats.append(row.name) }
                        continue
                    }
                    let label = [value(element, "AXDescription") as? String, title]
                        .compactMap { $0?.lowercased() }
                    if label.contains(where: { stopLabels.contains($0) }) { showsStop = true }
                }
                let isSidebar = (value(element, "AXSubrole") as? String) == "AXLandmarkComplementary"
                    && (value(element, "AXDescription") as? String) == "Sidebar"
                let children = (value(element, "AXChildren") as? [AXUIElement]) ?? []
                queue += children.map { ($0, inSidebar || isSidebar) }
            }
            if showsStop {
                let windowTitle = (value(window, "AXTitle") as? String) ?? ""
                let name = pageTitle ?? (windowTitle.isEmpty ? "Writing a response" : windowTitle)
                if !chats.contains(name) { chats.append(name) }
            }
        }
        return chats
    }

    /// A chat row in Claude's sidebar: a button holding a status icon
    /// ("Running", "Done", "Unread response"…) and the chat's name as its
    /// first text.
    private nonisolated static func rowContents(_ row: AXUIElement) -> (name: String, status: String)? {
        var name: String?
        var status: String?
        var queue = [(row, 0)]
        while let (element, depth) = queue.popLast() {
            let role = value(element, "AXRole") as? String
            if role == "AXStaticText", name == nil, let text = value(element, "AXValue") as? String, !text.isEmpty {
                name = text
            }
            if status == nil, role == "AXImage" || (value(element, "AXSubrole") as? String) == "AXApplicationStatus",
               let label = value(element, "AXDescription") as? String, !label.isEmpty {
                status = label.lowercased()
            }
            guard depth < 3 else { continue }
            // Reversed so the first child is looked at first.
            queue += ((value(element, "AXChildren") as? [AXUIElement]) ?? []).reversed().map { ($0, depth + 1) }
        }
        guard let name, let status else { return nil }
        return (name, status)
    }

    /// The sidebar row for the chat called `name`, if the sidebar is showing.
    private static func sidebarRow(named name: String, in app: AXUIElement) -> AXUIElement? {
        var queue = (value(app, "AXWindows") as? [AXUIElement]) ?? []
        var visited = 0
        while !queue.isEmpty && visited < 6000 {
            let element = queue.removeLast()
            visited += 1
            if (value(element, "AXRole") as? String) == "AXButton",
               !((value(element, "AXTitle") as? String) ?? "").isEmpty,
               rowContents(element)?.name == name {
                return element
            }
            queue += (value(element, "AXChildren") as? [AXUIElement]) ?? []
        }
        return nil
    }
}
