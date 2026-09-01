import Foundation
import Security

// MARK: - The credential Claude Code already holds

/// The OAuth token Claude Code keeps in the login keychain.
///
/// **Read-only, and that is a hard rule.** The access token expires in hours, and the
/// refresh that renews it *rotates the refresh token too* — Claude Code stores back
/// whatever the token endpoint hands over. Two processes refreshing one credential
/// leaves one of them holding a dead refresh token, and the loser is as likely to be
/// the CLI as us: the symptom would be Claude Code silently logged out. So this reads,
/// and when the token has expired it says so and waits for Claude Code to renew it.
/// It never refreshes, and it never writes.
enum CLICredential {
    /// The generic-password item `claude` writes on macOS.
    static let service = "Claude Code-credentials"

    struct Token: Equatable {
        var value: String
        var expiresAt: Date?

        /// The endpoint refuses an expired token, so there is no point spending the
        /// request to find out. Treated as expired slightly early: a token that dies
        /// mid-flight reads as a network failure, which is a worse thing to show.
        func isExpired(at now: Date = Date(), margin: TimeInterval = 60) -> Bool {
            guard let e = expiresAt else { return false }
            return now.addingTimeInterval(margin) >= e
        }
    }

    enum Failure: Error, Equatable {
        case missing                 // Claude Code has never signed in on this machine
        case denied                  // the user declined the keychain prompt, or macOS could not ask
        case malformed               // the item is there but is not the shape we know
        case other(OSStatus)
    }

    /// Blocks on a keychain prompt the first time, so never call this from the main actor.
    static func read() -> Result<Token, Failure> {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &out)

        switch status {
        case errSecSuccess:
            guard let data = out as? Data, let token = parse(data) else { return .failure(.malformed) }
            return .success(token)
        case errSecItemNotFound:
            return .failure(.missing)
        // Every way the user can say no, or macOS can decline to ask on their behalf.
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecInteractionRequired:
            return .failure(.denied)
        default:
            return .failure(.other(status))
        }
    }

    /// Split out so `--selftest` can check the shape without a keychain behind it.
    static func parse(_ data: Data) -> Token? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let value = oauth["accessToken"] as? String,
              !value.isEmpty
        else { return nil }
        // Written as a millisecond epoch today; `parseFlexibleDate` also covers the
        // seconds and ISO spellings the rest of Claude's surfaces use.
        return Token(value: value, expiresAt: parseFlexibleDate(oauth["expiresAt"]))
    }
}

// MARK: - The endpoint

/// `api.anthropic.com/api/oauth/usage` — the call Claude Code's own `/usage` makes.
///
/// It answers with the same document claude.ai serves the extension: the two structural
/// ceilings as objects, per-model weekly caps as a `limits` array, and `extra_usage`.
/// Parsing therefore mirrors `content.js` field for field; when one side has to change,
/// so does the other, which is the whole reason both halves live in this repo.
enum QuotaAPI {
    static let base = URL(string: "https://api.anthropic.com")!
    static let betaHeader = "oauth-2025-04-20"

    /// Matches the CLI's own 5 s budget. A menu bar that hangs on a slow network is
    /// worse than one that says nothing this cycle and tries again on the next.
    static let timeout: TimeInterval = 5

    static func request(path: String, token: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        r.httpMethod = "GET"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    // MARK: Parsing — pure, so `--selftest` can hold it to the shapes seen in the wild

    /// `/api/oauth/profile` → who this token actually belongs to.
    ///
    /// `plan` is deliberately left nil. This endpoint and claude.ai's
    /// `/api/organizations/{id}` word the tier differently for the same organization
    /// (`default_claude_max_5x` here against `default_raven` there, on one Team seat),
    /// and `absorb` is last-writer-wins — so filling it in would make the row's plan
    /// badge alternate every few minutes depending on which source reported last. The
    /// extension and `~/.claude.json` both already carry it; the tier this endpoint
    /// reports is shown in Settings instead, next to the account it identifies.
    static func identity(fromProfile data: Data) -> CLIIdentity? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["account"] as? [String: Any]
        else { return nil }
        let org = root["organization"] as? [String: Any] ?? [:]

        let id = CLIIdentity(
            accountUuid: nonEmpty(account["uuid"]),
            email: nonEmpty(account["email"])?.lowercased(),
            orgId: nonEmpty(org["uuid"]),
            orgName: nonEmpty(org["name"]),
            plan: nil
        )
        // A profile that names nobody is not an identity, and letting it through would
        // hand the store a report it cannot key.
        guard id.accountUuid != nil || id.email != nil else { return nil }
        return id
    }

    /// The tier as this endpoint words it. Shown in Settings, never sent in a report —
    /// see the note on `identity(fromProfile:)`.
    static func tier(fromProfile data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let org = root["organization"] as? [String: Any]
        else { return nil }
        return nonEmpty(org["rate_limit_tier"])
    }

    /// `/api/oauth/usage` → the limits and the extra-usage block.
    static func reading(fromUsage data: Data, observedAt: Date)
        -> (limits: [String: LimitReading], extra: ExtraUsage?)
    {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ([:], nil)
        }

