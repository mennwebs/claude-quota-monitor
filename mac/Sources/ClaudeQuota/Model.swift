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

    /// How long each window runs. The API states when a window resets but never how
    /// long it is, and pace cannot say how far in you are without it.
    static func windowLength(_ raw: String) -> TimeInterval? {
        if raw == fiveHour { return 5 * 3600 }
        if raw == sevenDay || raw.hasPrefix(weeklyPrefix) { return 7 * 86_400 }
        return nil
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
    case api = "api"         // api.anthropic.com, with Claude Code's own token

    var badge: String {
        switch self {
        case .cli: return "CLI"
        case .api: return "API"
        case .ext: return "web"
        }
    }

    /// Whether a report from this source lists every per-model cap the account has.
    /// The status line carries only the two ceilings, so its silence about Opus says
    /// nothing about whether Opus is still capped — which is what `retireModelCaps`
    /// has to be able to tell apart.
    var carriesModelCaps: Bool { self != .cli }
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

    /// How much of the window has to have passed before pace means anything.
    ///
    /// The 5-hour window starts on your first message rather than on a schedule, so its
    /// opening minutes are *always* over pace: one message two minutes in projects to
    /// several hundred percent and says nothing at all. Fifteen percent of a 5-hour
    /// window is 45 minutes, which is long enough for a rate to exist.
    static let paceWarmup = 0.15

    /// nil when pace cannot be judged: the window is unknown, has no reset time (which
    /// is every per-model cap today — the API sends `resets_at: null` for them), has
    /// already run out, or is too young to read.
    func pace(id: String, at now: Date) -> Pace? {
        guard let window = LimitID.windowLength(id), let resets = resetsAt else { return nil }
        let left = resets.timeIntervalSince(now)
        guard left > 0 else { return nil }
        let elapsed = (window - left) / window
        guard elapsed >= Self.paceWarmup, elapsed < 1 else { return nil }

        guard pct > 0 else { return Pace(elapsed: elapsed, projected: 0, exhaustsIn: nil) }
        let projected = pct / elapsed
        let perSecond = pct / (window * elapsed)
        // A window already spent has no end left to predict. Saying "runs out in 0m" over
        // a bar that is visibly full is noise, and it costs the row its reset countdown —
        // which at that point is the only number left worth having.
        let ends = projected > 100 && pct < 100 ? (100 - pct) / perSecond : nil
        return Pace(elapsed: elapsed, projected: projected, exhaustsIn: ends)
    }

    /// Each limit ages on its own clock. The two sources cover different limits — the
    /// status line never reports Opus — so an account can be refreshed every second
    /// while its Opus number quietly goes hours stale. Dimming the row by the account's
    /// newest reading would present that stale number as current.
    func freshness(at now: Date, thresholds: FreshnessThresholds) -> Freshness {
        Freshness.of(now.timeIntervalSince(observedAt), thresholds: thresholds)
    }
}

// MARK: - Pace

/// Whether this window is being spent faster than it can carry.
///
/// A bar answers "how full", which is not the question that ruins a week. 66% used
/// looks comfortable next to a reset five days out, and is not: a quarter of the way
/// into the window it means the quota runs out on Thursday. The comparison the eye
/// cannot make on its own is usage against *elapsed time*, so the panel makes it.
struct Pace: Equatable, Sendable {
    /// How far through the window we are, 0…1. This is where the bar would be if the
    /// window were being spent evenly — the mark the fill is measured against.
    var elapsed: Double
    /// Where the fill lands at the end of the window if the current average rate holds.
    var projected: Double
    /// Time until the window is spent, or nil when it will not be spent at this rate.
    var exhaustsIn: TimeInterval?

    /// Ten percent either side of 100. Anything inside that is a window being spent at
    /// roughly the rate it can carry, and the projection is not accurate enough to argue
    /// otherwise: a session at 62% with 58% of it gone projects to 107%, which is a 7%
    /// overshoot dressed up as an hour of lost quota. The mark on the bar can say that
    /// much on its own.
    var level: Level {
        if projected > 110 { return .short }
        if projected >= 90 { return .tight }
        return .onTrack
    }

    enum Level: Sendable { case onTrack, tight, short }
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

// MARK: - Plan

/// One source's word on an account's tier, stamped with the reading it arrived beside.
struct PlanStatement: Codable, Equatable, Sendable {
    var plan: String
    var at: Date

