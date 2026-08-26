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

        return IncomingReport(
            source: .cli,
            browser: nil,
            accountUuid: identity?.accountUuid,
            email: identity?.email?.lowercased(),
            orgId: identity?.orgId,
            orgName: identity?.orgName,
            plan: identity?.plan,
            limits: limits,
            extra: nil,
            receivedAt: receivedAt
        )
    }

    // MARK: - Claude Code's own usage cache (~/.claude.json)

    /// Claude Code keeps the last quota response it fetched in `cachedUsageUtilization`,
    /// stamped with `fetchedAtMs` and — crucially — with the account it belongs to.
    ///
    /// This is the only local source that does not need a terminal. The statusline shim
    /// runs on render, so it only produces anything while Claude Code is drawing a status
    /// line; in the desktop app it never fires at all. This block is written by whichever
    /// session last refreshed its usage, whatever the surface.
    ///
    /// It is also the more complete of the two: the statusline payload carries 5h and 7d
    /// and nothing else, while this carries the dynamic per-model list and the credit
    /// balance as well. What it does not carry is freshness — Claude Code refreshes it on
    /// its own schedule, which can be a day apart — hence `fetchedAtMs` on every reading
    /// so the panel ages it honestly rather than presenting it as current.
    static func claudeConfigReport(_ data: Data,
                                   identity: CLIIdentity?,
                                   receivedAt: Date = Date()) -> IncomingReport? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let fetched = parseFlexibleDate(cache["fetchedAtMs"]),
              let uuid = nonEmpty(cache["accountUuid"]),
              let u = cache["utilization"] as? [String: Any]
        else { return nil }

        let observedAt = min(fetched, receivedAt)

        var limits: [String: LimitReading] = [:]
        func put(_ id: String, _ entry: Any?, pctKey: String, label: String? = nil) {
            guard let e = entry as? [String: Any], let pct = numeric(e[pctKey]) else { return }
            limits[id] = LimitReading(pct: clampPct(pct), resetsAt: parseFlexibleDate(e["resets_at"]),
                                      observedAt: observedAt, source: .cli, label: label)
        }

        put(LimitID.fiveHour, u["five_hour"], pctKey: "utilization")
        put(LimitID.sevenDay, u["seven_day"], pctKey: "utilization")

        // Same open-ended list the web API returns, and read the same way: whatever
        // models come back get a row, keyed by slug and carrying their own label.
        for case let entry as [String: Any] in (u["limits"] as? [Any] ?? []) {
            guard (entry["kind"] as? String) == "weekly_scoped",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = nonEmpty(model["display_name"])
            else { continue }
            let id = LimitID.weeklyPrefix + slug(name)
            guard LimitID.isAcceptable(id) else { continue }
            put(id, entry, pctKey: "percent", label: name)
        }

        guard !limits.isEmpty else { return nil }
        if limits.count > maxLimitsPerReport {
            let keep = Set(limits.keys.sorted().prefix(maxLimitsPerReport))
            limits = limits.filter { keep.contains($0.key) }
        }

        var extra: ExtraUsage?
        if let e = u["extra_usage"] as? [String: Any], let enabled = e["is_enabled"] as? Bool {
            extra = ExtraUsage(enabled: enabled,
                               used: numeric(e["used_credits"]) ?? 0,
                               limit: numeric(e["monthly_limit"]) ?? 0,
                               currency: e["currency"] as? String,
                               observedAt: observedAt)
        }

        // The cache names its own account, and `oauthAccount` names whichever one the CLI
        // is signed into *now*. They disagree the moment you switch accounts, so the rest
        // of the identity is only borrowed when the two agree — a wrong email would merge
        // this reading into somebody else's row.
        let sameAccount = identity?.accountUuid == uuid
        return IncomingReport(
            source: .cli,
            browser: nil,
            accountUuid: uuid,
            email: sameAccount ? identity?.email?.lowercased() : nil,
            orgId: sameAccount ? identity?.orgId : nil,
            orgName: sameAccount ? identity?.orgName : nil,
            plan: sameAccount ? identity?.plan : nil,
            limits: limits,
            extra: extra,
            receivedAt: receivedAt
        )
    }

    // MARK: - Helpers

    /// "Claude Design" -> "claude-design". Must land inside `LimitID.isAcceptable`, so
    /// anything that is not an ASCII letter or digit collapses into a single dash.
    static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if !out.isEmpty && !out.hasSuffix("-") { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(32))
    }


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

/// Who the local `claude` CLI is logged in as, read from `~/.claude.json`.
struct CLIIdentity: Equatable, Sendable {
    var accountUuid: String?
    var email: String?
    var orgId: String?
    var orgName: String?
    var plan: String?

    /// `~/.claude.json` is large (hundreds of KB of unrelated project history) but
    /// only changes when Claude Code writes it, so this runs on an mtime change, not a timer.
    static func read(from url: URL = Paths.claudeConfig) -> CLIIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return read(from: data)
    }

    /// Taken as bytes so the caller can parse the file once: it is hundreds of KB, and
    /// the usage block beside `oauthAccount` is read on the same pass.
    static func read(from data: Data) -> CLIIdentity? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let acct = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return CLIIdentity(
            accountUuid: acct["accountUuid"] as? String,
            email: acct["emailAddress"] as? String,
            orgId: acct["organizationUuid"] as? String,
            orgName: acct["organizationName"] as? String,
            plan: (acct["userRateLimitTier"] as? String) ?? (acct["organizationRateLimitTier"] as? String)
        )
    }
}