        var limits: [String: LimitReading] = [:]

        // The two ceilings come from the top-level objects rather than from the `limits`
        // array's `session` / `weekly_all` entries: those carry the percentage rounded to
        // an integer, and these do not.
        for (key, id) in [("five_hour", LimitID.fiveHour), ("seven_day", LimitID.sevenDay)] {
            guard let entry = root[key] as? [String: Any],
                  let pct = numeric(entry["utilization"])
            else { continue }
            limits[id] = LimitReading(pct: clampPct(pct),
                                      resetsAt: parseFlexibleDate(entry["resets_at"]),
                                      observedAt: observedAt,
                                      source: .api,
                                      label: nil)
        }

        // Per-model caps arrive as a dynamic list — a model this code has never heard of
        // still gets a row, keyed by slug and carrying its own display name. Same rule
        // `slugModel` applies in bridge.js, because both feed one key space.
        if let list = root["limits"] as? [[String: Any]] {
            for entry in list {
                guard entry["kind"] as? String == "weekly_scoped",
                      let scope = entry["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = nonEmpty(model["display_name"]),
                      let pct = numeric(entry["percent"])
                else { continue }
                let id = LimitID.weeklyPrefix + slug(name)
                guard LimitID.isAcceptable(id) else { continue }
                limits[id] = LimitReading(pct: clampPct(pct),
                                          resetsAt: parseFlexibleDate(entry["resets_at"]),
                                          observedAt: observedAt,
                                          source: .api,
                                          label: name)
            }
        }

        // The same ceiling the wire format sets: open-ended is not unbounded.
        if limits.count > Ingest.maxLimitsPerReport {
            let keep = Set(limits.keys.sorted().prefix(Ingest.maxLimitsPerReport))
            limits = limits.filter { keep.contains($0.key) }
        }

        var extra: ExtraUsage?
        if let e = root["extra_usage"] as? [String: Any], let enabled = e["is_enabled"] as? Bool {
            // `monthly_limit` and `used_credits` are null while credits are off, which is
            // not the same as zero — but zero is what a disabled block should draw.
            extra = ExtraUsage(enabled: enabled,
                               used: numeric(e["used_credits"]) ?? 0,
                               limit: numeric(e["monthly_limit"]) ?? 0,
                               currency: nonEmpty(e["currency"]),
                               observedAt: observedAt)
        }

        return (limits, extra)
    }

    /// A model display name becomes a stable wire key. Must stay identical to
    /// `slugModel` in `bridge.js`: the extension and this source write the same keys,
    /// and a mismatch would draw one model as two rows.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in name.lowercased() {
            if ch.isASCIILetterOrDigit {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else {
                pendingDash = true
            }
        }
        return String(out.prefix(32))
    }

    // MARK: Helpers

    private static func numeric(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d.isFinite ? d : nil
        case let i as Int: return Double(i)
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

    private static func clampPct(_ v: Double) -> Double { min(100, max(0, v)) }
}

private extension Character {
    var isASCIILetterOrDigit: Bool { ("a"..."z").contains(self) || ("0"..."9").contains(self) }
}

// MARK: - The source

/// Polls `/api/oauth/usage` for the account Claude Code is signed in as.
///
/// Complements the statusline shim rather than replacing it. The shim is fresher and
/// costs no request, but it only speaks while a terminal is drawing a status line and
/// it carries only the two ceilings. This answers around the clock and carries
/// everything claude.ai serves the extension — per-model caps, extra usage — for the
/// one account whose credential is in the keychain.
///
/// Off by default. It reads a credential belonging to another application, which is
/// the user's call to make and not a thing to switch on for them.
final class APISource {
    /// What Settings shows. Every failure is a state the user can act on, so none of
    /// them collapse into a generic error.
    enum Status: Equatable {
        case off
        case waiting                                    // on, first answer not back yet
        case ok(account: String, org: String?, tier: String?, at: Date)
        case noCredential                               // Claude Code has never signed in here
        case denied                                     // keychain prompt declined
        case expired                                    // waiting for Claude Code to renew
        case unauthorized                               // 401 with a token we thought was live
        case failed(String)
    }

    private let onReport: @Sendable (IncomingReport) -> Void
    /// The identity this credential really belongs to. The store uses it to file the
    /// shim's readings, which carry no identity of their own.
    private let onIdentity: @Sendable (CLIIdentity?) -> Void
    private let onStatus: @Sendable (Status) -> Void

    private let queue = DispatchQueue(label: "com.mennwebs.cqm.api")
    private let session: URLSession
    private var timer: DispatchSourceTimer?
    private var enabled = false

    /// Cached per credential value: the profile only changes when the login does, and
    /// it costs a request nobody asked for on every tick otherwise.
    private var profiledToken: String?
    private var identity: CLIIdentity?
    private var tier: String?

    /// Matches the cadence the extension polls claude.ai on. The shim already covers
    /// the seconds-fresh case for whichever account is at a terminal.
    static let interval: TimeInterval = 5 * 60

