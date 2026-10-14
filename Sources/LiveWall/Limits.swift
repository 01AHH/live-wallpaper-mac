import Foundation

/// Whose plan a limit belongs to.
enum LimitTool: String, CaseIterable, Identifiable {
    case claude, chatGPT

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude:  return "Claude"
        case .chatGPT: return "ChatGPT"
        }
    }
}

/// How much of one plan limit is used, and when it resets.
struct PlanLimit: Equatable, Identifiable {
    let windowMinutes: Int
    let usedPercent: Double
    let resetsAt: Date
    /// When the figure was recorded; it only changes as the AI is used.
    let asOf: Date

    var id: Int { windowMinutes }

    var label: String {
        switch windowMinutes {
        case 10080: return "Week"
        case let m where m % 1440 == 0: return "\(m / 1440) days"
        case let m where m % 60 == 0:   return "\(m / 60) hours"
        default:                        return "\(windowMinutes) min"
        }
    }

    /// Once the reset time has passed, the window has started over.
    var hasReset: Bool { resetsAt <= Date() }
    var currentPercent: Double { hasReset ? 0 : usedPercent }
}

/// Reads the plan limits Claude Code and Codex already record on this Mac:
/// Claude Code's `~/.claude/rate-limit-cache.json`, and the `rate_limits` in
/// Codex's session logs (which the ChatGPT app writes too). No login, no
/// network; the figures are as fresh as the last reply from each.
@MainActor
final class PlanLimitsWatcher {
    var onChange: (([LimitTool: [PlanLimit]]) -> Void)?

    private let claudeCache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/rate-limit-cache.json")
    /// `LIVEWALL_CODEX_SESSIONS` overrides the location (used for testing).
    private let codexRoot = ProcessInfo.processInfo.environment["LIVEWALL_CODEX_SESSIONS"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    private var timer: Timer?
    private var last: [LimitTool: [PlanLimit]] = [:]

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        last = [:]
        onChange?([:])
    }

    func refresh() {
        var limits: [LimitTool: [PlanLimit]] = [:]
        limits[.claude] = claudeLimits()
        limits[.chatGPT] = codexLimits()
        limits = limits.filter { !$0.value.isEmpty }
        guard limits != last else { return }
        last = limits
        onChange?(limits)
    }

    // MARK: Claude Code

    /// `{"five_hour": {"used_percentage": 30, "resets_at": 1791938400}, "seven_day": {…}}`
    private func claudeLimits() -> [PlanLimit] {
        guard let data = try? Data(contentsOf: claudeCache),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let asOf = (try? claudeCache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes in
            guard let window = json[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (window["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return PlanLimit(windowMinutes: minutes, usedPercent: used,
                             resetsAt: Date(timeIntervalSince1970: resets), asOf: asOf)
        }
    }

    // MARK: Codex / ChatGPT

    /// The newest `rate_limits` from the last week's session logs, newest file first.
    private func codexLimits() -> [PlanLimit] {
        for file in recentCodexFiles() {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
            guard let data = try? handle.readToEnd() else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
                guard line.count < 65_536,
                      let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = json["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any] else { continue }
                let asOf = (json["timestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? Date()
                return ["primary", "secondary"].compactMap { key in
                    guard let window = limits[key] as? [String: Any],
                          let used = (window["used_percent"] as? NSNumber)?.doubleValue,
                          let minutes = (window["window_minutes"] as? NSNumber)?.intValue else { return nil }
                    let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                        ?? (window["resets_in_seconds"] as? NSNumber).map { asOf.addingTimeInterval($0.doubleValue) }
                    guard let resets else { return nil }
                    return PlanLimit(windowMinutes: minutes, usedPercent: used, resetsAt: resets, asOf: asOf)
                }
                .sorted { $0.windowMinutes < $1.windowMinutes }
            }
        }
        return []
    }

    private func recentCodexFiles() -> [URL] {
        let calendar = Calendar.current
        var files: [(URL, Date)] = []
        for daysAgo in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = codexRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in items where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((url, modified))
            }
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
