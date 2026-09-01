import Foundation

/// Watches the three files on this machine that tell us something useful:
///
///  - `cli.json`         — the statusline shim's dump of Claude Code's live session JSON
///  - `~/.claude.json`   — whose account the CLI's credential belongs to
///  - `stats-cache.json` — token and message totals Claude Code already computed
///
/// Deliberately mtime polling rather than FSEvents. The statusline shim rewrites
/// `cli.json` on every render, so a watcher would fire constantly and still need
/// re-arming whenever the file is replaced; one `stat` per second is cheaper than
/// getting that right.
final class LocalSources {
    private let onCLIReport: @Sendable (IncomingReport) -> Void
    private let onStats: @Sendable (CLIStats?) -> Void
    /// Whether `~/.claude.json` names an account at all — that is, whether Claude Code
    /// has ever signed in on this machine. The panel uses it to know there is a second
    /// way in worth offering, without going near the keychain to find out.
    private let onCLIPresence: @Sendable (Bool) -> Void

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.mennwebs.cqm.local")

    private var cliDumpStamp: Date?
    private var configStamp: Date?
    private var statsStamp: Date?
    private var statsMissing = false
    private var identity: CLIIdentity?
    private var credentialIdentity: CLIIdentity?

    private var wantStatusline = true
    private var wantStats = true

    init(onCLIReport: @escaping @Sendable (IncomingReport) -> Void,
         onStats: @escaping @Sendable (CLIStats?) -> Void,
         onCLIPresence: @escaping @Sendable (Bool) -> Void) {
        self.onCLIReport = onCLIReport
        self.onStats = onStats
        self.onCLIPresence = onCLIPresence
    }

    /// Who the OAuth credential on this machine really belongs to, once the quota API
    /// source has asked. Nil when that source is off, or has not answered yet.
    func setCredentialIdentity(_ id: CLIIdentity?) {
        queue.async { [weak self] in
            guard let self, self.credentialIdentity != id else { return }
            self.credentialIdentity = id
            // Re-read on the next tick rather than waiting for the shim to write again:
            // a correction that only lands on the next Claude Code render could sit
            // behind a wrong row for as long as the terminal is idle.
            self.cliDumpStamp = nil
        }
    }

    func configure(statusline: Bool, stats: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantStatusline = statusline
            self.wantStats = stats
            if !stats { self.statsMissing = true; self.onStats(nil) }
            // Force a re-read on the next tick so a toggle takes effect immediately.
            self.cliDumpStamp = nil
            self.statsStamp = nil
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .seconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // MARK: - Polling

    private func tick() {
        refreshClaudeConfig()
        if wantStatusline { refreshStatusline() }
        if wantStats { refreshStats() }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Who the CLI is working as. Two blocks of the file answer that and can disagree,
    /// so both are read on the same pass — see `CLIIdentity`. The percentages cached
    /// beside them are still not read: the note on `cachedUsageUtilization` in
    /// `mac/README.md` says why quota from there cannot be trusted even now that its
    /// account uuid can.
    private func refreshClaudeConfig() {
        guard let m = Self.modified(Paths.claudeConfig), m != configStamp else { return }
        configStamp = m
        guard let data = try? Data(contentsOf: Paths.claudeConfig) else { return }
        identity = CLIIdentity.read(from: data)
        // Signing in rewrites this file, so a machine that gains Claude Code while the
        // app is open is noticed within the second rather than at the next launch.
        onCLIPresence(identity?.accountUuid != nil)
    }

    private func refreshStatusline() {
        guard let m = Self.modified(Paths.cliDump) else { return }
        guard m != cliDumpStamp else { return }
        cliDumpStamp = m

        guard let data = try? Data(contentsOf: Paths.cliDump) else { return }
        // The shim's write and our read race by design; a half-written file simply
        // fails to parse and we pick it up on the next tick.
        //
        // `/api/oauth/profile` answers the question `~/.claude.json` can only be made to
        // infer — whose credential Claude Code is using — from the same auth context the
        // numbers come from. When the quota API source has told us, it replaces the
        // file-derived identity outright rather than being weighed against it, which also
        // covers the case the file-based rule refuses to guess at and drops.
        guard let report = Ingest.cliReport(statuslineJSON: data,
                                            identity: credentialIdentity ?? identity,
                                            observedAt: m) else { return }
        onCLIReport(report)
    }

    private func refreshStats() {
        guard let m = Self.modified(Paths.statsCache) else {
            // Say "gone" once. Repeating it every second would wake the main actor and
            // republish an unchanged nil forever, for a file that is simply not there.
            if !statsMissing {
                statsMissing = true
                statsStamp = nil
                onStats(nil)
            }
            return
        }
        statsMissing = false
        guard m != statsStamp else { return }
        statsStamp = m
        onStats(StatsReader.read())
    }
}

/// Reads `~/.claude/stats-cache.json`.
///
/// These are token and message counts, *not* quota. The server weights usage in a way
/// raw tokens cannot reproduce, so nothing here is ever mixed into a quota bar — it is
/// shown as its own line, with the cache's own `lastComputedDate` so a stale cache
/// cannot masquerade as today's activity.
enum StatsReader {
    static func read(from url: URL = Paths.statsCache, keepDays: Int = 14) -> CLIStats? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let lastComputed = (root["lastComputedDate"] as? String) ?? ""

        var tokensByDate: [String: Int] = [:]
        if let daily = root["dailyModelTokens"] as? [[String: Any]] {
            for entry in daily {
                guard let date = entry["date"] as? String else { continue }
                let byModel = entry["tokensByModel"] as? [String: Any] ?? [:]
                tokensByDate[date] = byModel.values.reduce(0) { $0 + (($1 as? NSNumber)?.intValue ?? 0) }
            }
        }

        var messagesByDate: [String: Int] = [:]
        var sessionsByDate: [String: Int] = [:]
        if let activity = root["dailyActivity"] as? [[String: Any]] {
            for entry in activity {
                guard let date = entry["date"] as? String else { continue }
                messagesByDate[date] = (entry["messageCount"] as? NSNumber)?.intValue ?? 0
                sessionsByDate[date] = (entry["sessionCount"] as? NSNumber)?.intValue ?? 0
            }
        }

        let dates = Set(tokensByDate.keys).union(messagesByDate.keys).sorted()
        let recent = dates.suffix(keepDays).map {
            CLIStats.DayPoint(date: $0, tokens: tokensByDate[$0] ?? 0, messages: messagesByDate[$0] ?? 0)
        }

        let today = Fmt.todayKey
        return CLIStats(
            lastComputedDate: lastComputed,
            todayTokens: tokensByDate[today] ?? 0,
            todayMessages: messagesByDate[today] ?? 0,
            todaySessions: sessionsByDate[today] ?? 0,
            daily: Array(recent)
        )
    }
}