    init(onReport: @escaping @Sendable (IncomingReport) -> Void,
         onIdentity: @escaping @Sendable (CLIIdentity?) -> Void,
         onStatus: @escaping @Sendable (Status) -> Void)
    {
        self.onReport = onReport
        self.onIdentity = onIdentity
        self.onStatus = onStatus

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = QuotaAPI.timeout
        cfg.timeoutIntervalForResource = QuotaAPI.timeout * 2
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
    }

    func configure(enabled on: Bool) {
        queue.async { [weak self] in
            guard let self, self.enabled != on else { return }
            self.enabled = on
            if on {
                self.onStatus(.waiting)
                self.startTimer()
                self.fetch()
            } else {
                self.stopTimer()
                // The identity was only trustworthy while we were reading the credential
                // it came from. Withdraw it rather than leaving the store filing the
                // shim's readings against a claim nothing is refreshing.
                self.profiledToken = nil
                self.identity = nil
                self.tier = nil
                self.onIdentity(nil)
                self.onStatus(.off)
            }
        }
    }

    /// Pressing Refresh reaches the browser through a flag it may take a minute to
    /// notice. This source is ours, so Refresh can simply be a fetch. Also the way back
    /// from a stopped clock: `fetch` restarts it once an answer comes through.
    func refreshNow() {
        queue.async { [weak self] in
            guard let self, self.enabled else { return }
            self.fetch()
        }
    }

    func stop() { queue.async { [weak self] in self?.stopTimer() } }

    // MARK: - Polling

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(15))
        t.setEventHandler { [weak self] in self?.fetch() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func fetch() {
        guard enabled else { return }

        let token: CLICredential.Token
        switch CLICredential.read() {
        case .success(let t): token = t
        case .failure(let f):
            // Both of these are answered by the user, not by waiting — and a keychain
            // read that was declined prompts again every time it is retried. Stop the
            // clock and let Settings offer a retry rather than re-asking on a timer.
            switch f {
            case .missing: stopTimer(); onStatus(.noCredential)
            case .denied: stopTimer(); onStatus(.denied)
            case .malformed: onStatus(.failed("keychain item is not the shape this build knows"))
            case .other(let s): onStatus(.failed("keychain error \(s)"))
            }
            return
        }

        guard !token.isExpired() else {
            // Not an error: Claude Code renews this on its next run. Saying so is more
            // useful than a red line the user cannot act on.
            onStatus(.expired)
            return
        }

        if identity == nil || profiledToken != token.value {
            fetchProfile(token: token) { [weak self] in self?.fetchUsage(token: token) }
        } else {
            fetchUsage(token: token)
        }
    }

    private func fetchProfile(token: CLICredential.Token, then: @escaping @Sendable () -> Void) {
        let req = QuotaAPI.request(path: "api/oauth/profile", token: token.value)
        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard self.enabled else { return }
                if let outcome = self.problem(data: data, response: response, error: error) {
                    self.onStatus(outcome)
                    return
                }
                guard let data, let id = QuotaAPI.identity(fromProfile: data) else {
                    self.onStatus(.failed("profile response was not readable"))
                    return
                }
                self.identity = id
                self.tier = QuotaAPI.tier(fromProfile: data)
                self.profiledToken = token.value
                self.onIdentity(id)
                then()
            }
        }.resume()
    }

    private func fetchUsage(token: CLICredential.Token) {
        let req = QuotaAPI.request(path: "api/oauth/usage", token: token.value)
        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard self.enabled else { return }
                if let outcome = self.problem(data: data, response: response, error: error) {
                    self.onStatus(outcome)
                    return
                }
                let now = Date()
                guard let data else { return }
                let parsed = QuotaAPI.reading(fromUsage: data, observedAt: now)
                // A report with no recognized limit would refresh the row's timestamp
                // without refreshing its numbers — the same rule the wire format applies.
                guard !parsed.limits.isEmpty else {
                    self.onStatus(.failed("usage response carried no limit this build understands"))
                    return
                }
                guard let id = self.identity else { return }
                // An answer got through, so whatever stopped the clock is resolved.
                if self.timer == nil { self.startTimer() }

                self.onReport(IncomingReport(
                    source: .api,
                    browser: nil,
                    accountUuid: id.accountUuid,
                    email: id.email,
                    orgId: id.orgId,
                    orgName: id.orgName,
                    plan: nil,
                    limits: parsed.limits,
                    extra: parsed.extra,
                    receivedAt: now
                ))
                self.onStatus(.ok(account: id.email ?? id.accountUuid ?? "—",
                                  org: id.orgName,
                                  tier: self.tier,
                                  at: now))
            }
        }.resume()
    }

    /// Nil when the exchange was fine. A 401 here means the token died between the
    /// expiry check and the request, or was revoked — either way the cached profile is
    /// no longer known to belong to it.
    private func problem(data: Data?, response: URLResponse?, error: Error?) -> Status? {
        if let error { return .failed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { return .failed("no response") }
        switch http.statusCode {
        case 200:
            return nil
        case 401, 403:
            profiledToken = nil
            identity = nil
            onIdentity(nil)
            return .unauthorized
        default:
            return .failed("HTTP \(http.statusCode)")
        }
    }
}
