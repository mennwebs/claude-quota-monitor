import Foundation

/// Watches the three files on this machine that tell us something useful:
///
///  - `cli.json`         — the statusline shim's dump of Claude Code's live session JSON
///  - `~/.claude.json`   — which account the CLI is logged in as
///  - `stats-cache.json` — token and message totals Claude Code already computed
///
/// Deliberately mtime polling rather than FSEvents. The statusline shim rewrites
/// `cli.json` on every render, so a watcher would fire constantly and still need
/// re-arming whenever the file is replaced; one `stat` per second is cheaper than
/// getting that right.
final class LocalSources {
    private let onCLIReport: @Sendable (IncomingReport) -> Void
    private let onStats: @Sendable (CLIStats?) -> Void

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.mennwebs.cqm.local")

    private var cliDumpStamp: Date?
    private var configStamp: Date?
    private var statsStamp: Date?
    private var statsMissing = false
    private var identity: CLIIdentity?

    private var wantStatusline = true
    private var wantStats = true

    init(onCLIReport: @escaping @Sendable (IncomingReport) -> Void,
         onStats: @escaping @Sendable (CLIStats?) -> Void) {
        self.onCLIReport = onCLIReport
        self.onStats = onStats
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
        refreshIdentity()
        if wantStatusline { refreshStatusline() }
        if wantStats { refreshStats() }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func refreshIdentity() {
        guard let m = Self.modified(Paths.claudeConfig) else { return }
        guard m != configStamp else { return }
        configStamp = m
        identity = CLIIdentity.read()
    }

    private func refreshStatusline() {
        guard let m = Self.modified(Paths.cliDump) else { return }
        guard m != cliDumpStamp else { return }
        cliDumpStamp = m

        guard let data = try? Data(contentsOf: Paths.cliDump) else { return }
        // The shim's write and our read race by design; a half-written file simply
        // fails to parse and we pick it up on the next tick.
        guard let report = Ingest.cliReport(statuslineJSON: data,
                                            identity: identity,
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
