import Foundation

/// Turns the two wire formats we accept into one `IncomingReport`.
///
/// Both are parsed with `JSONSerialization` rather than `Codable` on purpose: the
/// shapes come from software we do not control, and a single unexpected field type
/// should degrade one limit, not throw the whole report away.
enum Ingest {

    /// Two structural ceilings plus a generous allowance for per-model caps.
    static let maxLimitsPerReport = 16

    // MARK: - Extension payload (POST /v1/usage)

    static func extensionReport(_ data: Data, receivedAt: Date = Date()) -> IncomingReport? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let source: ReadingSource = (root["source"] as? String) == "cli" ? .cli : .ext
        let account = root["account"] as? [String: Any] ?? [:]

        // A report whose observation time is missing or in the future is stamped
        // with arrival time — a clock-skewed sender must not win every merge.
        let claimed = parseFlexibleDate(root["observedAt"]) ?? receivedAt
        let observedAt = min(claimed, receivedAt)

        var limits: [String: LimitReading] = [:]
        if let raw = root["limits"] as? [String: Any] {
            for (key, value) in raw {
                guard let entry = value as? [String: Any],
                      let pct = numeric(entry["pct"]) else { continue }
                // Translate what older extension builds send, then check the shape. The
                // key space is open, so the check is on form rather than on a known list.
                let alias = LimitID.legacyAliases[key]
                let id = alias?.id ?? key
                guard LimitID.isAcceptable(id) else { continue }

                limits[id] = LimitReading(
                    pct: clampPct(pct),
                    resetsAt: parseFlexibleDate(entry["resetsAt"]),
                    observedAt: observedAt,
                    source: source,
                    label: nonEmpty(entry["label"]) ?? alias?.label
                )
            }
            // Open-ended is not the same as unbounded: a report cannot grow the panel
            // past a plausible number of model ceilings. Sorted so the cut is deterministic.
            if limits.count > maxLimitsPerReport {
                let keep = Set(limits.keys.sorted().prefix(maxLimitsPerReport))
                limits = limits.filter { keep.contains($0.key) }
            }
        }
        guard !limits.isEmpty else { return nil }

        var extra: ExtraUsage?
        if let e = root["extra"] as? [String: Any], let enabled = e["enabled"] as? Bool {
            extra = ExtraUsage(enabled: enabled,
                               used: numeric(e["used"]) ?? 0,
                               limit: numeric(e["limit"]) ?? 0,
                               currency: e["currency"] as? String,
                               observedAt: observedAt)
        }

        return IncomingReport(
            source: source,
            browser: root["browser"] as? String,
            accountUuid: nonEmpty(account["uuid"]),
            email: nonEmpty(account["email"])?.lowercased(),
            orgId: nonEmpty(account["orgId"]),
            orgName: nonEmpty(account["orgName"]),
            plan: nonEmpty(account["plan"]),
            limits: limits,
            extra: extra,
            receivedAt: receivedAt
        )
    }

    // MARK: - Claude Code statusline dump

    /// Claude Code hands its statusLine command the live `rate_limits` block on every
    /// render, which makes the local CLI account the freshest source we have — no
    /// polling and no request to claude.ai. It carries no account identity and no
    /// Opus ceiling, so identity comes from `~/.claude.json` and Opus from the extension.
    ///
    /// Because the payload names nobody, attribution is the whole risk here: a number
    /// filed under the wrong account is not a gap in the panel, it is a lie on it. See
    /// `CLIIdentity.attribution(sevenDayResetsAt:)`.
    static func cliReport(statuslineJSON data: Data,
                          identity: CLIIdentity?,
                          observedAt: Date,
                          receivedAt: Date = Date()) -> IncomingReport? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rl = root["rate_limits"] as? [String: Any] else { return nil }

        // Same clamp the extension path applies. The observation time here is a file
        // mtime, and a clock that jumps forward — or a file restored from a backup —
        // would otherwise stamp a reading in the future that wins every merge for good.
        let stamped = min(observedAt, receivedAt)

        var limits: [String: LimitReading] = [:]
        // The status line carries only these two. Per-model caps come from the browser.
        for id in [LimitID.fiveHour, LimitID.sevenDay] {
            guard let entry = rl[id] as? [String: Any],
                  let pct = numeric(entry["used_percentage"]), pct >= 0 else { continue }
            limits[id] = LimitReading(
                pct: clampPct(pct),
                resetsAt: parseFlexibleDate(entry["resets_at"]),
                observedAt: stamped,
                source: .cli,
                label: nil
            )
        }
        guard !limits.isEmpty else { return nil }

        // With no `~/.claude.json` there is nothing to file this under at all. `Store`
        // would drop it a moment later for the same reason; refusing here keeps every
        // decision about who these numbers belong to in one place.
        guard let identity else { return nil }

        let who: CLIIdentity
        switch identity.attribution(sevenDayResetsAt: limits[LimitID.sevenDay]?.resetsAt) {
        case .confirmed(let id), .unconfirmed(let id), .corrected(let id): who = id
        case .refused: return nil
        }

        return IncomingReport(
            source: .cli,
            browser: nil,
            accountUuid: who.accountUuid,
            email: who.email?.lowercased(),
            orgId: who.orgId,
            orgName: who.orgName,
            plan: who.plan,
            limits: limits,
            extra: nil,
            receivedAt: receivedAt
        )
    }

    // MARK: - Helpers

    private static func numeric(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d.isFinite ? d : nil
        case let i as Int:    return Double(i)
        case let n as NSNumber: return n.doubleValue.isFinite ? n.doubleValue : nil
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Utilization arrives as a percentage. Clamp rather than trust: a bar drawn
    /// from 143% would silently overflow its track.
    private static func clampPct(_ v: Double) -> Double { min(100, max(0, v)) }
}

