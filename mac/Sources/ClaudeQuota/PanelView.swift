import SwiftUI

struct PanelView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.visibleAccounts.isEmpty {
                emptyState
            } else {
                accountGrid
            }

            footer
        }
        .frame(width: Theme.panelWidth(columns: columns))
        .background(Theme.surface)
        // Belt and braces with `DarkWindows`: the views are dark from the first frame,
        // before the window's own appearance has been switched.
        .environment(\.colorScheme, .dark)
    }

    /// Two accounts fit side by side in the width one used to take. A single account
    /// keeps the panel narrow rather than leaving half of it blank.
    private var columns: Int { store.visibleAccounts.count > 1 ? 2 : 1 }

    // MARK: - Accounts

    private var accountGrid: some View {
        ScrollView {
            VStack(spacing: Theme.cardGap) {
                ForEach(gridRows, id: \.first?.key) { row in
                    HStack(alignment: .top, spacing: Theme.cardGap) {
                        ForEach(row) { account in
                            AccountCard(store: store, account: account, now: store.now)
                        }
                        if row.count < columns {
                            Color.clear.frame(width: Theme.cardWidth, height: 1)
                        }
                    }
                }
            }
            .padding(Theme.panelPadding)
        }
        // Asked for its ideal height with no proposal — which is what the MenuBarExtra
        // window does — a ScrollView reports almost nothing, and the panel collapses to
        // its header and footer with every bar squeezed out of existence. `fixedSize`
        // makes it report the height its content actually wants; the frame still caps
        // that, so a long list scrolls instead of growing off the screen.
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var gridRows: [[AccountSnapshot]] {
        let all = store.visibleAccounts
        return stride(from: 0, to: all.count, by: columns).map {
            Array(all[$0..<min($0 + columns, all.count)])
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Quota")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
            freshnessNote
            Button {
                store.requestRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.borderless)
            .help("ขอให้เบราว์เซอร์ดึงค่าใหม่ในการเช็คอินรอบถัดไป (ไม่เกิน 1 นาที)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Two different facts, and only one of them used to be sayable: how old the newest
    /// reading is, and whether anything is still reporting. When they disagree the
    /// silence is the one that matters — nothing arriving is a problem to go and fix,
    /// while an old number on a live channel usually just means an idle afternoon.
    @ViewBuilder private var freshnessNote: some View {
        if let gap = store.quietFor {
            Text(Fmt.quiet(gap))
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.warning)
                .help("ไม่มีรายงานเข้ามา \(Fmt.gap(gap)) — เบราว์เซอร์อาจปิดอยู่ หรือ extension ยังไม่ได้ reload หลังอัปเดตไฟล์")
        } else if let last = store.lastUpdate {
            Text(Fmt.ago(last, now: store.now))
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.inkFaint)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ยังไม่มีข้อมูล")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(statusHint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var statusHint: String {
        switch store.serverState {
        case .listening(let port):
            return "กำลังรออยู่ที่ 127.0.0.1:\(port) — ใส่ token ในหน้าตั้งค่าของ extension ในแต่ละโปรไฟล์ Chrome"
        case .failed(let message):
            return "เปิดพอร์ตไม่ได้: \(message)"
        case .stopped:
            return "เซิร์ฟเวอร์ยังไม่เริ่มทำงาน"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stats = store.stats, store.settings.readStatsCache {
                StatsFooter(stats: stats)
            }
            if case .failed(let message) = store.serverState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                // `SettingsLink`, not `NSApp.sendAction(showSettingsWindow:)`: that
                // selector reports success and opens nothing in a menu-bar-only app.
                // The link alone is still not enough — see `SettingsWindow`.
                SettingsLink {
                    Text("ตั้งค่า…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("ออก")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkFaint)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - One account

struct AccountCard: View {
    @ObservedObject var store: Store
    let account: AccountSnapshot
    let now: Date

    private var freshness: Freshness {
        account.freshness(at: now, thresholds: store.settings.thresholds)
    }

    /// Nil while this row is still being reported. Held once per body so the dot and
    /// the header text cannot disagree about it.
    private var quiet: TimeInterval? { account.quietFor(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                statusDot

                Text(store.label(for: account))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                if let plan = Fmt.plan(account.plan) {
                    Text(plan)
                        .font(.system(size: 8.5, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.chip, in: Capsule())
                        .foregroundStyle(Theme.inkMuted)
                }

                Spacer(minLength: 3)

                // A row that has stopped reporting says so first: its numbers may still
                // be minutes old and perfectly plausible, which is what made the state
                // invisible. Only past that does the reading's own age get the space.
                if let quiet {
                    Text(Fmt.quiet(quiet))
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(1)
                        .help("โปรไฟล์นี้ไม่ได้ส่งรายงานมา \(Fmt.gap(quiet)) — ตัวเลขที่เห็นคือของครั้งล่าสุด")
                } else if freshness >= .stale, let observed = account.observedAt {
                    Text(Fmt.ago(observed, now: now))
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                        .help("อ่านล่าสุด \(Fmt.ago(observed, now: now))")
                } else {
                    SourceBadges(account: account, label: store.label(for: account), now: now)
                }
            }
            .padding(.bottom, 1)

            ForEach(account.structuralLimits) { limit in
                LimitRow(limit: limit, thresholds: store.settings.thresholds, now: now)
            }

            let models = account.modelLimits(at: now)
            if !models.isEmpty {
                ModelGroupRow(limits: models, thresholds: store.settings.thresholds, now: now)
            }

            if let extra = account.extra, extra.enabled, extra.limit > 0 {
                ExtraRow(extra: extra, thresholds: store.settings.thresholds, now: now)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Theme.cardWidth, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Filled while something is reporting, hollow once nothing is. The old dot tracked
    /// only the age of the numbers, which is why a channel that had died looked exactly
    /// like one that simply had nothing new to say.
    @ViewBuilder private var statusDot: some View {
        if quiet != nil {
            Circle()
                .strokeBorder(Theme.warning.opacity(0.8), lineWidth: 1)
                .frame(width: 5, height: 5)
        } else {
            Circle()
                .fill(freshness >= .stale ? Theme.inkFaint : Theme.color(for: 0))
                .frame(width: 5, height: 5)
        }
    }
}

private struct SourceBadges: View {
    let account: AccountSnapshot
    /// The row's own name, so a badge cannot just repeat it.
    let label: String
    let now: Date

    // Which sources still count, and which are only repeating the row's name, is decided
    // in one place — see `AccountSnapshot.sourceBadges(rowLabel:at:)`. A badge that never
    // expires ends up asserting that a browser profile renamed weeks ago is still here.
    var body: some View {
        HStack(spacing: 3) {
            ForEach(account.sourceBadges(rowLabel: label, at: now).prefix(2), id: \.self) { badge($0) }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(Theme.inkFaint)
    }
}

// MARK: - Row geometry

/// The columns every bar row shares. Kept in one place so the model group and the
/// credit row line up with the plain limits above them.
private enum RowMetric {
    static let label: CGFloat = 38
    static let pct: CGFloat = 32
    static let trailing: CGFloat = 54
    static let gap: CGFloat = 6
    /// Where the bar starts, for anything that has to align under it.
    static let barInset: CGFloat = label + gap
}

// MARK: - One limit

struct LimitRow: View {
    let limit: Limit
    let thresholds: FreshnessThresholds
    let now: Date

    private var reading: LimitReading { limit.reading }
    private var expired: Bool { reading.expired(at: now) }
    private var pct: Double { reading.effectivePct(at: now) }
    /// This reading's own age. An account can be reporting every second and still be
    /// showing an Opus figure from three hours ago.
    private var freshness: Freshness { reading.freshness(at: now, thresholds: thresholds) }

    var body: some View {
        HStack(spacing: RowMetric.gap) {
            RowLabel(limit.short)
            QuotaBar(pct: pct, freshness: freshness, hollow: expired)
                .frame(height: Theme.barHeight)
            PctText(pct: pct, expired: expired, freshness: freshness)
            ResetText(resets: reading.resetsAt, expired: expired, now: now)
        }
    }
}

/// The per-model weekly caps, on one row.
///
/// There can be any number of these and they all reset together, so a row each pushed
/// the panel taller for numbers nobody reads twice. The fullest model gets the bar and
/// the label — it is the one that will stop you — and the rest are marks on the same
/// track plus one small line of figures underneath.
struct ModelGroupRow: View {
    let limits: [Limit]
    let thresholds: FreshnessThresholds
    let now: Date

    private var top: Limit { limits[0] }
    private var rest: [Limit] { Array(limits.dropFirst()) }
    private var expired: Bool { top.reading.expired(at: now) }
    private var freshness: Freshness { top.reading.freshness(at: now, thresholds: thresholds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: RowMetric.gap) {
                RowLabel(top.short)
                QuotaBar(pct: top.reading.effectivePct(at: now),
                         freshness: freshness,
                         hollow: expired,
                         ticks: rest.map { $0.reading.effectivePct(at: now) })
                    .frame(height: Theme.barHeight)
                PctText(pct: top.reading.effectivePct(at: now), expired: expired, freshness: freshness)
                ResetText(resets: top.reading.resetsAt, expired: expired, now: now)
            }

            if !rest.isEmpty {
                Text(rest.map { "\($0.short) \(Fmt.pct($0.reading.effectivePct(at: now)))" }
                        .joined(separator: " · "))
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, RowMetric.barInset)
            }
        }
    }
}

private struct RowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.inkMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: RowMetric.label, alignment: .leading)
    }
}

private struct PctText: View {
    let pct: Double
    let expired: Bool
    let freshness: Freshness

    var body: some View {
        Text(expired ? "0%" : "\(freshness.needsTilde ? "~" : "")\(Fmt.pct(pct))")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(expired ? Theme.inkFaint
                                     : Theme.color(for: pct).opacity(freshness.dim))
            .frame(width: RowMetric.pct, alignment: .trailing)
    }
}

/// After a reset the next one is not knowable: the 5-hour window starts on the next
/// message, not on a schedule. Say that instead of inventing a countdown. The exact
/// wall-clock time is a tooltip — the countdown is what anyone acts on.
private struct ResetText: View {
    let resets: Date?
    let expired: Bool
    let now: Date

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(Theme.inkFaint)
            .lineLimit(1)
            .frame(width: RowMetric.trailing, alignment: .trailing)
            .help(tooltip)
    }

    private var text: String {
        guard let resets else { return "" }
        return expired ? "รีเซ็ตแล้ว" : "↻ \(Fmt.countdown(to: resets, from: now))"
    }

    private var tooltip: String {
        guard let resets else { return "" }
        return expired ? "รีเซ็ตแล้ว · รอใช้ครั้งถัดไป" : "รีเซ็ต \(Fmt.clock(resets, now: now))"
    }
}

struct QuotaBar: View {
    let pct: Double
    let freshness: Freshness
    var hollow: Bool = false
    /// Other readings sharing this track, drawn as marks rather than as their own row.
    var ticks: [Double] = []

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if hollow {
                    Capsule().strokeBorder(Theme.inkFaint.opacity(0.55), style:
                        StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                } else {
                    Capsule()
                        .fill(freshness >= .stale
                              ? Theme.inkFaint.opacity(0.7)
                              : Theme.color(for: pct).opacity(freshness.dim))
                        .frame(width: max(pct > 0 ? 3 : 0, geo.size.width * pct / 100))
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        Capsule()
                            .fill(Theme.color(for: tick).opacity(freshness >= .stale ? 0.55 : 0.95))
                            .frame(width: 2)
                            .offset(x: max(0, min(geo.size.width - 2,
                                                  geo.size.width * tick / 100 - 1)))
                    }
                }
            }
        }
    }
}

private struct ExtraRow: View {
    let extra: ExtraUsage
    let thresholds: FreshnessThresholds
    let now: Date

    private var freshness: Freshness {
        Freshness.of(now.timeIntervalSince(extra.observedAt), thresholds: thresholds)
    }

    var body: some View {
        HStack(spacing: RowMetric.gap) {
            RowLabel("เครดิต")
            QuotaBar(pct: extra.pct, freshness: freshness)
                .frame(height: Theme.barHeight)
            PctText(pct: extra.pct, expired: false, freshness: freshness)
            Text(creditText)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
                .frame(width: RowMetric.trailing, alignment: .trailing)
        }
    }

    private var creditText: String {
        let unit = extra.currency ?? ""
        return "\(Int(extra.used))/\(Int(extra.limit)) \(unit)".trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Local stats footer

struct StatsFooter: View {
    let stats: CLIStats

    private var behind: Bool { stats.isBehind(today: Fmt.todayKey) }
    private var day: CLIStats.DayPoint { stats.shown(today: Fmt.todayKey) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 9))
                .foregroundStyle(Theme.inkFaint)
            // These counts are not quota — Claude weights usage server-side — which is
            // why they never feed a bar. Saying so under every render was a caption
            // nobody needed twice; the date already carries the part that changes.
            Text(line)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
                .help(behind
                      ? "จำนวนโทเคน/ข้อความ ไม่ใช่ % quota · Claude Code ยังไม่ได้คำนวณของวันนี้ ตัวเลขนี้จึงเป็นของ \(Fmt.shortDay(day.date))"
                      : "จำนวนโทเคน/ข้อความ ไม่ใช่ % quota")
            Spacer(minLength: 0)
            Sparkline(values: stats.daily.map { Double($0.tokens) })
                .frame(width: 48, height: 13)
        }
    }

    /// Named by the day it actually covers. Claude Code writes this cache lazily, so
    /// "today" is regularly still zero on a machine that has been busy since morning —
    /// printing that zero would report no work rather than no count yet.
    private var line: String {
        let when = behind ? Fmt.shortDay(day.date) : "วันนี้"
        return "\(when) · \(Fmt.tokens(day.tokens)) tok · \(day.messages) ข้อความ"
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 1, 1)
            let count = max(values.count, 1)
            let slot = geo.size.width / CGFloat(count)
            let width = max(1, slot - 1)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(Theme.inkFaint.opacity(0.65))
                        .frame(width: width,
                               height: max(1, geo.size.height * CGFloat(v / maxValue)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}
