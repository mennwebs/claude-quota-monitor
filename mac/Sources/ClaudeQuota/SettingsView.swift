import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        TabView {
            GeneralSettings(store: store)
                .tabItem { Label("ทั่วไป", systemImage: "gearshape") }
            AccountSettings(store: store)
                .tabItem { Label("บัญชี", systemImage: "person.2") }
            LocalSettings(store: store)
                .tabItem { Label("เครื่องนี้", systemImage: "desktopcomputer") }
        }
        .frame(width: 470, height: 400)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var store: Store
    @State private var portText = ""
    @State private var revealToken = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("การเชื่อมต่อ") {
                LabeledContent("สถานะ") { statusText }

                HStack {
                    TextField("พอร์ต", text: $portText)
                        .frame(width: 90)
                        .onSubmit(applyPort)
                    Button("ใช้พอร์ตนี้", action: applyPort)
                        .disabled(UInt16(portText) == nil || UInt16(portText) == store.settings.port)
                }

                LabeledContent("Token") {
                    HStack(spacing: 6) {
                        Text(revealToken ? store.token : String(repeating: "•", count: 24))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Button(revealToken ? "ซ่อน" : "แสดง") { revealToken.toggle() }
                            .buttonStyle(.link)
                        Button("คัดลอก") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.token, forType: .string)
                        }
                        .buttonStyle(.link)
                    }
                }

                Text("วางพอร์ตกับ token นี้ในหน้าตั้งค่าของ extension **ทุกโปรไฟล์** ที่ต้องการให้รายงานเข้ามา")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("การแสดงผล") {
                Toggle("แสดง % ของบัญชีที่เต็มที่สุดข้างไอคอน", isOn: $store.settings.showPercentInMenuBar)
                Toggle("เปิดโปรแกรมตอนล็อกอิน", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LoginItem.set(on) ; loginError = nil }
                        catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("ถือว่าค่าเก่าเมื่อ") {
                MinuteStepper(title: "เริ่มจาง", seconds: $store.settings.thresholds.fresh, range: 1...60)
                MinuteStepper(title: "จางลงอีก", seconds: $store.settings.thresholds.aging, range: 5...240)
                MinuteStepper(title: "เทาทั้งแถว", seconds: $store.settings.thresholds.stale, range: 30...1440)
                Text("ค่าที่เกินขีดสุดท้ายจะกลายเป็นสีเทาและมี ~ นำหน้า แปลว่าอย่าเพิ่งเชื่อ")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(store.settings.port) }
    }

    @ViewBuilder private var statusText: some View {
        switch store.serverState {
        case .listening(let port):
            Label("รับข้อมูลอยู่ที่ 127.0.0.1:\(port)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .stopped:
            Label("หยุดอยู่", systemImage: "pause.circle").foregroundStyle(.secondary)
        }
    }

    private func applyPort() {
        guard let p = UInt16(portText), p >= 1024 else { return }
        store.settings.port = p
    }
}

private struct MinuteStepper: View {
    let title: String
    @Binding var seconds: TimeInterval
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: Binding(
            get: { Int(seconds / 60) },
            set: { seconds = TimeInterval($0 * 60) }
        ), in: range, step: stepSize) {
            LabeledContent(title) { Text("\(Int(seconds / 60)) นาที").monospacedDigit() }
        }
    }

    private var stepSize: Int { range.upperBound > 300 ? 30 : range.upperBound > 100 ? 10 : 1 }
}

// MARK: - Accounts

private struct AccountSettings: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.accounts.isEmpty {
                ContentUnavailableView("ยังไม่มีบัญชีรายงานเข้ามา",
                                       systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("เปิด claude.ai ในโปรไฟล์ที่ตั้ง token ไว้แล้ว หรือรอ Claude Code ในเครื่องรายงานเข้ามา"))
            } else {
                List {
                    ForEach(store.accounts) { account in
                        AccountEditor(store: store, account: account)
                    }
                }
            }
        }
    }
}

private struct AccountEditor: View {
    @ObservedObject var store: Store
    let account: AccountSnapshot
    @State private var draft = ""
    @State private var confirmingForget = false

