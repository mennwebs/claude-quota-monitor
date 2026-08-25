import SwiftUI

struct PanelView: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.visibleAccounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.visibleAccounts.enumerated()), id: \.element.key) { index, account in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            AccountRow(store: store, account: account, now: store.now)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 420)
            }

            Divider()
            footer
        }
        .frame(width: Theme.panelWidth)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Quota").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let last = store.lastUpdate {
                Text(Fmt.ago(last, now: store.now))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Button {
                store.requestRefresh()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("ขอให้เบราว์เซอร์ดึงค่าใหม่ในการเช็คอินรอบถัดไป (ไม่เกิน 1 นาที)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ยังไม่มีข้อมูล").font(.system(size: 12, weight: .medium))
            Text(statusHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 7) {
            if let stats = store.stats, store.settings.readStatsCache {
                StatsFooter(stats: stats)
            }
            if case .failed(let message) = store.serverState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("ตั้งค่า…") { openSettings() }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Spacer()
                Button("ออก") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - Account row

struct AccountRow: View {
    @ObservedObject var store: Store
    let account: AccountSnapshot
    let now: Date

    private var freshness: Freshness {
        account.freshness(at: now, thresholds: store.settings.thresholds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(freshness >= .stale ? Color.secondary.opacity(0.45) : Color.green)
                    .frame(width: 6, height: 6)

                Text(store.label(for: account))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                if let plan = Fmt.plan(account.plan) {
                    Text(plan)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                // Only worth saying once the number has aged enough to distrust.
                if freshness >= .stale, let observed = account.observedAt {
                    Text("อ่านล่าสุด \(Fmt.ago(observed, now: now))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    SourceBadges(account: account)
                }
            }

            ForEach(account.orderedLimits) { limit in
                LimitRow(limit: limit, thresholds: store.settings.thresholds, now: now)
            }

            if let extra = account.extra, extra.enabled, extra.limit > 0 {
                ExtraRow(extra: extra, thresholds: store.settings.thresholds, now: now)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

private struct SourceBadges: View {
    let account: AccountSnapshot

    var body: some View {
        HStack(spacing: 3) {
            if account.sawCLI { badge("CLI") }
            ForEach(account.browsers.prefix(2), id: \.self) { badge($0) }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.tertiary)
    }
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
        HStack(spacing: 7) {
            Text(limit.short)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 46, alignment: .leading)

            QuotaBar(pct: pct, freshness: freshness, hollow: expired)
                .frame(height: Theme.barHeight)

            Text(expired ? "0%" : "\(freshness.needsTilde ? "~" : "")\(Fmt.pct(pct))")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(expired ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(Theme.color(for: pct).opacity(freshness.dim)))
                .frame(width: 40, alignment: .trailing)

            Text(resetText)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 104, alignment: .trailing)
        }
    }

    /// After a reset the next one is not knowable: the 5-hour window starts on the
    /// next message, not on a schedule. Say that instead of inventing a countdown.
    private var resetText: String {
        guard let resets = reading.resetsAt else { return "" }
        if expired { return "รีเซ็ตแล้ว · รอใช้ครั้งถัดไป" }
        return "↻ \(Fmt.countdown(to: resets, from: now)) · \(Fmt.clock(resets, now: now))"
    }
}

struct QuotaBar: View {
    let pct: Double
    let freshness: Freshness
    var hollow: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                if hollow {
                    Capsule().strokeBorder(Color.secondary.opacity(0.35), style:
                        StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                } else {
                    Capsule()
                        .fill(freshness >= .stale
                              ? AnyShapeStyle(Color.secondary.opacity(0.5))
                              : AnyShapeStyle(Theme.color(for: pct).opacity(freshness.dim)))
                        .frame(width: max(pct > 0 ? 3 : 0, geo.size.width * pct / 100))
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
        HStack(spacing: 7) {
            Text("เครดิต")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            QuotaBar(pct: extra.pct, freshness: freshness)
                .frame(height: Theme.barHeight)
            Text(Fmt.pct(extra.pct))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Text(creditText)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 104, alignment: .trailing)
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

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(line)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(behind ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                // These counts are not quota — Claude weights usage server-side — so
                // they get their own line and never feed a bar.
                Text(behind
                     ? "stats-cache ยังคำนวณถึงแค่ \(stats.lastComputedDate) · ไม่ใช่ % quota"
                     : "โทเคนจาก stats-cache · ไม่ใช่ % quota")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Sparkline(values: stats.daily.map { Double($0.tokens) })
                .frame(width: 56, height: 14)
        }
    }

    private var line: String {
        "เครื่องนี้: \(Fmt.tokens(stats.todayTokens)) tok · \(stats.todayMessages) ข้อความ"
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
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: width,
                               height: max(1, geo.size.height * CGFloat(v / maxValue)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}
