import Foundation

// MARK: - Limits

/// Limit identities as they travel on the wire.
///
/// The set is open-ended on purpose. claude.ai moved per-model weekly caps out of fixed
/// `seven_day_opus`-style fields — which now return null — into a dynamic `limits` array,
/// so Fable showed up unannounced and the next model will too. Only the two structural
/// ceilings are named here; every model cap is `weekly:<slug>` and carries its own label.
enum LimitID {
    static let fiveHour = "five_hour"
    static let sevenDay = "seven_day"
    static let weeklyPrefix = "weekly:"

    static func isWellKnown(_ raw: String) -> Bool { raw == fiveHour || raw == sevenDay }

    /// An open key space still needs a shape, or a malformed report could invent rows.
    static func isAcceptable(_ raw: String) -> Bool {
        if isWellKnown(raw) { return true }
        guard raw.hasPrefix(weeklyPrefix) else { return false }
        let slug = raw.dropFirst(weeklyPrefix.count)
        guard !slug.isEmpty, slug.count <= 32 else { return false }
        return slug.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" }
    }

    /// Extension builds before the dynamic-limits change still send these.
    static let legacyAliases: [String: (id: String, label: String)] = [
        "seven_day_opus":   (weeklyPrefix + "opus", "Opus"),
        "seven_day_sonnet": (weeklyPrefix + "sonnet", "Sonnet"),
        "seven_day_design": (weeklyPrefix + "design", "Design")
    ]
}

/// One limit, ready to render: its wire key plus the reading behind it.
struct Limit: Identifiable, Equatable, Sendable {
    let id: String
    let reading: LimitReading

    /// What the row is called. Model caps use the name the API gave them, so a model this
    /// code has never heard of still labels itself correctly.
    var short: String {
        switch id {
        case LimitID.fiveHour: return "5h"
        case LimitID.sevenDay: return "7d"
        default:
            if let label = reading.label, !label.isEmpty { return label }
            return String(id.dropFirst(LimitID.weeklyPrefix.count)).capitalized
        }
    }

    /// Panel order: the 5-hour window first, because it is the one that stops you today.
    var rank: Int {
        switch id {
        case LimitID.fiveHour: return 0
        case LimitID.sevenDay: return 1
        default: return 2
        }
    }
}

enum ReadingSource: String, Codable, Sendable {
    case ext = "extension"   // Chrome extension talking to claude.ai
    case cli = "cli"         // statusline shim on this machine

    var badge: String { self == .cli ? "CLI" : "web" }
}

/// One percentage for one limit, stamped with when it was actually observed —
/// not when we happened to store it. Merging is decided on `observedAt`, so a slow
/// POST can never overwrite a newer reading that arrived first.
struct LimitReading: Codable, Equatable, Sendable {
    var pct: Double
    var resetsAt: Date?
    var observedAt: Date
    var source: ReadingSource
    /// Display name for a per-model cap, as the API worded it. nil for the two
    /// well-known ceilings, which name themselves.
    var label: String?

    /// A window that is past its reset is empty again, even though nobody has
    /// confirmed it yet. Callers should mark this state visually rather than
    /// pass it off as a real reading.
    func expired(at now: Date) -> Bool {
        guard let r = resetsAt else { return false }
        return now >= r
    }

    func effectivePct(at now: Date) -> Double { expired(at: now) ? 0 : pct }

    /// Each limit ages on its own clock. The two sources cover different limits — the
    /// status line never reports Opus — so an account can be refreshed every second
    /// while its Opus number quietly goes hours stale. Dimming the row by the account's
    /// newest reading would present that stale number as current.
    func freshness(at now: Date, thresholds: FreshnessThresholds) -> Freshness {
        Freshness.of(now.timeIntervalSince(observedAt), thresholds: thresholds)
    }
}

// MARK: - Freshness

/// How much to trust a number, purely as a function of age. The panel greys out
/// anything past `.stale` instead of quietly presenting hours-old data as current.
enum Freshness: Int, Comparable, Sendable {
    case fresh = 0   // < 3 min
    case aging = 1   // < 30 min
    case stale = 2   // < 3 h
    case dead  = 3   // older

    static func < (a: Freshness, b: Freshness) -> Bool { a.rawValue < b.rawValue }

    static func of(_ age: TimeInterval, thresholds t: FreshnessThresholds) -> Freshness {
        if age < t.fresh { return .fresh }
        if age < t.aging { return .aging }
        if age < t.stale { return .stale }
        return .dead
    }

    /// Opacity multiplier applied to the bar fill and the text.
    var dim: Double {
        switch self {
        case .fresh: return 1.0
        case .aging: return 0.82
        case .stale: return 0.55
        case .dead:  return 0.34
        }
    }

    /// Past `.aging` we stop claiming the number is exact.
    var needsTilde: Bool { self >= .stale }
}

