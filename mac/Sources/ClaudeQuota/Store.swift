import Foundation
import SwiftUI

/// A one-bit channel from the UI back to the browser extension.
///
/// Nothing on this machine can make Chrome fetch on demand, but the extension already
/// checks in every minute. Clicking Refresh raises this flag; the next check-in reply
/// carries it, and the extension does a real claude.ai fetch instead of re-posting its
/// cache. No extra polling, no extra requests.
final class RefreshFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var openUntil = Date.distantPast
    private let window: TimeInterval

    /// The window has to outlast one full push cycle so every profile sees the request.
    init(window: TimeInterval = 90) { self.window = window }

    func raise() {
        lock.lock(); defer { lock.unlock() }
        openUntil = Date().addingTimeInterval(window)
    }

    /// Deliberately not destructive. Each profile's service worker checks in on its own
    /// minute, so a flag consumed by the first caller would refresh one account and
    /// leave the other three untouched — which is not what pressing Refresh means.
    func shouldRefresh() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < openUntil
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var accounts: [AccountSnapshot] = []
    @Published private(set) var stats: CLIStats?
    @Published private(set) var serverState: LoopbackServer.ServerState = .stopped
    @Published private(set) var now = Date()
    @Published var settings: AppSettings {
        didSet { onSettingsChanged(from: oldValue) }
    }

    let token: String
    let refreshFlag = RefreshFlag()

    private var server: LoopbackServer!
    private var local: LocalSources!
    private var ticker: Timer?
    private var persistWork: DispatchWorkItem?
    private var started = false

    init() {
        self.token = TokenStore.loadOrCreate()
        self.settings = AppSettings.load()
        self.accounts = Self.loadPersisted()

        // Captured directly rather than through `self`: the server answers on its own
        // queue and must not reach into main-actor state to do it.
        let flag = refreshFlag
        server = LoopbackServer(
            onReport: { [weak self] data in
                if let report = Ingest.extensionReport(data) {
                    Task { @MainActor [weak self] in self?.ingest(report) }
                }
                // Reading the flag is lock-guarded, so it can be answered on the
                // server's own queue without hopping to the main actor first.
                return LoopbackServer.ReportAck(refresh: flag.shouldRefresh())
            },
            onState: { [weak self] st in
                Task { @MainActor [weak self] in self?.serverState = st }
            }
        )
        local = LocalSources(
            onCLIReport: { [weak self] report in
                Task { @MainActor [weak self] in self?.ingest(report) }
            },
            onStats: { [weak self] s in
                Task { @MainActor [weak self] in self?.stats = s }
            }
        )
    }

    /// The menu bar label's `onAppear` can fire more than once; starting is idempotent.
    func start() {
        guard !started else { return }
        started = true
        server.start(port: settings.port, token: token)
        local.configure(statusline: settings.readCLIStatusline, stats: settings.readStatsCache)
        local.start()

        // Five seconds is enough: countdowns are shown to the minute, and freshness
        // thresholds are minutes apart. A 1 s tick would only buy redraws nobody sees.
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func stop() {
        ticker?.invalidate(); ticker = nil
        local.stop()
        server.stop()
        persistNow()
    }

    // MARK: - Ingest

    func ingest(_ report: IncomingReport) {
        guard report.preferredKey != nil else { return }
        let index = matchIndex(for: report) ?? appendNew(from: report)
        accounts[index].absorb(report)
        collapseDuplicates()
        sortAccounts()
        schedulePersist()
    }

    /// Match on the strongest identifier the report carries. The extension and the
    /// statusline shim describe the same account from different angles — one knows the
    /// org, the other the OAuth account — so matching has to work from any of them or
    /// the same quota shows up as two rows.
    private func matchIndex(for r: IncomingReport) -> Int? {
        if let u = r.accountUuid, let i = accounts.firstIndex(where: { $0.accountUuid == u }) { return i }
        if let e = r.email, let i = accounts.firstIndex(where: { $0.email == e }) { return i }
        // Only when *neither* side names an account. Several accounts can belong to one
        // Team organization, so an org match between a report that knows its uuid and a
        // row that does not is not evidence they are the same person.
        if let o = r.orgId, r.accountUuid == nil,
           let i = accounts.firstIndex(where: { $0.orgId == o && $0.accountUuid == nil }) { return i }
        if let k = r.preferredKey, let i = accounts.firstIndex(where: { $0.key == k }) { return i }
        return nil
    }

    private func appendNew(from r: IncomingReport) -> Int {
        accounts.append(AccountSnapshot(key: r.preferredKey!))
        return accounts.count - 1
    }

    /// Two rows can exist before anyone links them: the shim reports an email-keyed row
    /// on Monday, the extension supplies the matching UUID on Tuesday. Fold them then.
    private func collapseDuplicates() {
        var i = 0
        while i < accounts.count {
            var j = i + 1
            while j < accounts.count {
                if sameAccount(accounts[i], accounts[j]) {
                    let victim = accounts.remove(at: j)
                    absorbAccount(victim, into: &accounts[i])
                } else {
                    j += 1
                }
            }
            i += 1
        }
    }

    private func sameAccount(_ a: AccountSnapshot, _ b: AccountSnapshot) -> Bool {
        if let x = a.accountUuid, let y = b.accountUuid { return x == y }
        if let x = a.email, let y = b.email { return x == y }
        if a.accountUuid == nil, b.accountUuid == nil, let x = a.orgId, let y = b.orgId { return x == y }
        return a.key == b.key
    }

    private func absorbAccount(_ victim: AccountSnapshot, into target: inout AccountSnapshot) {
        target.accountUuid = target.accountUuid ?? victim.accountUuid
        target.email       = target.email       ?? victim.email
        target.orgId       = target.orgId       ?? victim.orgId
        target.orgName     = target.orgName     ?? victim.orgName
        target.plan        = target.plan        ?? victim.plan
        target.sawCLI      = target.sawCLI || victim.sawCLI
        target.browsers    = Array(Set(target.browsers).union(victim.browsers)).sorted()
        target.firstSeen   = min(target.firstSeen, victim.firstSeen)
        target.lastContactAt = [target.lastContactAt, victim.lastContactAt].compactMap { $0 }.max()
        if let inherited = victim.sourceSeen {
            var seen = target.sourceSeen ?? [:]
            for (name, when) in inherited { seen[name] = max(seen[name] ?? .distantPast, when) }
            target.sourceSeen = seen
        }
        for (k, r) in victim.limits where (target.limits[k]?.observedAt ?? .distantPast) < r.observedAt {
            target.limits[k] = r
        }
        if let e = victim.extra, (target.extra?.observedAt ?? .distantPast) < e.observedAt {
            target.extra = e
        }
        // Carry the user's label across so a merge does not silently rename a row.
        if settings.labels[target.key] == nil, let inherited = settings.labels[victim.key] {
            settings.labels[target.key] = inherited
        }
        settings.labels.removeValue(forKey: victim.key)
        settings.hidden.remove(victim.key)
    }

    // MARK: - Presentation

    /// Position must be stable — the menu bar icon is read at a glance, and bars that
    /// reorder themselves by urgency are unreadable. Explicit order first, then arrival.
    private func sortAccounts() {
        let rank = Dictionary(uniqueKeysWithValues: settings.order.enumerated().map { ($1, $0) })
        accounts.sort { a, b in
            let ra = rank[a.key] ?? Int.max
            let rb = rank[b.key] ?? Int.max
            if ra != rb { return ra < rb }
            if a.firstSeen != b.firstSeen { return a.firstSeen < b.firstSeen }
            return a.key < b.key
        }
    }

    var visibleAccounts: [AccountSnapshot] {
        accounts.filter { !settings.hidden.contains($0.key) }
    }

    func label(for a: AccountSnapshot) -> String {
        if let custom = settings.labels[a.key], !custom.isEmpty { return custom }
        if let email = a.email { return String(email.split(separator: "@").first ?? "") }
        if let org = a.orgName, !org.isEmpty { return org }
        return String(a.key.suffix(8))
    }

    func rename(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { settings.labels.removeValue(forKey: key) }
        else { settings.labels[key] = trimmed }
    }

    func forget(_ key: String) {
        accounts.removeAll { $0.key == key }
        settings.labels.removeValue(forKey: key)
        settings.hidden.remove(key)
        settings.order.removeAll { $0 == key }
        persistNow()
    }

    func move(_ key: String, by delta: Int) {
        var keys = accounts.map(\.key)
        guard let from = keys.firstIndex(of: key) else { return }
        let to = max(0, min(keys.count - 1, from + delta))
        guard to != from else { return }
        keys.remove(at: from)
        keys.insert(key, at: to)
        settings.order = keys
        sortAccounts()
    }

    func requestRefresh() { refreshFlag.raise() }

    /// Newest observation anywhere, for the panel header.
    var lastUpdate: Date? { accounts.compactMap(\.observedAt).max() }

    /// How long since *anything* reported, once that is long enough to be worth saying.
    ///
    /// `lastUpdate` is the age of the newest reading. The two diverge exactly when a
    /// source stops reporting — a browser whose service worker is gone, an app the
    /// extension can no longer reach — and that is the case the panel used to render
    /// identically to a quiet afternoon.
    var quietFor: TimeInterval? {
        guard let newest = accounts.compactMap({ $0.lastContactAt ?? $0.observedAt }).max()
        else { return nil }
        let gap = now.timeIntervalSince(newest)
        return gap >= AccountSnapshot.quietAfter ? gap : nil
    }

    // MARK: - Settings changes

    private func onSettingsChanged(from old: AppSettings) {
        settings.save()
        if old.port != settings.port {
            server.start(port: settings.port, token: token)
        }
        if old.readCLIStatusline != settings.readCLIStatusline || old.readStatsCache != settings.readStatsCache {
            local.configure(statusline: settings.readCLIStatusline, stats: settings.readStatsCache)
        }
        if old.order != settings.order { sortAccounts() }
    }

    // MARK: - Persistence

    private struct PersistedState: Codable { var accounts: [AccountSnapshot] }

    private static func loadPersisted() -> [AccountSnapshot] {
        guard let d = try? Data(contentsOf: Paths.state),
              let s = try? JSONIO.decoder.decode(PersistedState.self, from: d)
        else { return [] }
        return s.accounts.map(migrateLegacyLimits)
    }

    /// State written before per-model caps became dynamic is keyed `seven_day_opus` and
    /// carries no label. Left alone it would render as "Seven day opus" and never merge
    /// with the `weekly:opus` a current extension sends.
    private static func migrateLegacyLimits(_ account: AccountSnapshot) -> AccountSnapshot {
        var migrated = account
        for (old, new) in LimitID.legacyAliases {
            guard var reading = migrated.limits.removeValue(forKey: old) else { continue }
            reading.label = reading.label ?? new.label
            if (migrated.limits[new.id]?.observedAt ?? .distantPast) < reading.observedAt {
                migrated.limits[new.id] = reading
            }
        }
        return migrated
    }

    /// Reports arrive far more often than the disk needs to hear about them; coalesce.
    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.persistNow() }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func persistNow() {
        persistWork?.cancel()
        persistWork = nil
        guard let d = try? JSONIO.encoder.encode(PersistedState(accounts: accounts)) else { return }
        try? JSONIO.atomicWrite(d, to: Paths.state)
    }
}