    /// Strict, total order: by time, then by text, so two statements stamped alike still
    /// settle the same way whichever arrived first.
    static func order(_ a: PlanStatement, _ b: PlanStatement) -> Bool {
        (a.at, a.plan) < (b.at, b.plan)
    }
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
    /// Each source's latest word on the plan, keyed by `ReadingSource.rawValue`. `plan` is
    /// derived from these by `resolvePlan` rather than overwritten by whichever report came
    /// last: the sources word one seat's tier differently — on a Team seat claude.ai's
    /// organization answers `default_raven` while Claude Code's profile answers a Max tier —
    /// and the panel decides what a card shows from it. Kept per source, rather than only
    /// the winner, so folding two rows reaches exactly what absorbing their reports in turn
    /// would. Optional for the same decoding reason as `lastContactAt`.
    var planStatements: [String: PlanStatement]?
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
    /// When each source last reported this account with no 5-hour window, keyed by
    /// `ReadingSource.rawValue`. Retiring the 5h reading leaves nothing behind for the
    /// newest-wins merge to compare against, so without this an *older* 5h reading arriving
    /// afterwards — a second browser profile re-posting its cache, a row folded in — would
    /// simply be written back, and the row would come and go every minute. Optional for
    /// the same decoding reason as `lastContactAt`.
    var sessionRetiredAt: [String: Date]?

    var id: String { key }

    /// Newest observation across every limit — the row's overall age.
    var observedAt: Date? {
        limits.values.map(\.observedAt).max()
    }

    var orderedLimits: [Limit] {
        limits.map { Limit(id: $0.key, reading: $0.value) }
            .sorted { ($0.rank, $0.short) < ($1.rank, $1.short) }
    }

    /// The account-wide ceilings, whatever models it uses: 7d always, 5h only for an
    /// account that has a 5-hour window — Ultra plans and some Team seats do not.
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

    /// A Team seat, by the name the plan badge would give it.
    var isTeam: Bool { Fmt.plan(plan) == "Team" }

    /// Whether this card draws its per-model caps at all.
    ///
    /// A Team seat's are hidden unless the user asks for them. Team organizations tend not
    /// to use the models that carry a cap of their own, so the row sits at 0% on every card
    /// and costs a line of a two-column panel to say nothing. Every other plan keeps them:
    /// there, a model cap is routinely the one that binds first.
    func showsModelCaps(onTeam: Bool) -> Bool { !isTeam || onTeam }