    private var hidden: Bool { store.settings.hidden.contains(account.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("ชื่อที่จะแสดง", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { store.rename(account.key, to: draft) }

                Button {
                    store.move(account.key, by: -1)
                } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(store.accounts.first?.key == account.key)

                Button {
                    store.move(account.key, by: 1)
                } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless)
                    .disabled(store.accounts.last?.key == account.key)

                Spacer()

                Toggle("แสดง", isOn: Binding(
                    get: { !hidden },
                    set: { show in
                        if show { store.settings.hidden.remove(account.key) }
                        else { store.settings.hidden.insert(account.key) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)

                Button(role: .destructive) {
                    confirmingForget = true
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .onAppear { draft = store.settings.labels[account.key] ?? store.label(for: account) }
        .confirmationDialog("ลบบัญชีนี้ออกจากรายการ?", isPresented: $confirmingForget) {
            Button("ลบ", role: .destructive) { store.forget(account.key) }
            Button("ยกเลิก", role: .cancel) {}
        } message: {
            Text("ถ้ามีรายงานเข้ามาอีก บัญชีนี้จะกลับมาเอง")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let email = account.email { parts.append(email) }
        if let org = account.orgName { parts.append(org) }
        var sources = account.browsers
        if account.sawCLI { sources.insert("CLI", at: 0) }
        if !sources.isEmpty { parts.append(sources.joined(separator: ", ")) }
        parts.append(account.key)
        return parts.joined(separator: " · ")
    }
}

// MARK: - This machine

private struct LocalSettings: View {
    @ObservedObject var store: Store
    @State private var shimStatus = StatuslineInstaller.status()
    @State private var error: String?

    var body: some View {
        Form {
            Section("Claude Code บนเครื่องนี้") {
                LabeledContent("statusline shim") { shimLabel }

                HStack {
                    Button(isInstalled ? "ถอนออก" : "ติดตั้ง") {
                        do {
                            shimStatus = isInstalled ? try StatuslineInstaller.uninstall()
                                                     : try StatuslineInstaller.install()
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    Button("ตรวจใหม่") { shimStatus = StatuslineInstaller.status() }
                        .buttonStyle(.link)
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }

                Text("Claude Code ส่ง `rate_limits` ให้ status line ทุกครั้งที่ render · shim ก๊อป JSON นั้นลงไฟล์แล้วส่งต่อให้ status line เดิมโดยไม่เปลี่ยนหน้าตาอะไร ได้ 5h/7d สด ๆ ไม่ต้องยิง API แลกกับที่มันทำงานเฉพาะตอนมีแถบสถานะให้วาด คือ Claude Code ในเทอร์มินัลเท่านั้น")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("อ่านไฟล์ที่ shim เขียน", isOn: $store.settings.readCLIStatusline)
            }

            Section("สถิติในเครื่อง") {
                Toggle("อ่าน ~/.claude/stats-cache.json", isOn: $store.settings.readStatsCache)
                if let stats = store.stats {
                    let day = stats.shown(today: Fmt.todayKey)
                    LabeledContent("คำนวณถึง") { Text(stats.lastComputedDate).monospacedDigit() }
                    // Same reason as the panel: on a cache that has not been recomputed
                    // today, "วันนี้" is zero, which reads as no work rather than no count.
                    LabeledContent(stats.isBehind(today: Fmt.todayKey) ? Fmt.shortDay(day.date) : "วันนี้") {
                        Text("\(Fmt.tokens(day.tokens)) tok · \(day.messages) ข้อความ")
                            .monospacedDigit()
                    }
                }
                Text("เป็นจำนวนโทเคน/ข้อความ ไม่ใช่ % quota เพราะ Claude คิดน้ำหนักการใช้งานที่ฝั่งเซิร์ฟเวอร์ จึงแปลงกลับเป็นเปอร์เซ็นต์ไม่ได้ ตัวเลขนี้เลยแยกบรรทัดไว้ ไม่เอาไปปนกับ bar")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("ไฟล์") {
                PathRow(title: "state", url: Paths.state)
                PathRow(title: "settings", url: Paths.settings)
                PathRow(title: "cli dump", url: Paths.cliDump)
            }
        }
        .formStyle(.grouped)
    }

    private var isInstalled: Bool {
        if case .installed = shimStatus { return true }
        return false
    }

    @ViewBuilder private var shimLabel: some View {
        switch shimStatus {
        case .installed(let wrapping):
            Label(wrapping.map { "ติดตั้งแล้ว · ห่อ \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "ติดตั้งแล้ว",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .foreign(let command):
            Label("ยังไม่ได้ติดตั้ง · ตอนนี้ใช้ \(URL(fileURLWithPath: command).lastPathComponent)",
                  systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .notConfigured:
            Label("ยังไม่มี status line", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

private struct PathRow: View {
    let title: String
    let url: URL

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                Button("เปิด") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            }
        }
    }
}
