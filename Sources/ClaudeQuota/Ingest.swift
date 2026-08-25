import Foundation

/// Turns the two wire formats we accept into one `IncomingReport`.
///
/// Both are parsed with `JSONSerialization` rather than `Codable` on purpose: the
/// shapes come from software we do not control, and a single unexpected field type
/// should degrade one limit, not throw the whole report away.
enum Ingest {

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
                guard LimitKind(rawValue: key) != nil,
                      let entry = value as? [String: Any],
                      let pct = numeric(entry["pct"]) else { continue }
                limits[key] = LimitReading(
                    pct: clampPct(pct),
                    resetsAt: parseFlexibleDate(entry["resetsAt"]),
                    observedAt: observedAt,
                    source: source
                )
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
        for kind in [LimitKind.fiveHour, .sevenDay] {
            guard let entry = rl[kind.rawValue] as? [String: Any],
                  let pct = numeric(entry["used_percentage"]), pct >= 0 else { continue }
            limits[kind.rawValue] = LimitReading(
                pct: clampPct(pct),
                resetsAt: parseFlexibleDate(entry["resets_at"]),
                observedAt: stamped,
                source: .cli
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
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
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