    /// The ceiling closest to blocking you. Weekly Opus routinely binds before the
    /// 5-hour window does, so "how full am I" cannot just read `five_hour`.
    ///
    /// Only over what the card shows: a menu bar glyph filled by a cap the card has hidden
    /// would be a number with nothing in the panel to explain it.
    func binding(at now: Date, modelCaps: Bool = true) -> Limit? {
        (modelCaps ? orderedLimits : structuralLimits)
            .max { $0.reading.effectivePct(at: now) < $1.reading.effectivePct(at: now) }
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

    /// The plan a set of statements adds up to. Pure, and independent of the order they
    /// arrived in.
    ///
    /// Newest observation wins, as it does for limits. The stamp is the reading's own time,
    /// not the report's arrival: the extension re-posts its cache every minute whether or not
    /// its fetch is working, and a re-delivery of an hour-old plan is not a new statement.
    ///
    /// One exception. Against the other sources, the extension's latest word stands while it
    /// says "Team" and is fresh. It reads claude.ai's organization, the only source that names
    /// a Team seat at all; `~/.claude.json` carries the tier Claude Code's profile answered,
    /// which on that same seat is a Max tier, and the status line stamps a reading the moment
    /// it renders — so newest-wins alone would turn the card back, badge and model-cap row
    /// both, within seconds of every extension report. Narrow on purpose: elsewhere the
    /// sources read the same `rate_limit_tier`, and the extension caches its tier until
    /// claude.ai is next opened in that profile, so it is not the fresher word in general.
    /// The hold lapses on the badge's horizon — the app's existing answer to "is this source
    /// still feeding the row" — after which the status line's tier, if it carries one, wins.
    static func resolvePlan(_ all: [String: PlanStatement]) -> String? {
        let ext = all[ReadingSource.ext.rawValue]
        let other = all.filter { $0.key != ReadingSource.ext.rawValue }.values.max(by: PlanStatement.order)
        switch (ext, other) {
        case (nil, nil): return nil
        case (let e?, nil): return e.plan
        case (nil, let o?): return o.plan
        case (let e?, let o?):
            if Fmt.plan(e.plan) == "Team", o.at.timeIntervalSince(e.at) < sourceBadgeAge { return e.plan }
            return PlanStatement.order(e, o) ? o.plan : e.plan
        }
    }

    /// Keep a source's newest statement, and re-derive the plan from the set.
    private mutating func notePlan(_ statement: PlanStatement, from source: String) {
        var all = planStatements ?? [:]
        if let held = all[source], !PlanStatement.order(held, statement) { return }
        all[source] = statement
        planStatements = all
        plan = Self.resolvePlan(all) ?? plan
    }

    /// Folding a duplicate row's plan in: each source's newest statement across both rows,
    /// then the same derivation `absorb` uses. A row persisted before statements were kept
    /// still lends its plan to one that has none.
    mutating func foldPlan(from victim: AccountSnapshot) {
        for (source, statement) in victim.planStatements ?? [:] { notePlan(statement, from: source) }
        if plan == nil { plan = victim.plan }
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

        // What the badge claims is that this source is producing readings, so it is
        // stamped with the newest observation in the report rather than with the moment
        // the report arrived. A source re-delivering yesterday's numbers is not live — and
        // the plan riding along with them is not a new statement either.
        let observed = r.limits.values.map(\.observedAt).max() ?? r.receivedAt
        if let p = r.plan { notePlan(PlanStatement(plan: p, at: observed), from: r.source.rawValue) }
        switch r.source {
        case .cli:
            sawCLI = true
            noteSource(r.source.badge, at: observed)
        case .api:
            // No browser to name, so the badge is the source itself. Without this the
            // row would draw no chip at all for a source that is plainly feeding it.
            noteSource(r.source.badge, at: observed)
        case .ext:
            if let b = r.browser?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
                if !browsers.contains(b) {
                    browsers.append(b)
                    browsers.sort()
                }
                noteSource(b, at: observed)
            }
        }

        for (rawKind, reading) in r.limits {
            if let existing = limits[rawKind], existing.observedAt > reading.observedAt { continue }
            if rawKind == LimitID.fiveHour, predatesRetirement(reading) { continue }
            limits[rawKind] = reading
        }
        retireModelCaps(missingFrom: r)
        retireSessionWindow(missingFrom: r)

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
    /// Only a source that lists them all may retire them: the status line never carries
    /// model caps at all, so its silence about Opus is not evidence that Opus is gone.
    ///
    /// And a source may only retire its *own* readings. The extension and the API source
    /// both list caps, but they poll on their own clocks — so a cap the API has already
    /// dropped can still be arriving from the browser, and letting either speak for the
    /// other would make one source's timing erase the other's live reading.
    private mutating func retireModelCaps(missingFrom r: IncomingReport) {
        guard r.source.carriesModelCaps else { return }
        let cutoff = r.receivedAt.addingTimeInterval(-Self.retiredModelCapAge)
        limits = limits.filter { id, reading in
            guard id.hasPrefix(LimitID.weeklyPrefix), reading.source == r.source,
                  r.limits[id] == nil
            else { return true }
            return reading.observedAt > cutoff
        }
    }

    /// A report with no `five_hour` says the account has no 5-hour window. Ultra plans and
    /// some Team seats have none at all, and an account that does have one loses it while
    /// its weekly cap is spent. Left alone, the last reading would hold the row forever —
    /// and the extension used to send exactly that as 0% with no reset, so every Ultra card
    /// carried an idle-looking 5h bar for a limit that does not exist.
    ///
    /// Unlike the model list there is no hiccup to wait out: every source states the two
    /// ceilings on every report, so the reading goes at once rather than after
    /// `retiredModelCapAge`. Only the source's *own* reading, for the same reason as the
    /// model caps; and only one the report has seen past, since two browser profiles on one
    /// account post on their own minutes and an older re-delivery must not erase a newer one.
    ///
    /// The absence is remembered in `sessionRetiredAt`, so it holds against older data the
    /// way a newer reading would: the other profile's stale re-post is refused, not revived.
    private mutating func retireSessionWindow(missingFrom r: IncomingReport) {
        guard r.limits[LimitID.fiveHour] == nil,
              let seen = r.limits.values.map(\.observedAt).max()
        else { return }
        var retired = sessionRetiredAt ?? [:]
        let source = r.source.rawValue
        retired[source] = max(retired[source] ?? .distantPast, seen)
        sessionRetiredAt = retired
        dropSessionPredatingRetirement()
    }

    /// Whether a 5h reading was observed before its own source last said there is no
    /// window. A later reading is the window coming back — a spent week resetting — and
    /// is taken as usual.
    private func predatesRetirement(_ reading: LimitReading) -> Bool {
        guard let at = sessionRetiredAt?[reading.source.rawValue] else { return false }
        return reading.observedAt < at
    }

    private mutating func dropSessionPredatingRetirement() {
        if let held = limits[LimitID.fiveHour], predatesRetirement(held) {
            limits[LimitID.fiveHour] = nil
        }
    }

    /// Folding a duplicate row's readings into this one. Newest observation wins per limit,
    /// as in `absorb`. The later "no window" per source wins too, and is merged *first*: a
    /// 5h either row held from before it is neither copied in nor kept, and a 5h this row
    /// holds from another source is not displaced by one that would only be dropped after.
    mutating func foldLimits(from victim: AccountSnapshot) {
        if let theirs = victim.sessionRetiredAt {
            var mine = sessionRetiredAt ?? [:]
            for (source, at) in theirs { mine[source] = max(mine[source] ?? .distantPast, at) }
            sessionRetiredAt = mine
        }
        for (id, reading) in victim.limits
        where (limits[id]?.observedAt ?? .distantPast) < reading.observedAt {
            if id == LimitID.fiveHour, predatesRetirement(reading) { continue }
            limits[id] = reading
        }
        dropSessionPredatingRetirement()
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

// MARK: - Matching a report to a row

/// Which row a report belongs to, and which rows a source that could not name an account
/// has left behind. Pure functions of the list and the report, so the rules can be checked
/// without a store, a server, or a file on disk.
enum AccountMatch {

    /// Match on the strongest identifier the report carries. The extension and the
    /// statusline shim describe the same account from different angles — one knows the
    /// org, the other the OAuth account — so matching has to work from any of them or
    /// the same quota shows up as two rows.
    static func index(of r: IncomingReport, in accounts: [AccountSnapshot]) -> Int? {
        if let u = r.accountUuid, let i = accounts.firstIndex(where: { $0.accountUuid == u }) { return i }
        if let e = r.email, let i = accounts.firstIndex(where: { $0.email == e }) { return i }
        if let i = profileIndex(of: r, in: accounts) { return i }
        // Only when *neither* side names an account. Several accounts can belong to one
        // Team organization, so an org match between a report that knows its uuid and a
        // row that does not is not evidence they are the same person.
        if let o = r.orgId, r.accountUuid == nil,
           let i = accounts.firstIndex(where: { $0.orgId == o && $0.accountUuid == nil }) { return i }
        if let k = r.preferredKey, let i = accounts.firstIndex(where: { $0.key == k }) { return i }
        return nil
    }

    /// The row this report's browser profile is already feeding.
    ///
    /// A source that cannot name the account still names the profile it speaks for, and a
    /// profile is signed into one account at a time — which is the only thing separating an
    /// anonymous report from a second account in the same Team organization. Without it, an
    /// extension whose identity lookup fails once files every later reading under the
    /// organization, and the panel grows a duplicate card holding the same numbers under a
    /// name nobody recognises.
    ///
    /// A row that knows whose account it is wins over one that does not, so the rule heals
    /// state the old behaviour left behind rather than going on feeding it.
    static func profileIndex(of r: IncomingReport, in accounts: [AccountSnapshot]) -> Int? {
        guard r.accountUuid == nil, r.email == nil, let org = r.orgId,
              let profile = r.browser?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty
        else { return nil }

        let candidates = accounts.indices.filter {
            accounts[$0].orgId == org && accounts[$0].browsers.contains(profile)
        }
        let named = candidates.filter { accounts[$0].accountUuid != nil }
        if named.count == 1 { return named[0] }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Rows that exist only because a report once had nowhere else to go.
    ///
    /// Now that an anonymous report lands on its profile's real row, a row with no account
    /// identity holds nothing that is not already somewhere better — provided *every*
    /// browser feeding it also feeds a named row in the same organization. That proviso is
    /// where the safety is: an organization can hold several accounts, and one of them
    /// genuinely unidentified is a row worth keeping.
    static func redundantAnonymousKeys(in accounts: [AccountSnapshot]) -> [String] {
        let named = accounts.filter { $0.accountUuid != nil || $0.email != nil }
        guard !named.isEmpty else { return [] }
        return accounts.filter { row in
            guard row.accountUuid == nil, row.email == nil,
                  let org = row.orgId, !row.browsers.isEmpty
            else { return false }
            return row.browsers.allSatisfy { b in
                named.contains { $0.orgId == org && $0.browsers.contains(b) }
            }
        }.map(\.key)
    }
}