/// Who the local `claude` CLI is working as, read from `~/.claude.json`.
///
/// Two blocks of that file describe an account and they can name different ones.
/// `oauthAccount` is the profile Claude Code last fetched, and it is the only place the
/// email, organization and plan live. `cachedUsageUtilization` is the quota response
/// Claude Code last fetched *with the credential it is actually using*, and it carries
/// nothing but the account uuid that response belonged to.
///
/// They disagreed on the machine this was found on, and had for weeks: `oauthAccount`
/// named one account while every status line reading — reset instants included —
/// belonged to another. `oauthAccount` alone therefore does not answer whose quota the
/// status line is reporting; it answers who Claude Code last looked up.
struct CLIIdentity: Equatable, Sendable {
    var accountUuid: String?
    var email: String?
    var orgId: String?
    var orgName: String?
    var plan: String?
    /// What the credential in use last answered to. nil only when Claude Code has never
    /// fetched usage on this machine — the one case with nothing to cross-check against.
    var credential: Credential?

    /// The part of `cachedUsageUtilization` that says *whose* it is. The percentages
    /// beside it are still not read; see `mac/README.md`.
    struct Credential: Equatable, Sendable {
        var accountUuid: String?
        /// The seven-day reset instant from that same response. A week-long window sits
        /// at its own instant per account and does not move while it runs, so it is what
        /// ties a cached account uuid to a live status line — the five-hour one cannot,
        /// because it rolls every five hours and this block is routinely hours old.
        var sevenDayResetsAt: Date?
    }

    /// `~/.claude.json` is large (hundreds of KB of unrelated project history) but
    /// only changes when Claude Code writes it, so this runs on an mtime change, not a timer.
    static func read(from url: URL = Paths.claudeConfig) -> CLIIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return read(from: data)
    }

    /// Taken as bytes so the caller can parse the file once: it is hundreds of KB, and
    /// both blocks are read on the same pass.
    static func read(from data: Data) -> CLIIdentity? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let acct = root["oauthAccount"] as? [String: Any]
        let credential = readCredential(root)
        // Either block on its own is worth something: one names the account, the other
        // proves which account the credential belongs to.
        guard acct != nil || credential != nil else { return nil }
        return CLIIdentity(
            accountUuid: acct?["accountUuid"] as? String,
            email: acct?["emailAddress"] as? String,
            orgId: acct?["organizationUuid"] as? String,
            orgName: acct?["organizationName"] as? String,
            plan: (acct?["userRateLimitTier"] as? String) ?? (acct?["organizationRateLimitTier"] as? String),
            credential: credential
        )
    }

    private static func readCredential(_ root: [String: Any]) -> Credential? {
        guard let cached = root["cachedUsageUtilization"] as? [String: Any] else { return nil }
        let sevenDay = (cached["utilization"] as? [String: Any])?[LimitID.sevenDay] as? [String: Any]
        let c = Credential(accountUuid: cached["accountUuid"] as? String,
                           sevenDayResetsAt: parseFlexibleDate(sevenDay?["resets_at"]))
        return c.accountUuid == nil && c.sevenDayResetsAt == nil ? nil : c
    }

    /// A cached reset instant and a live one describe the same window when they land
    /// this close: the API writes a fractional ISO string and the status line whole
    /// unix seconds, so the same window reads a fraction of a second apart.
    static let sameWindowTolerance: TimeInterval = 2

    /// Whose quota the status line is reporting, given the seven-day reset it just sent.
    ///
    /// The cheap check would be to take `oauthAccount` and hope. The authoritative one
    /// would be to read Claude Code's keychain item and ask `/api/oauth/profile` who the
    /// token belongs to — which costs a keychain prompt on every rebuild of an ad-hoc
    /// signed app, makes this the app's only outbound request, and would put a live
    /// access token on the wire for a menu bar widget. This does neither: both accounts
    /// are already in the file, and the reset instant says which of them the numbers
    /// came from.
    func attribution(sevenDayResetsAt reset: Date?) -> CLIAttribution {
        guard let credentialUuid = credential?.accountUuid, !credentialUuid.isEmpty else {
            return .unconfirmed(self)
        }
        if credentialUuid == accountUuid { return .confirmed(self) }
        guard let cached = credential?.sevenDayResetsAt, let reset,
              abs(cached.timeIntervalSince(reset)) <= Self.sameWindowTolerance
        else { return .refused }
        // Only the uuid travels. The email, organization and plan sitting beside it in
        // the file belong to the account `oauthAccount` names, and carrying them across
        // would put the wrong person's name on the right row. The extension fills them
        // in for any account it reports.
        return .corrected(CLIIdentity(accountUuid: credentialUuid, credential: credential))
    }
}

/// What may be done with a `CLIIdentity`, given the numbers in hand.
enum CLIAttribution: Equatable, Sendable {
    /// `oauthAccount` and the credential name the same account. Full identity.
    case confirmed(CLIIdentity)
    /// Nothing in the file names the credential's account, so `oauthAccount` is taken at
    /// its word — which is what this used to do unconditionally.
    case unconfirmed(CLIIdentity)
    /// `oauthAccount` names somebody else, and the cached quota response is holding the
    /// same seven-day window the status line just reported — so the credential's account
    /// owns these numbers. Its uuid is used, on its own.
    case corrected(CLIIdentity)
    /// The two disagree and nothing ties either account to these numbers. No row: a
    /// missing row is a gap the next report closes, a wrong one silently overwrites a
    /// correct reading and wins the merge for being newer.
    case refused
}