struct FreshnessThresholds: Codable, Equatable, Sendable {
    var fresh: TimeInterval = 3 * 60
    var aging: TimeInterval = 30 * 60
    var stale: TimeInterval = 3 * 3600
}

// MARK: - Extra usage credits

struct ExtraUsage: Codable, Equatable, Sendable {
    var enabled: Bool
    var used: Double
    var limit: Double
    var currency: String?
    var observedAt: Date

    var pct: Double { limit > 0 ? min(100, used / limit * 100) : 0 }
}

// MARK: - Account

/// Everything we know about one Claude account, merged from every source that
/// reported it. The extension and the CLI describe the *same* quota from two
/// angles, so they land in one row rather than two.
struct AccountSnapshot: Codable, Identifiable, Equatable, Sendable {
    var key: String                       // "acct:<uuid>" | "org:<uuid>"
    var accountUuid: String?
    var email: String?
    var orgId: String?
    var orgName: String?
    var plan: String?
    var browsers: [String] = []           // which browsers have reported this account
    var sawCLI: Bool = false
    var limits: [String: LimitReading] = [:]
    var extra: ExtraUsage?
    var firstSeen: Date = .distantPast

    var id: String { key }

    /// Newest observation across every limit — the row's overall age.
    var observedAt: Date? {
        limits.values.map(\.observedAt).max()
    }

    var orderedLimits: [Limit] {
        limits.map { Limit(id: $0.key, reading: $0.value) }
            .sorted { ($0.rank, $0.short) < ($1.rank, $1.short) }
    }

    /// The ceiling closest to blocking you. Weekly Opus routinely binds before the
    /// 5-hour window does, so "how full am I" cannot just read `five_hour`.
    func binding(at now: Date) -> Limit? {
        orderedLimits.max { $0.reading.effectivePct(at: now) < $1.reading.effectivePct(at: now) }
    }

    /// How recently this account was heard from at all — for the row header. Individual
    /// limits carry their own, older, ages; see `LimitReading.freshness`.
    func freshness(at now: Date, thresholds: FreshnessThresholds) -> Freshness {
        guard let o = observedAt else { return .dead }
        return Freshness.of(now.timeIntervalSince(o), thresholds: thresholds)
    }

    /// Merge a newly arrived report. Per-limit, newest observation wins; identity
    /// fields fill in whatever the other source did not know.
    mutating func absorb(_ r: IncomingReport) {
        if firstSeen == .distantPast { firstSeen = r.receivedAt }
        accountUuid = r.accountUuid ?? accountUuid
        email       = r.email       ?? email
        orgId       = r.orgId       ?? orgId
        orgName     = r.orgName     ?? orgName
        plan        = r.plan        ?? plan

        if r.source == .cli {
            sawCLI = true
        } else if let b = r.browser, !b.isEmpty, !browsers.contains(b) {
            browsers.append(b)
            browsers.sort()
        }

        for (rawKind, reading) in r.limits {
            if let existing = limits[rawKind], existing.observedAt > reading.observedAt { continue }
            limits[rawKind] = reading
        }

        if let e = r.extra, extra.map({ $0.observedAt <= e.observedAt }) ?? true {
            extra = e
        }
    }
}

/// A normalized report from either source, before it is matched to an account.
struct IncomingReport: Sendable {
    var source: ReadingSource
    var browser: String?
    var accountUuid: String?
    var email: String?
    var orgId: String?
    var orgName: String?
    var plan: String?
    var limits: [String: LimitReading]
    var extra: ExtraUsage?
    var receivedAt: Date

    /// Stable identity, best available. Falls back through account → org so that a
    /// source which cannot name the account still produces a usable row.
    var preferredKey: String? {
        if let u = accountUuid, !u.isEmpty { return "acct:\(u)" }
        if let o = orgId, !o.isEmpty       { return "org:\(o)" }
        if let e = email, !e.isEmpty       { return "email:\(e.lowercased())" }
        return nil
    }
}

// MARK: - Local CLI stats (from ~/.claude/stats-cache.json)

/// Token/message totals Claude Code has already computed on disk. These are *not*
/// quota — the server weights usage in a way tokens cannot reproduce — so they are
/// shown as their own line, never folded into a bar.
struct CLIStats: Codable, Equatable, Sendable {
    var lastComputedDate: String        // "YYYY-MM-DD"; the cache is written lazily
    var todayTokens: Int
    var todayMessages: Int
    var todaySessions: Int
    var daily: [DayPoint]               // recent history, oldest first

    struct DayPoint: Codable, Equatable, Sendable {
        var date: String
        var tokens: Int
        var messages: Int
    }

    /// True when the cache has not been recomputed for the current local day —
    /// in which case "today" is really "as of `lastComputedDate`".
    func isBehind(today: String) -> Bool { lastComputedDate < today }
}
