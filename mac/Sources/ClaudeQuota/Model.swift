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
            // "Claude Design" → "Design". The row already sits in a Claude panel, and
            // the label column has no room to say so twice.
            if let label = reading.label, !label.isEmpty {
                return label.hasPrefix("Claude ") ? String(label.dropFirst(7)) : label
            }
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
    /// When a source last reported this account *at all*, whatever the reading said.
    /// Optional so that a state file written before contact was tracked still decodes.
    var lastContactAt: Date?
    /// When each source last *observed* something, keyed by the badge it draws: "CLI",
    /// or the browser's name. Stamped with the reading's own time rather than the time
    /// the report landed, because that is what the badge claims — that this source is
    /// feeding the row. Optional for the same decoding reason as `lastContactAt`.
    var sourceSeen: [String: Date]?

    var id: String { key }

    /// Newest observation across every limit — the row's overall age.
    var observedAt: Date? {
        limits.values.map(\.observedAt).max()
    }

    var orderedLimits: [Limit] {
        limits.map { Limit(id: $0.key, reading: $0.value) }
            .sorted { ($0.rank, $0.short) < ($1.rank, $1.short) }
    }

    /// The two ceilings every account has, whatever models it uses.
    var structuralLimits: [Limit] { orderedLimits.filter { $0.rank < 2 } }

    /// Per-model weekly caps, fullest first. They share one reset and there can be any
    /// number of them, so the panel gives the group a single row rather than one each.
    func modelLimits(at now: Date) -> [Limit] {
        orderedLimits.filter { $0.rank == 2 }
            .sorted { a, b in
                let (x, y) = (a.reading.effectivePct(at: now), b.reading.effectivePct(at: now))
                return x != y ? x > y : a.short < b.short
            }
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

    /// The extension re-posts its cached reading every minute even when nothing has
    /// changed, so a gap this long means the channel has stopped rather than that the
    /// poll is slow — the one thing the panel previously could not say.
    ///
    /// Deliberately not a field of `FreshnessThresholds`: Swift's synthesized
    /// `Decodable` ignores default values, so a new stored property there would make
    /// every settings file written before it fail to decode, and `AppSettings.load()`
    /// answers a failed decode with defaults — silently discarding the user's labels.
    static let quietAfter: TimeInterval = 5 * 60

    /// How long since anything reported this account, or nil while it is still being
    /// heard from. `observedAt` stands in for rows persisted before contact was tracked;
    /// it can only over-state a gap, never hide one.
    func quietFor(at now: Date) -> TimeInterval? {
        guard let last = lastContactAt ?? observedAt else { return nil }
        let gap = now.timeIntervalSince(last)
        return gap >= Self.quietAfter ? gap : nil
    }

    /// A badge claims a source is feeding this row, so it has to be able to expire.
    /// Generous enough that a terminal left idle over lunch keeps its chip, short enough
    /// that a profile renamed weeks ago stops claiming to be here.
    static let sourceBadgeAge: TimeInterval = 3 * 3600

    /// Chips worth drawing: sources that have observed something recently, minus any
    /// that only repeat the row's own name. The extension sends the profile name the
    /// user typed into its options, and that is usually what the row is already called,
    /// so "Menn … Menn" was the common case.
    func sourceBadges(rowLabel: String, at now: Date) -> [String] {
        let names: [String]
        if let seen = sourceSeen, !seen.isEmpty {
            names = seen
                .filter { now.timeIntervalSince($0.value) < Self.sourceBadgeAge }
                .keys
                // The local CLI first, then browsers alphabetically. Written as a tuple
                // so the ordering stays strict — `$0 == "CLI"` alone is not.
                .sorted { ($0 == "CLI" ? 0 : 1, $0) < ($1 == "CLI" ? 0 : 1, $1) }
        } else {
            // A row persisted before per-source times existed. Fall back to the old
            // flags rather than blanking every badge until the next report arrives.
            names = (sawCLI ? ["CLI"] : []) + browsers
        }
        let row = rowLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(row) != .orderedSame
        }
    }

    private mutating func noteSource(_ name: String, at when: Date) {
        var seen = sourceSeen ?? [:]
        seen[name] = max(seen[name] ?? .distantPast, when)
        sourceSeen = seen
    }

    /// Merge a newly arrived report. Per-limit, newest observation wins; identity
    /// fields fill in whatever the other source did not know.
    mutating func absorb(_ r: IncomingReport) {
        if firstSeen == .distantPast { firstSeen = r.receivedAt }
        lastContactAt = max(lastContactAt ?? .distantPast, r.receivedAt)
        accountUuid = r.accountUuid ?? accountUuid
        email       = r.email       ?? email
        orgId       = r.orgId       ?? orgId
        orgName     = r.orgName     ?? orgName
        plan        = r.plan        ?? plan

        // What the badge claims is that this source is producing readings, so it is
        // stamped with the newest observation in the report rather than with the moment
        // the report arrived. A source re-delivering yesterday's numbers is not live.
        let observed = r.limits.values.map(\.observedAt).max() ?? r.receivedAt
        if r.source == .cli {
            sawCLI = true
            noteSource("CLI", at: observed)
        } else if let b = r.browser?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
            if !browsers.contains(b) {
                browsers.append(b)
                browsers.sort()
            }
            noteSource(b, at: observed)
        }

        for (rawKind, reading) in r.limits {
            if let existing = limits[rawKind], existing.observedAt > reading.observedAt { continue }
            limits[rawKind] = reading
        }
        retireModelCaps(missingFrom: r)

        if let e = r.extra, extra.map({ $0.observedAt <= e.observedAt }) ?? true {
            extra = e
        }
    }

    /// A model cap the API has stopped listing is dropped once it is this old. Long
    /// enough that one hiccuped report cannot erase a reading that is still live, short
    /// enough that a retired cap does not keep its place on the card all day.
    static let retiredModelCapAge: TimeInterval = 3 * 3600

    /// Per-model caps arrive as a list, so a model the API drops does not come back as
    /// zero — it simply stops appearing, and nothing overwrites the last reading. Left
    /// alone, an Opus bar from yesterday keeps its row next to today's numbers and reads
    /// as one of them.
    ///
    /// Only an extension report may retire them: the status line never carries model
    /// caps at all, so its silence about Opus is not evidence that Opus is gone.
    private mutating func retireModelCaps(missingFrom r: IncomingReport) {
        guard r.source == .ext else { return }
        let cutoff = r.receivedAt.addingTimeInterval(-Self.retiredModelCapAge)
        limits = limits.filter { id, reading in
            guard id.hasPrefix(LimitID.weeklyPrefix), reading.source == .ext,
                  r.limits[id] == nil
            else { return true }
            return reading.observedAt > cutoff
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

    /// The newest day the cache actually accounts for. Claude Code recomputes this file
    /// lazily, so on a machine that has been working all morning "today" is still all
    /// zeros — which reads as "you did nothing" rather than "not counted yet". The panel
    /// shows this day, named, instead of a zero it knows to be wrong.
    func shown(today: String) -> DayPoint {
        guard isBehind(today: today), let last = daily.last else {
            return DayPoint(date: today, tokens: todayTokens, messages: todayMessages)
        }
        return last
    }
}
