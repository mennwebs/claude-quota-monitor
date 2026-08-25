import Foundation

// MARK: - Paths

enum Paths {
    static let appSupport: URL = {
        let base = ProcessInfo.processInfo.environment["CQM_HOME"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("Library/Application Support")
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ClaudeQuotaMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static var state:    URL { appSupport.appendingPathComponent("state.json") }
    static var settings: URL { appSupport.appendingPathComponent("settings.json") }
    static var token:    URL { appSupport.appendingPathComponent("token") }
    /// Written by the statusline shim on every Claude Code render.
    static var cliDump:  URL { appSupport.appendingPathComponent("cli.json") }

    /// `NSHomeDirectory()` ignores `$HOME`, which makes anything that writes into the
    /// home directory impossible to test without touching the real one. `CQM_HOME`
    /// exists for that: it is only read here, and only set by the test script.
    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["CQM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
    static var claudeConfig: URL { home.appendingPathComponent(".claude.json") }
    static var statsCache: URL { home.appendingPathComponent(".claude/stats-cache.json") }
}

// MARK: - JSON

enum JSONIO {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Write via a temp file in the same directory so a crash mid-write cannot
    /// leave a truncated state file behind.
    static func atomicWrite(_ data: Data, to url: URL, mode: Int16 = 0o600) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

/// Claude's APIs are inconsistent about time: the statusline hands over unix
/// seconds, the web API an ISO-8601 string. Accept both, plus millisecond epochs.
func parseFlexibleDate(_ value: Any?) -> Date? {
    switch value {
    case let n as Double where n > 0:
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    case let n as Int where n > 0:
        let d = Double(n)
        return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
    case let s as String where !s.isEmpty:
        if let n = Double(s) { return parseFlexibleDate(n) }
        return ISO8601DateFormatter.cqmFractional.date(from: s)
            ?? ISO8601DateFormatter.cqmPlain.date(from: s)
    default:
        return nil
    }
}

extension ISO8601DateFormatter {
    static let cqmFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let cqmPlain = ISO8601DateFormatter()
}

// MARK: - Settings

struct AppSettings: Codable, Equatable, Sendable {
    var port: UInt16 = 47821
    var labels: [String: String] = [:]        // account key → user-chosen name
    var hidden: Set<String> = []              // account keys the user removed from the panel
    var order: [String] = []                  // explicit panel order, keys not listed sort after
    var thresholds = FreshnessThresholds()
    var showPercentInMenuBar = true
    var readCLIStatusline = true
    var readStatsCache = true

    static func load() -> AppSettings {
        guard let d = try? Data(contentsOf: Paths.settings),
              let s = try? JSONIO.decoder.decode(AppSettings.self, from: d)
        else { return AppSettings() }
        return s
    }

    func save() {
        guard let d = try? JSONIO.encoder.encode(self) else { return }
        try? JSONIO.atomicWrite(d, to: Paths.settings)
    }
}

// MARK: - Shared token

/// A single local secret, generated once. It exists so that a random page which
/// manages to reach the loopback port cannot inject fake numbers — the data is
/// not secret, but the display should not be forgeable.
enum TokenStore {
    static func loadOrCreate() -> String {
        if let s = try? String(contentsOf: Paths.token, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 16 { return t }
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? JSONIO.atomicWrite(Data(token.utf8), to: Paths.token)
        return token
    }
}

// MARK: - Formatting

enum Fmt {
    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// Time left, coarse on purpose: minutes matter near a reset, hours do not.
    static func countdown(to date: Date, from now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "ครบแล้ว" }
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Wall-clock reset point: bare time when it lands today, weekday when it does not.
    static func clock(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "th_TH")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 10 { return "เมื่อกี้" }
        if s < 60 { return "\(s) วิที่แล้ว" }
        let m = s / 60
        if m < 60 { return "\(m) นาทีที่แล้ว" }
        let h = m / 60
        if h < 24 { return "\(h) ชม.\(m % 60 > 0 ? " \(m % 60) นาที" : "")ที่แล้ว" }
        return "\(h / 24) วันที่แล้ว"
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return "\(n / 1000)k" }
        return "\(n)"
    }

    /// `default_claude_max_5x` → `Max 5x`. Unknown tiers pass through readably
    /// rather than being hidden, so a new plan name still shows something true.
    static func plan(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "default_", with: "")
        switch s {
        case "free":  return "Free"
        case "pro":   return "Pro"
        case "team", "claude_team": return "Team"
        default: break
        }
        if s.hasPrefix("claude_max") || s.hasPrefix("max") {
            let mult = s.contains("20x") ? "20x" : s.contains("5x") ? "5x" : nil
            return mult.map { "Max \($0)" } ?? "Max"
        }
        return s.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Must match the keys Claude Code writes into stats-cache.json, which are plain
    /// Gregorian ISO dates. `Locale.current` on a Thai-configured Mac carries the
    /// Buddhist calendar, so an unpinned formatter yields "2569-08-25" — every lookup
    /// misses and the cache looks permanently out of date.
    static var todayKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
