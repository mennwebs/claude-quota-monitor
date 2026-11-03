import Foundation
import SwiftUI

/// Checks on `JSONTextPatch`, the one piece that edits a file the user owns and
/// hand-maintains. Run with `--selftest`.
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() { passed += 1; print("  ✓  \(name)") }
            else { failed += 1; print("  ✗  \(name)") }
        }

        func valid(_ s: String) -> Bool {
            guard let d = s.data(using: .utf8) else { return false }
            return (try? JSONSerialization.jsonObject(with: d)) != nil
        }

        func command(in s: String) -> String? {
            guard let d = s.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let sl = root["statusLine"] as? [String: Any]
            else { return nil }
            return sl["command"] as? String
        }

        print("\n▸ JSONTextPatch — replacing an existing command")
        let existing = """
        {
          "env": { "A": "1" },
          "statusLine": { "type": "command", "command": "/old/line.sh", "padding": 0 },
          "theme": "dark"
        }
        """
        if let out = try? JSONTextPatch.setStatusLineCommand(in: existing, to: "/new/shim.sh") {
            check("result is valid JSON", valid(out))
            check("command replaced", command(in: out) == "/new/shim.sh")
            check("key order preserved", out.range(of: "\"env\"")!.lowerBound < out.range(of: "\"statusLine\"")!.lowerBound)
            check("untouched keys byte-identical", out.contains("\"theme\": \"dark\"") && out.contains("\"env\": { \"A\": \"1\" }"))
            check("sibling keys kept", out.contains("\"padding\": 0"))
            check("only one line differs", diffLineCount(existing, out) == 1)
        } else { failed += 1; print("  ✗  patch returned nil") }

        print("\n▸ JSONTextPatch — statusLine exists but has no command")
        let noCommand = "{\n  \"statusLine\": { \"type\": \"command\" },\n  \"theme\": \"dark\"\n}"
        if let out = try? JSONTextPatch.setStatusLineCommand(in: noCommand, to: "/shim.sh") {
            check("valid JSON", valid(out))
            check("command inserted", command(in: out) == "/shim.sh")
            check("type kept", out.contains("\"type\": \"command\""))
        } else { failed += 1; print("  ✗  patch returned nil") }

        print("\n▸ JSONTextPatch — no statusLine at all")
        let none = "{\n  \"theme\": \"dark\"\n}"
        if let out = try? JSONTextPatch.setStatusLineCommand(in: none, to: "/shim.sh") {
            check("valid JSON", valid(out))
            check("statusLine created", command(in: out) == "/shim.sh")
            check("existing key survives", out.contains("\"theme\": \"dark\""))
        } else { failed += 1; print("  ✗  patch returned nil") }

        print("\n▸ JSONTextPatch — a nested \"command\" must not be mistaken for ours")
        let nested = """
        {
          "hooks": { "Stop": [ { "command": "/hooks/notify.sh" } ] },
          "statusLine": { "command": "/old.sh" }
        }
        """
        if let out = try? JSONTextPatch.setStatusLineCommand(in: nested, to: "/shim.sh") {
            check("valid JSON", valid(out))
            check("statusLine command changed", command(in: out) == "/shim.sh")
            check("hook command untouched", out.contains("/hooks/notify.sh"))
        } else { failed += 1; print("  ✗  patch returned nil") }

        print("\n▸ JSONTextPatch — removal")
        let toRemove = "{\n  \"env\": { \"A\": \"1\" },\n  \"statusLine\": { \"command\": \"/x.sh\" },\n  \"theme\": \"dark\"\n}"
        if let out = try? JSONTextPatch.removeStatusLine(in: toRemove) {
            check("valid JSON after removal", valid(out))
            check("statusLine gone", command(in: out) == nil)
            check("neighbours intact", out.contains("\"env\"") && out.contains("\"theme\""))
        } else { failed += 1; print("  ✗  removal returned nil") }

        print("\n▸ JSONTextPatch — removal of the last member")
        let lastMember = "{\n  \"theme\": \"dark\",\n  \"statusLine\": { \"command\": \"/x.sh\" }\n}"
        if let out = try? JSONTextPatch.removeStatusLine(in: lastMember) {
            check("valid JSON with no trailing comma", valid(out))
            check("theme kept", out.contains("\"theme\""))
        } else { failed += 1; print("  ✗  removal returned nil") }

        print("\n▸ JSONTextPatch — a path with characters that need escaping")
        if let out = try? JSONTextPatch.setStatusLineCommand(in: "{}", to: #"/a "quoted"/b\c.sh"#) {
            check("valid JSON", valid(out))
            check("path round-trips", command(in: out) == #"/a "quoted"/b\c.sh"#)
        } else { failed += 1; print("  ✗  patch returned nil") }

        print("\n▸ JSONTextPatch — empty and near-empty objects (no trailing comma)")
        // JSONSerialization parses `{"a":1,}` happily; Claude Code's JSON.parse does not.
        // These are the shapes that produced one.
        for source in ["{}", "{\n}\n", "{ }", "{\n\n}"] {
            if let out = try? JSONTextPatch.setStatusLineCommand(in: source, to: "/shim.sh") {
                check("\(source.debugDescription) -> no trailing comma", !JSONTextPatch.hasTrailingComma(out))
                check("\(source.debugDescription) -> command set", command(in: out) == "/shim.sh")
                check("\(source.debugDescription) -> parses strictly", valid(out) && !JSONTextPatch.hasTrailingComma(out))
            } else { failed += 1; print("  ✗  \(source.debugDescription) patch returned nil") }
        }
        if let out = try? JSONTextPatch.setStatusLineCommand(in: "{\"statusLine\": {}}", to: "/shim.sh") {
            check("empty statusLine object -> no trailing comma", !JSONTextPatch.hasTrailingComma(out))
            check("empty statusLine object -> command set", command(in: out) == "/shim.sh")
        } else { failed += 1; print("  ✗  empty statusLine patch returned nil") }

        print("\n▸ hasTrailingComma")
        check("detects object trailing comma", JSONTextPatch.hasTrailingComma("{\"a\": 1,}"))
        check("detects array trailing comma", JSONTextPatch.hasTrailingComma("{\"a\": [1,]}"))
        check("detects across newlines", JSONTextPatch.hasTrailingComma("{\"a\": 1,\n}"))
        check("clean object passes", !JSONTextPatch.hasTrailingComma("{\"a\": 1, \"b\": 2}"))
        check("comma inside a string is not one", !JSONTextPatch.hasTrailingComma("{\"a\": \"x,}\"}"))

        print("\n▸ Fmt.todayKey — calendar independence")
        // A Thai-configured Mac defaults to the Buddhist calendar, which would render
        // this year as 2569 and miss every key in stats-cache.json.
        let key = Fmt.todayKey
        check("todayKey is yyyy-MM-dd", key.count == 10 && key.dropFirst(4).first == "-")
        check("todayKey is a Gregorian year, not Buddhist", (Int(key.prefix(4)) ?? 0) < 2400)

        print("\n▸ CLIStats — a cache that has not caught up with today")
        // Claude Code recomputes stats-cache.json lazily, so "today" is regularly zero
        // on a machine that has been busy since morning. Reporting that zero would say
        // no work was done rather than none has been counted.
        let behind = CLIStats(lastComputedDate: "2026-08-24", todayTokens: 0, todayMessages: 0,
                              todaySessions: 0,
                              daily: [CLIStats.DayPoint(date: "2026-08-23", tokens: 10, messages: 2),
                                      CLIStats.DayPoint(date: "2026-08-24", tokens: 99, messages: 7)])
        check("a stale cache is spotted", behind.isBehind(today: "2026-08-25"))
        check("the day shown is the one it covers", behind.shown(today: "2026-08-25").date == "2026-08-24")
        check("with that day's figures, not today's zeros", behind.shown(today: "2026-08-25").tokens == 99)
        let current = CLIStats(lastComputedDate: "2026-08-25", todayTokens: 5, todayMessages: 1,
                               todaySessions: 1,
                               daily: [CLIStats.DayPoint(date: "2026-08-25", tokens: 5, messages: 1)])
        check("a cache that is up to date reports today", !current.isBehind(today: "2026-08-25")
              && current.shown(today: "2026-08-25").tokens == 5)
        let empty = CLIStats(lastComputedDate: "2026-08-01", todayTokens: 0, todayMessages: 0,
                             todaySessions: 0, daily: [])
        check("no history at all falls back to today", empty.shown(today: "2026-08-25").date == "2026-08-25")

        print("\n▸ Fmt.shortDay")
        check("a date key is shortened, not echoed", Fmt.shortDay("2026-08-24") != "2026-08-24")
        check("and names the right day", Fmt.shortDay("2026-08-24").hasPrefix("24"))
        check("an unparseable key passes through", Fmt.shortDay("not-a-date") == "not-a-date")

        print("\n▸ Ingest — an open-ended limit key space")
        func report(_ limitsJSON: String) -> IncomingReport? {
            let body = """
            {"v":1,"source":"extension","account":{"uuid":"u-1"},
             "observedAt":1787648000,"limits":\(limitsJSON)}
            """
            return Ingest.extensionReport(Data(body.utf8))
        }

        if let r = report("""
            {"five_hour":{"pct":41},
             "weekly:fable":{"pct":34,"label":"Fable"},
             "weekly:claude-design":{"pct":5,"label":"Claude Design"}}
            """) {
            check("a model this code has never heard of is accepted", r.limits["weekly:fable"] != nil)
            check("its label rides along", r.limits["weekly:fable"]?.label == "Fable")
            check("a multi-word model name survives slugging", r.limits["weekly:claude-design"]?.label == "Claude Design")
            check("the well-known ceilings still land", r.limits[LimitID.fiveHour]?.pct == 41)
        } else { failed += 1; print("  ✗  dynamic report rejected outright") }

        // An older extension build on another profile keeps reporting the old way.
        if let r = report("{\"seven_day_opus\":{\"pct\":61},\"five_hour\":{\"pct\":10}}") {
            check("legacy seven_day_opus is translated", r.limits["weekly:opus"] != nil)
            check("and gains the label it never sent", r.limits["weekly:opus"]?.label == "Opus")
            check("the old key does not also survive", r.limits["seven_day_opus"] == nil)
        } else { failed += 1; print("  ✗  legacy report rejected outright") }

        if let r = report("""
            {"five_hour":{"pct":1},"weekly:UPPER":{"pct":2},"weekly:":{"pct":3},
             "../../etc/passwd":{"pct":4},"random_key":{"pct":5},
             "weekly:way-too-long-a-slug-for-any-real-model-name-at-all":{"pct":6}}
            """) {
            check("malformed keys are dropped, not rendered", r.limits.count == 1)
            check("and the good one is kept", r.limits[LimitID.fiveHour]?.pct == 1)
        } else { failed += 1; print("  ✗  report with one good limit rejected outright") }

        let many = (0..<40).map { "\"weekly:m\($0)\":{\"pct\":\($0)}" }.joined(separator: ",")
        if let r = report("{\(many)}") {
            check("a flood of invented models is capped", r.limits.count == Ingest.maxLimitsPerReport)
        } else { failed += 1; print("  ✗  flood report rejected outright") }

        print("\n▸ CLI identity — the status line names nobody, so `~/.claude.json` does")
        // What actually happened: `oauthAccount` named one account for weeks while every
        // status line reading belonged to another. The CLI's numbers landed on the wrong
        // card and won every merge there, because they were the freshest thing on it.
        let menn = "3a8f97c3-f7bc-4bd2-bd71-dd0197737884"
        let seed = "85eb22d5-8ee2-4b52-a21e-4792186592dd"
        // Both taken from the machine this was found on: the cached block's fractional
        // ISO and the status line's whole seconds are the same seven-day window, 0.28s apart.
        let cachedSevenDay = "2026-09-07T16:59:59.719144+00:00"
        let liveSevenDay: TimeInterval = 1_788_800_400

        func claudeConfig(oauth: String?, email: String = "m@menn.me",
                          cached: String?, cachedReset: String?) -> Data {
            var blocks: [String] = []
            if let oauth {
                blocks.append("""
                "oauthAccount":{"accountUuid":"\(oauth)","emailAddress":"\(email)",
                 "organizationUuid":"org-of-\(email)","organizationName":"\(email)'s Organization",
                 "organizationRateLimitTier":"default_claude_max_20x"}
                """)
            }
            if let cached {
                blocks.append("""
                "cachedUsageUtilization":{"fetchedAtMs":1788244466824,"accountUuid":"\(cached)",
                 "utilization":{"five_hour":{"utilization":0,"resets_at":null},
                                "seven_day":{"utilization":0,
                                             "resets_at":\(cachedReset.map { "\"\($0)\"" } ?? "null")}}}
                """)
            }
            // Wrapped in unrelated keys, because the real file is hundreds of KB of them.
            return Data("{\"numStartups\":91,\(blocks.joined(separator: ","))}".utf8)
        }

        func attribution(oauth: String?, cached: String?, cachedReset: String? = cachedSevenDay,
                         liveReset: TimeInterval? = liveSevenDay) -> CLIAttribution? {
            CLIIdentity.read(from: claudeConfig(oauth: oauth, cached: cached, cachedReset: cachedReset))?
                .attribution(sevenDayResetsAt: liveReset.map { Date(timeIntervalSince1970: $0) })
        }

        check("the cached reset parses out of its fractional ISO form",
              CLIIdentity.read(from: claudeConfig(oauth: menn, cached: seed, cachedReset: cachedSevenDay))?
                  .credential?.sevenDayResetsAt
                  .map { abs($0.timeIntervalSince1970 - 1_788_800_399.719) < 0.01 } == true)

        check("blocks that agree confirm the identity", {
            guard case .confirmed(let id)? = CLIIdentity
                .read(from: claudeConfig(oauth: seed, email: "m@seedwebs.com",
                                         cached: seed, cachedReset: cachedSevenDay))?
                .attribution(sevenDayResetsAt: Date(timeIntervalSince1970: liveSevenDay))
            else { return false }
            return id.accountUuid == seed && id.email == "m@seedwebs.com"
        }())

        check("a disagreement is settled by the window the numbers came from", {
            guard case .corrected(let id)? = attribution(oauth: menn, cached: seed) else { return false }
            return id.accountUuid == seed
        }())
        check("and none of the other account's details ride along", {
            guard case .corrected(let id)? = attribution(oauth: menn, cached: seed) else { return false }
            return id.email == nil && id.orgId == nil && id.orgName == nil && id.plan == nil
        }())
        check("a second of rounding between the two is still the same window", {
            guard case .corrected? = attribution(oauth: menn, cached: seed,
                                                 liveReset: liveSevenDay + 1) else { return false }
            return true
        }())
        check("a window a minute and a half away is not",
              attribution(oauth: menn, cached: seed, liveReset: liveSevenDay + 100) == .refused)
        check("nor is another account's seven-day window",
              attribution(oauth: menn, cached: seed, liveReset: 1_788_663_599) == .refused)
        check("a disagreement with no cached reset to check is refused",
              attribution(oauth: menn, cached: seed, cachedReset: nil) == .refused)
        check("as is one where the status line sent no seven-day window at all",
              attribution(oauth: menn, cached: seed, liveReset: nil) == .refused)

        check("with no cached block there is nothing to check against", {
            guard case .unconfirmed(let id)? = attribution(oauth: menn, cached: nil) else { return false }
            return id.accountUuid == menn && id.plan == "default_claude_max_20x"
        }())
        check("a file with neither block is no identity at all",
              CLIIdentity.read(from: claudeConfig(oauth: nil, cached: nil, cachedReset: nil)) == nil)
        check("a cached block with no oauthAccount beside it still has to match the window", {
            guard case .corrected(let id)? = attribution(oauth: nil, cached: seed) else { return false }
            return id.accountUuid == seed
        }())

        // End to end, through the thing `LocalSources` actually calls.
        let cliObserved = Date(timeIntervalSince1970: 1_788_263_041)
        func statusline(sevenDayResetsAt: TimeInterval = liveSevenDay) -> Data {
            Data("""
            {"session_id":"s","version":"2.1.252","rate_limits":{
               "five_hour":{"used_percentage":3,"resets_at":1788280200},
               "seven_day":{"used_percentage":11,"resets_at":\(Int(sevenDayResetsAt))}}}
            """.utf8)
        }
        func cliReport(oauth: String?, cached: String?,
                       sevenDayResetsAt: TimeInterval = liveSevenDay) -> IncomingReport? {
            Ingest.cliReport(
                statuslineJSON: statusline(sevenDayResetsAt: sevenDayResetsAt),
                identity: CLIIdentity.read(from: claudeConfig(oauth: oauth, cached: cached,
                                                              cachedReset: cachedSevenDay)),
                observedAt: cliObserved, receivedAt: cliObserved)
        }
        check("the report lands on the account whose window it describes",
              cliReport(oauth: menn, cached: seed)?.accountUuid == seed)
        check("carrying no email to relabel that row with",
              cliReport(oauth: menn, cached: seed)?.email == nil)
        check("and still carrying the numbers",
              cliReport(oauth: menn, cached: seed)?.limits[LimitID.fiveHour]?.pct == 3)
        check("a report that cannot be attributed is never produced",
              cliReport(oauth: menn, cached: seed, sevenDayResetsAt: 1_788_663_599) == nil)
        check("nor is one with no ~/.claude.json behind it",
              Ingest.cliReport(statuslineJSON: statusline(), identity: nil,
                               observedAt: cliObserved, receivedAt: cliObserved) == nil)
        check("the agreeing case still carries the whole identity",
              cliReport(oauth: seed, cached: seed)?.orgName == "m@menn.me's Organization")

        print("\n▸ Limit — display names")
        func limit(_ id: String, _ label: String?) -> Limit {
            Limit(id: id, reading: LimitReading(pct: 0, resetsAt: nil, observedAt: Date(),
                                                source: .ext, label: label))
        }
        check("five_hour shows as 5h", limit(LimitID.fiveHour, nil).short == "5h")
        check("seven_day shows as 7d", limit(LimitID.sevenDay, nil).short == "7d")
        check("a model uses the API's own wording", limit("weekly:sonnet", "Sonnet").short == "Sonnet")
        check("a redundant Claude prefix is dropped", limit("weekly:claude-design", "Claude Design").short == "Design")
        check("Claude on its own is left alone", limit("weekly:claude", "Claude").short == "Claude")
        check("a label-less model falls back to its slug", limit("weekly:fable", nil).short == "Fable")
        check("the session sorts first", limit(LimitID.fiveHour, nil).rank < limit("weekly:opus", "Opus").rank)

        print("\n▸ Contact — a dead channel is not the same as an old number")
        let t0 = Date(timeIntervalSince1970: 1_787_700_000)
        func reading(_ pct: Double, _ at: Date, _ src: ReadingSource = .ext,
                     label: String? = nil) -> LimitReading {
            LimitReading(pct: pct, resetsAt: nil, observedAt: at, source: src, label: label)
        }
        func extReport(_ limits: [String: LimitReading], at: Date) -> IncomingReport {
            IncomingReport(source: .ext, limits: limits, receivedAt: at)
        }

        var acct = AccountSnapshot(key: "acct:1")
        acct.absorb(extReport([LimitID.fiveHour: reading(10, t0)], at: t0))
        check("a report stamps contact", acct.lastContactAt == t0)
        check("a minute later is not silence", acct.quietFor(at: t0.addingTimeInterval(60)) == nil)
        check("six minutes is", (acct.quietFor(at: t0.addingTimeInterval(6 * 60)) ?? 0) >= 5 * 60)
        check("a later report clears it", {
            var a = acct
            let then = t0.addingTimeInterval(600)
            a.absorb(extReport([LimitID.fiveHour: reading(10, then)], at: then))
            return a.quietFor(at: then.addingTimeInterval(60)) == nil
        }())
        check("a report that arrives out of order cannot rewind contact", {
            var a = acct
            a.absorb(extReport([LimitID.fiveHour: reading(9, t0)], at: t0.addingTimeInterval(-3600)))
            return a.lastContactAt == t0
        }())
        // Rows persisted before contact was tracked still have to be judged, and the
        // reading's own age is the only evidence they carry.
        var legacyRow = AccountSnapshot(key: "acct:legacy")
        legacyRow.limits[LimitID.fiveHour] = reading(5, t0)
        check("with no contact recorded the reading's age stands in",
              (legacyRow.quietFor(at: t0.addingTimeInterval(3600)) ?? 0) >= 3600)

        print("\n▸ Model caps the API has stopped listing")
        // Exactly the Seed card: the weekly list came back carrying Fable only, and
        // nothing was ever going to overwrite yesterday's Opus and Design readings.
        let thirteenHoursAgo = t0.addingTimeInterval(-13 * 3600)
        var retired = AccountSnapshot(key: "acct:seed")
        retired.limits = [
            LimitID.fiveHour: reading(23, thirteenHoursAgo),
            LimitID.sevenDay: reading(26, thirteenHoursAgo),
            "weekly:opus": reading(61, thirteenHoursAgo, label: "Opus"),
            "weekly:claude-design": reading(7, thirteenHoursAgo, label: "Claude Design"),
            "weekly:fable": reading(0, thirteenHoursAgo, label: "Fable")
        ]
        retired.absorb(extReport([
            LimitID.fiveHour: reading(23, t0),
            LimitID.sevenDay: reading(26, t0),
            "weekly:fable": reading(0, t0, label: "Fable")
        ], at: t0))
        check("a cap the report no longer carries is dropped", retired.limits["weekly:opus"] == nil)
        check("all of them, not just the first", retired.limits["weekly:claude-design"] == nil)
        check("the cap still being reported stays", retired.limits["weekly:fable"] != nil)
        check("the two structural ceilings are never candidates",
              retired.limits[LimitID.fiveHour] != nil && retired.limits[LimitID.sevenDay] != nil)

        var live = AccountSnapshot(key: "acct:live")
        live.limits = ["weekly:opus": reading(61, t0.addingTimeInterval(-120), label: "Opus"),
                       LimitID.fiveHour: reading(1, t0.addingTimeInterval(-120))]
        live.absorb(extReport([LimitID.fiveHour: reading(1, t0)], at: t0))
        check("one short report cannot erase a reading that is still live",
              live.limits["weekly:opus"] != nil)

        var viaCLI = AccountSnapshot(key: "acct:cli")
        viaCLI.limits = ["weekly:opus": reading(61, thirteenHoursAgo, label: "Opus")]
        viaCLI.absorb(IncomingReport(source: .cli,
                                     limits: [LimitID.fiveHour: reading(4, t0, .cli)],
                                     receivedAt: t0))
        check("the status line carries no caps, so its silence retires nothing",
              viaCLI.limits["weekly:opus"] != nil)

        print("\n▸ A 5-hour window the source has stopped reporting")
        // Exactly the Ultra cards: the extension used to send `five_hour` as 0% with no
        // reset, and the build that stops sending it must take the row away with it.
        var ultra = AccountSnapshot(key: "acct:ultra")
        ultra.limits = [LimitID.fiveHour: reading(0, t0.addingTimeInterval(-60)),
                        LimitID.sevenDay: reading(5, t0.addingTimeInterval(-60))]
        ultra.absorb(extReport([LimitID.sevenDay: reading(5, t0),
                                "weekly:fable": reading(0, t0, label: "Fable")], at: t0))
        check("a report without five_hour retires the source's own 5h at once",
              ultra.limits[LimitID.fiveHour] == nil)
        check("the rest of the report still lands",
              ultra.limits[LimitID.sevenDay]?.pct == 5 && ultra.limits["weekly:fable"] != nil)
        check("and the card is left with 7d alone as its ceiling",
              ultra.structuralLimits.map(\.id) == [LimitID.sevenDay])

        var otherSource = AccountSnapshot(key: "acct:other")
        otherSource.limits = [LimitID.fiveHour: reading(12, t0.addingTimeInterval(-60), .cli)]
        otherSource.absorb(extReport([LimitID.sevenDay: reading(5, t0)], at: t0))
        check("it never speaks for another source's 5h",
              otherSource.limits[LimitID.fiveHour]?.pct == 12)

        var redelivered = AccountSnapshot(key: "acct:redelivered")
        redelivered.limits = [LimitID.fiveHour: reading(30, t0)]
        redelivered.absorb(extReport([LimitID.sevenDay: reading(8, t0.addingTimeInterval(-600))],
                                     at: t0))
        check("an older reading re-delivered cannot erase a newer 5h",
              redelivered.limits[LimitID.fiveHour]?.pct == 30)

        var cliUltra = AccountSnapshot(key: "acct:cli-ultra")
        cliUltra.limits = [LimitID.fiveHour: reading(0, t0.addingTimeInterval(-60), .cli)]
        cliUltra.absorb(IncomingReport(source: .cli,
                                       limits: [LimitID.sevenDay: reading(40, t0, .cli)],
                                       receivedAt: t0))
        check("the status line retires its own 5h the same way",
              cliUltra.limits[LimitID.fiveHour] == nil)

        var stillLive = AccountSnapshot(key: "acct:still-live")
        stillLive.limits = [LimitID.fiveHour: reading(11, t0.addingTimeInterval(-60))]
        stillLive.absorb(extReport([LimitID.fiveHour: reading(13, t0),
                                    LimitID.sevenDay: reading(7, t0)], at: t0))
        check("an account that still has the window keeps it",
              stillLive.limits[LimitID.fiveHour]?.pct == 13)

        // Two browser profiles on one account, both `.ext`: B read the window at t0, A saw
        // none five minutes later. B re-posts its cache every minute until its next fetch —
        // forever, if that fetch keeps failing — and must not bring the row back each time.
        var twoProfiles = AccountSnapshot(key: "acct:two-profiles")
        let tB = t0, tA = t0.addingTimeInterval(300)
        let fromB = extReport([LimitID.fiveHour: reading(40, tB), LimitID.sevenDay: reading(9, tB)],
                              at: tB)
        let fromA = extReport([LimitID.sevenDay: reading(9, tA)], at: tA)
        twoProfiles.absorb(fromB)
        twoProfiles.absorb(fromA)
        check("the newer profile's \"no window\" retires the 5h",
              twoProfiles.limits[LimitID.fiveHour] == nil)
        var flapped = false
        for minute in 1...4 {
            twoProfiles.absorb(IncomingReport(source: .ext, limits: fromB.limits,
                                              receivedAt: tA.addingTimeInterval(Double(minute) * 60)))
            if twoProfiles.limits[LimitID.fiveHour] != nil { flapped = true }
            twoProfiles.absorb(IncomingReport(source: .ext, limits: fromA.limits,
                                              receivedAt: tA.addingTimeInterval(Double(minute) * 60 + 30)))
        }
        check("the other profile's older re-post cannot bring it back", !flapped)
        twoProfiles.absorb(extReport([LimitID.fiveHour: reading(2, t0.addingTimeInterval(1200)),
                                      LimitID.sevenDay: reading(0, t0.addingTimeInterval(1200))],
                                     at: t0.addingTimeInterval(1200)))
        check("a newer 5h is the window coming back, and is taken",
              twoProfiles.limits[LimitID.fiveHour]?.pct == 2)

        // Store's fold of a duplicate row is `foldLimits`, so this is the code it runs.
        // Both directions, and the case where merging in the wrong order would cost a
        // 5h from another source.
        var retiredRow = AccountSnapshot(key: "acct:retired-row")
        retiredRow.absorb(extReport([LimitID.sevenDay: reading(9, tA)], at: tA))
        var staleRow = AccountSnapshot(key: "org:stale-row")
        staleRow.limits = [LimitID.fiveHour: reading(40, tB), LimitID.sevenDay: reading(9, tB)]

        var survivorRetired = retiredRow
        survivorRetired.foldLimits(from: staleRow)
        check("folding in a row that still holds an older 5h does not revive it",
              survivorRetired.limits[LimitID.fiveHour] == nil)

        var survivorStale = staleRow
        survivorStale.foldLimits(from: retiredRow)
        check("nor does keeping that row and folding the retired one into it",
              survivorStale.limits[LimitID.fiveHour] == nil &&
              survivorStale.sessionRetiredAt?[ReadingSource.ext.rawValue] == tA)
        check("and the rest of the fold is still newest-wins",
              survivorStale.limits[LimitID.sevenDay]?.observedAt == tA)

        var cliHolder = retiredRow
        cliHolder.limits[LimitID.fiveHour] = reading(6, tB.addingTimeInterval(-60), .cli)
        cliHolder.foldLimits(from: staleRow)
        check("a 5h from another source is not displaced by a retired one",
              cliHolder.limits[LimitID.fiveHour]?.pct == 6 &&
              cliHolder.limits[LimitID.fiveHour]?.source == .cli)

        if let data = try? JSONIO.encoder.encode(twoProfiles),
           let back = try? JSONIO.decoder.decode(AccountSnapshot.self, from: data) {
            check("the retirement survives a save", back.sessionRetiredAt == twoProfiles.sessionRetiredAt)
        } else {
            check("the retirement survives a save", false)
        }

        print("\n▸ A Team seat's model caps — hidden unless asked for")
        let t1 = t0.addingTimeInterval(60)
        // The 7Sol card: a Team seat whose Fable cap sits at 0% beside a 52% week.
        var teamSeat = AccountSnapshot(key: "acct:team")
        teamSeat.absorb(IncomingReport(source: .ext, plan: "default_raven",
                                       limits: [LimitID.sevenDay: reading(52, t0),
                                                "weekly:fable": reading(0, t0, label: "Fable")],
                                       receivedAt: t0))
        check("a raven tier is a Team seat", teamSeat.isTeam)
        check("its model caps are hidden by default", !teamSeat.showsModelCaps(onTeam: false))
        check("and shown once the setting is on", teamSeat.showsModelCaps(onTeam: true))
        check("AppSettings starts with them hidden", AppSettings().showTeamModelCaps == false)

        var maxSeat = AccountSnapshot(key: "acct:max")
        maxSeat.plan = "default_claude_max_20x"
        maxSeat.limits = ["weekly:fable": reading(0, t0, label: "Fable")]
        check("every other plan always shows them",
              maxSeat.showsModelCaps(onTeam: false) && !maxSeat.isTeam)
        check("so does a row whose plan nobody has reported",
              AccountSnapshot(key: "acct:unknown").showsModelCaps(onTeam: false))

        // The menu bar glyph must not be filled by a cap the card has hidden.
        var spentCap = teamSeat
        spentCap.limits["weekly:fable"] = reading(90, t0, label: "Fable")
        check("a hidden cap does not bind the menu bar glyph",
              spentCap.binding(at: t0, modelCaps: false)?.id == LimitID.sevenDay)
        check("a shown one still does",
              spentCap.binding(at: t0, modelCaps: true)?.id == "weekly:fable" &&
              spentCap.binding(at: t0)?.id == "weekly:fable")

        print("\n▸ The plan — the extension's \"Team\" holds against the status line's tier")
        // claude.ai names a Team seat `default_raven`; Claude Code's profile words the same
        // seat as a Max tier, and the status line reports on every render. Last-writer-wins
        // would put the Fable row back on the card within seconds of every extension report.
        var flipped = teamSeat
        flipped.absorb(IncomingReport(source: .cli, plan: "default_claude_max_5x",
                                      limits: [LimitID.sevenDay: reading(52, t0.addingTimeInterval(5), .cli)],
                                      receivedAt: t0.addingTimeInterval(5)))
        check("a status line report does not overwrite the extension's plan",
              flipped.plan == "default_raven" && flipped.isTeam)
        check("and its readings still land",
              flipped.limits[LimitID.sevenDay]?.source == .cli)

        // The hold is only for the disagreement it exists for. Elsewhere the sources read
        // the same tier, and the extension's is cached until claude.ai is next opened.
        var upgraded = AccountSnapshot(key: "acct:upgraded")
        upgraded.absorb(IncomingReport(source: .ext, plan: "default_claude_max_5x",
                                       limits: [LimitID.sevenDay: reading(5, t0)], receivedAt: t0))
        upgraded.absorb(IncomingReport(source: .cli, plan: "default_claude_max_20x",
                                       limits: [LimitID.sevenDay: reading(5, t0.addingTimeInterval(60), .cli)],
                                       receivedAt: t0.addingTimeInterval(60)))
        check("a non-Team plan from the extension does not hold off the status line",
              upgraded.plan == "default_claude_max_20x")

        // And it lapses with the extension: a profile gone quiet must not pin the card.
        let lapsed = t0.addingTimeInterval(AccountSnapshot.sourceBadgeAge + 60)
        var leftTeam = teamSeat
        leftTeam.absorb(IncomingReport(source: .cli, plan: "default_claude_max_5x",
                                       limits: [LimitID.sevenDay: reading(5, lapsed, .cli)],
                                       receivedAt: lapsed))
        check("an extension silent past the badge's age no longer holds the plan",
              leftTeam.plan == "default_claude_max_5x" && !leftTeam.isTeam)

        var restated = teamSeat
        let later = t0.addingTimeInterval(AccountSnapshot.sourceBadgeAge - 600)
        restated.absorb(IncomingReport(source: .ext, plan: "default_raven",
                                       limits: [LimitID.sevenDay: reading(52, later)], receivedAt: later))
        restated.absorb(IncomingReport(source: .cli, plan: "default_claude_max_5x",
                                       limits: [LimitID.sevenDay: reading(52, lapsed, .cli)],
                                       receivedAt: lapsed))
        check("each extension report renews the hold", restated.plan == "default_raven")

        // The extension re-posts its cache every minute even while its fetch is failing.
        // Those re-posts must neither renew the hold nor, once it has lapsed, flip the card
        // back each minute against the status line.
        var frozen = teamSeat
        for minute in stride(from: 60.0, through: AccountSnapshot.sourceBadgeAge + 600, by: 60) {
            frozen.absorb(IncomingReport(source: .ext, plan: "default_raven",
                                         limits: [LimitID.sevenDay: reading(52, t0)],
                                         receivedAt: t0.addingTimeInterval(minute)))
        }
        let afterFreeze = t0.addingTimeInterval(AccountSnapshot.sourceBadgeAge + 660)
        frozen.absorb(IncomingReport(source: .cli, plan: "default_claude_max_5x",
                                     limits: [LimitID.sevenDay: reading(52, afterFreeze, .cli)],
                                     receivedAt: afterFreeze))
        check("a re-posted cache does not renew the hold", frozen.plan == "default_claude_max_5x")
        frozen.absorb(IncomingReport(source: .ext, plan: "default_raven",
                                     limits: [LimitID.sevenDay: reading(52, t0)],
                                     receivedAt: afterFreeze.addingTimeInterval(60)))
        check("nor take the plan back from a newer statement", frozen.plan == "default_claude_max_5x")

        // First launch of a build, or a new row: the status line speaks first, freshly
        // stamped, and the extension's next re-post carries a reading minutes older.
        var cliFirst = AccountSnapshot(key: "acct:cli-first")
        cliFirst.absorb(IncomingReport(source: .cli, plan: "default_claude_max_5x",
                                       limits: [LimitID.sevenDay: reading(52, t1, .cli)],
                                       receivedAt: t1))
        cliFirst.absorb(IncomingReport(source: .ext, plan: "default_raven",
                                       limits: [LimitID.sevenDay: reading(52, t0)],
                                       receivedAt: t1.addingTimeInterval(5)))
        check("an extension Team minutes older than the status line still takes the card",
              cliFirst.plan == "default_raven")

        // And a seat that left Team says so through the extension too: same source, newest wins.
        var leaver = teamSeat
        leaver.absorb(IncomingReport(source: .ext, plan: "default_claude_max_5x",
                                     limits: [LimitID.sevenDay: reading(5, t1)], receivedAt: t1))
        check("the extension can take its own Team back", leaver.plan == "default_claude_max_5x")

        var cliOnly = AccountSnapshot(key: "acct:cli-only")
        cliOnly.absorb(IncomingReport(source: .cli, plan: "default_pro",
                                      limits: [LimitID.sevenDay: reading(5, t0, .cli)],
                                      receivedAt: t0))
        cliOnly.absorb(IncomingReport(source: .cli, plan: "default_claude_max_5x",
                                      limits: [LimitID.sevenDay: reading(6, t0.addingTimeInterval(60), .cli)],
                                      receivedAt: t0.addingTimeInterval(60)))
        check("a source may still revise its own word", cliOnly.plan == "default_claude_max_5x")
        cliOnly.absorb(IncomingReport(source: .ext, plan: "default_raven",
                                      limits: [LimitID.sevenDay: reading(6, t0.addingTimeInterval(120))],
                                      receivedAt: t0.addingTimeInterval(120)))
        check("and the extension's overrides the status line's",
              cliOnly.plan == "default_raven")
        cliOnly.absorb(IncomingReport(source: .ext,
                                      limits: [LimitID.sevenDay: reading(6, t0.addingTimeInterval(180))],
                                      receivedAt: t0.addingTimeInterval(180)))
        check("a report with no plan leaves it alone", cliOnly.plan == "default_raven")

        // A row persisted before the plan's source was recorded.
        var legacyPlan = AccountSnapshot(key: "acct:legacy-plan")
        legacyPlan.plan = "default_raven"
        legacyPlan.absorb(IncomingReport(source: .ext, plan: "default_raven",
                                         limits: [LimitID.sevenDay: reading(1, t0)], receivedAt: t0))
        check("an older row picks up the source on its next extension report",
              legacyPlan.planStatements?[ReadingSource.ext.rawValue] != nil && legacyPlan.plan == "default_raven")

        // Store folds duplicates through `foldPlan`.
        var cliRow = AccountSnapshot(key: "email:x")
        cliRow.absorb(IncomingReport(source: .cli, plan: "default_claude_max_5x",
                                     limits: [LimitID.sevenDay: reading(1, t1, .cli)], receivedAt: t1))
        var keptCLI = cliRow
        keptCLI.foldPlan(from: teamSeat)
        check("folding in the extension's row takes its plan",
              keptCLI.plan == "default_raven" && keptCLI.planStatements?[ReadingSource.ext.rawValue] != nil)
        var keptExt = teamSeat
        keptExt.foldPlan(from: cliRow)
        check("and folding the status line's row into it keeps the extension's",
              keptExt.plan == "default_raven")
        var olderExt = teamSeat
        olderExt.foldPlan(from: restated)
        var newerExt = restated
        newerExt.foldPlan(from: teamSeat)
        check("between two extension plans the fold keeps the more recent, either way",
              olderExt.planStatements?[ReadingSource.ext.rawValue]?.at == later && newerExt.planStatements?[ReadingSource.ext.rawValue]?.at == later)

        // The `upgraded` reports, split across two rows: folding must reach what absorbing
        // them in turn did.
        var extMax = AccountSnapshot(key: "acct:ext-max")
        extMax.absorb(IncomingReport(source: .ext, plan: "default_claude_max_5x",
                                     limits: [LimitID.sevenDay: reading(5, t0)], receivedAt: t0))
        var cliMax = AccountSnapshot(key: "email:cli-max")
        cliMax.absorb(IncomingReport(source: .cli, plan: "default_claude_max_20x",
                                     limits: [LimitID.sevenDay: reading(5, t1, .cli)], receivedAt: t1))
        var foldA = extMax, foldB = cliMax
        foldA.foldPlan(from: cliMax)
        foldB.foldPlan(from: extMax)
        check("a fold takes the newer non-Team plan, whichever row survives",
              foldA.plan == "default_claude_max_20x" && foldB.plan == "default_claude_max_20x")

        var staleTeam = teamSeat
        var freshCLI = AccountSnapshot(key: "email:fresh")
        freshCLI.absorb(IncomingReport(source: .cli, plan: "default_claude_max_5x",
                                       limits: [LimitID.sevenDay: reading(5, lapsed, .cli)],
                                       receivedAt: lapsed))
        staleTeam.foldPlan(from: freshCLI)
        freshCLI.foldPlan(from: teamSeat)
        check("and a lapsed Team plan does not win a fold",
              staleTeam.plan == "default_claude_max_5x" && freshCLI.plan == "default_claude_max_5x")

        var legacyVictim = AccountSnapshot(key: "email:legacy")
        legacyVictim.plan = "default_pro"
        var noPlan = AccountSnapshot(key: "acct:no-plan")
        noPlan.foldPlan(from: legacyVictim)
        check("a row from before statements were kept still lends its plan", noPlan.plan == "default_pro")

        var blank = AccountSnapshot(key: "org:blank")
        blank.foldPlan(from: cliRow)
        check("a row with no plan takes whatever the other knew",
              blank.plan == "default_claude_max_5x")

        // Two profiles on one account: A still caches the Max tier it read before the seat
        // moved, B reads Team. A status line report between them must not let B's older
        // re-post take back a card A has already contradicted.
        var twoTiers = AccountSnapshot(key: "acct:two-tiers")
        let e1 = t0, e2 = t0.addingTimeInterval(600), c = t0.addingTimeInterval(900)
        func ext(_ plan: String, _ at: Date, receivedAt: Date) -> IncomingReport {
            IncomingReport(source: .ext, plan: plan, limits: [LimitID.sevenDay: reading(5, at)],
                           receivedAt: receivedAt)
        }
        twoTiers.absorb(ext("default_raven", e1, receivedAt: e1))
        twoTiers.absorb(ext("default_claude_max_5x", e2, receivedAt: e2))
        twoTiers.absorb(IncomingReport(source: .cli, plan: "default_claude_max_20x",
                                       limits: [LimitID.sevenDay: reading(5, c, .cli)], receivedAt: c))
        twoTiers.absorb(ext("default_raven", e1, receivedAt: c.addingTimeInterval(30)))
        check("an extension Team since contradicted cannot win the card back",
              twoTiers.plan == "default_claude_max_20x")

        // Folding must land where absorbing the same reports in turn would. Deterministic
        // pseudo-random streams, split across two rows, folded both ways round.
        var lcg: UInt64 = 0x5eed
        func next(_ n: Int) -> Int {
            lcg = lcg &* 6364136223846793005 &+ 1442695040888963407
            return Int((lcg >> 33) % UInt64(n))
        }
        let kinds: [(ReadingSource, String)] = [(.ext, "default_raven"), (.ext, "default_claude_max_5x"),
                                                (.cli, "default_claude_max_5x"), (.cli, "default_claude_max_20x")]
        var mismatches = 0
        for _ in 0..<3000 {
            var used = Set<Int>()
            var stream: [(Int, IncomingReport)] = []
            for _ in 0..<(2 + next(5)) {
                var minute = next(480)
                while used.contains(minute) { minute = next(480) }
                used.insert(minute)
                let (src, plan) = kinds[next(kinds.count)]
                let at = t0.addingTimeInterval(Double(minute) * 60)
                stream.append((next(2), IncomingReport(source: src, plan: plan,
                                                       limits: [LimitID.sevenDay: reading(5, at, src)],
                                                       receivedAt: at)))
            }
            stream.sort { $0.1.receivedAt < $1.1.receivedAt }
            var whole = AccountSnapshot(key: "acct:whole")
            var rows = [AccountSnapshot(key: "acct:a"), AccountSnapshot(key: "email:b")]
            for (side, r) in stream { whole.absorb(r); rows[side].absorb(r) }
            var ab = rows[0], ba = rows[1]
            ab.foldPlan(from: rows[1])
            ba.foldPlan(from: rows[0])
            if ab.plan != whole.plan || ba.plan != whole.plan { mismatches += 1 }
        }
        check("a fold reaches what absorbing in turn does, over 3000 streams", mismatches == 0)

        if let data = try? JSONIO.encoder.encode(teamSeat),
           let back = try? JSONIO.decoder.decode(AccountSnapshot.self, from: data) {
            check("the plan statements survive a save", back.planStatements == teamSeat.planStatements && back.planStatements != nil)
        } else {
            check("the plan statements survive a save", false)
        }

        print("\n▸ Fmt.plan — the names on the badge, not the tier ids")
        check("Max 20x is shown as Ultra", Fmt.plan("default_claude_max_20x") == "Ultra")
        check("an ultra tier id is shown as Ultra", Fmt.plan("default_claude_ultra") == "Ultra")
        check("Max 5x keeps its name", Fmt.plan("default_claude_max_5x") == "Max 5x")
        check("a bare Max stays Max", Fmt.plan("default_claude_max") == "Max")
        check("a Team seat's codename is shown as Team", Fmt.plan("default_raven") == "Team")
        check("Pro is unchanged", Fmt.plan("default_pro") == "Pro")
        check("an unknown tier still reads", Fmt.plan("default_claude_enterprise") == "Claude Enterprise")
        check("no tier, no badge", Fmt.plan(nil) == nil && Fmt.plan("  ") == nil)

        print("\n▸ Source badges")
        var badged = AccountSnapshot(key: "acct:badges")
        badged.sourceSeen = ["Chrome": t0, "Seed": t0]
        check("a badge that only repeats the row name goes",
              badged.sourceBadges(rowLabel: "Seed", at: t0) == ["Chrome"])
        check("case and padding do not save it",
              badged.sourceBadges(rowLabel: "  seed ", at: t0) == ["Chrome"])
        check("one that says something new is kept",
              badged.sourceBadges(rowLabel: "Menn", at: t0) == ["Chrome", "Seed"])
        var solo = AccountSnapshot(key: "acct:solo")
        solo.sourceSeen = ["Novem": t0]
        check("and the only badge may go entirely",
              solo.sourceBadges(rowLabel: "Novem", at: t0).isEmpty)

        // A badge asserts that the source is feeding this row. The CLI one was a boolean
        // that could only ever be switched on, so it kept claiming a status line that had
        // not run since yesterday.
        var mixed = AccountSnapshot(key: "acct:mixed")
        mixed.sourceSeen = ["CLI": t0.addingTimeInterval(-22 * 3600), "Dia": t0]
        check("a source that has not observed anything in hours loses its badge",
              mixed.sourceBadges(rowLabel: "Menn", at: t0) == ["Dia"])
        mixed.sourceSeen?["CLI"] = t0.addingTimeInterval(-60)
        check("and gets it back the moment it reports again",
              mixed.sourceBadges(rowLabel: "Menn", at: t0) == ["CLI", "Dia"])

        var legacyBadges = AccountSnapshot(key: "acct:legacy-badges")
        legacyBadges.sawCLI = true
        legacyBadges.browsers = ["Chrome"]
        check("a row with no per-source times falls back to the old flags",
              legacyBadges.sourceBadges(rowLabel: "Menn", at: t0) == ["CLI", "Chrome"])

        var stamped = AccountSnapshot(key: "acct:stamped")
        stamped.absorb(IncomingReport(source: .cli, browser: nil,
                                      limits: [LimitID.fiveHour: reading(4, t0.addingTimeInterval(-22 * 3600), .cli)],
                                      receivedAt: t0))
        check("the badge is stamped with the reading, not with the delivery",
              stamped.sourceBadges(rowLabel: "x", at: t0).isEmpty)

        print("\n▸ Pace — spending a window faster than it can carry")
        let week: TimeInterval = 7 * 86_400
        func weekly(_ pct: Double, leftInWindow: TimeInterval, at when: Date) -> LimitReading {
            LimitReading(pct: pct, resetsAt: when.addingTimeInterval(leftInWindow),
                         observedAt: when, source: .ext, label: nil)
        }

        // The Seed card as it stood: a quarter into the week, over a quarter spent.
        if let p = weekly(27, leftInWindow: 5 * 86_400 + 8 * 3600, at: t0)
                     .pace(id: LimitID.sevenDay, at: t0) {
            check("elapsed is read from the reset time and the window length",
                  abs(p.elapsed - 144_000 / week) < 0.001)
            check("projected end of window", p.projected > 113 && p.projected < 114)
            check("and it is called short", p.level == .short)
            check("with the moment it runs out", (p.exhaustsIn ?? 0) > 0)
        } else { failed += 1; print("  ✗  a mid-window weekly limit produced no pace") }

        // Novem's: two days in, two thirds gone.
        if let p = weekly(66, leftInWindow: 5 * 86_400 + 6 * 3600, at: t0)
                     .pace(id: LimitID.sevenDay, at: t0) {
            check("a quarter of the week elapsed", abs(p.elapsed - 0.25) < 0.001)
            check("projects to more than double the window", p.projected > 263 && p.projected < 265)
            let hours = (p.exhaustsIn ?? 0) / 3600
            check("and runs out in about 21 hours", hours > 21.4 && hours < 21.8)
        } else { failed += 1; print("  ✗  an over-pace weekly limit produced no pace") }

        // Under pace: most of the window gone, less than half of it spent.
        if let p = weekly(30, leftInWindow: 5_580, at: t0).pace(id: LimitID.fiveHour, at: t0) {
            check("a window being spent slowly is on track", p.level == .onTrack)
            check("and names no end", p.exhaustsIn == nil)
        } else { failed += 1; print("  ✗  an under-pace session produced no pace") }

        check("the band around 100 does not flicker", [
            (89.0, Pace.Level.onTrack), (90.0, .tight), (110.0, .tight), (111.0, .short)
        ].allSatisfy { Pace(elapsed: 0.5, projected: $0.0, exhaustsIn: nil).level == $0.1 })
        // 62% used with 58% of the session gone: a 7% overshoot, not an alarm.
        check("a marginal overshoot stays inside the band",
              Pace(elapsed: 0.58, projected: 107, exhaustsIn: 3600).level == .tight)

        // A full window keeps its reset countdown instead of being told it runs out now.
        if let p = weekly(100, leftInWindow: 2 * 3600, at: t0).pace(id: LimitID.fiveHour, at: t0) {
            check("a window already spent predicts no end", p.exhaustsIn == nil)
        } else { failed += 1; print("  ✗  a full window produced no pace at all") }

        // Everything that has to answer "cannot say" rather than guess.
        check("a per-model cap has no reset time, so no pace",
              LimitReading(pct: 40, resetsAt: nil, observedAt: t0, source: .ext, label: "Fable")
                  .pace(id: "weekly:fable", at: t0) == nil)
        check("nor does a window that has already run out",
              weekly(40, leftInWindow: -60, at: t0).pace(id: LimitID.sevenDay, at: t0) == nil)
        // The 5-hour window starts on your first message, so its opening minutes are
        // always over pace and always meaningless.
        check("nor one that is 40 minutes old",
              LimitReading(pct: 5, resetsAt: t0.addingTimeInterval(4 * 3600 + 20 * 60),
                           observedAt: t0, source: .ext, label: nil)
                  .pace(id: LimitID.fiveHour, at: t0) == nil)
        check("but 46 minutes in it can be read",
              LimitReading(pct: 5, resetsAt: t0.addingTimeInterval(4 * 3600 + 14 * 60),
                           observedAt: t0, source: .ext, label: nil)
                  .pace(id: LimitID.fiveHour, at: t0) != nil)
        check("an unused window projects to nothing, not to a division by zero",
              weekly(0, leftInWindow: 3 * 86_400, at: t0)
                  .pace(id: LimitID.sevenDay, at: t0)?.projected == 0)

        print("\n▸ Theme — the same number must read the same in both surfaces")
        // The extension's badge and popup both break at 70 and 90. This panel breaking
        // at 80 and 95 meant 76% came up gold here and orange there.
        check("76% is the extension's orange, not gold", Theme.color(for: 76) == Theme.brand)
        check("70 is where that starts", Theme.color(for: 70) == Theme.brand)
        check("69 is still the step below", Theme.color(for: 69) == Theme.warning)
        check("90 is red, as it is in the badge", Theme.color(for: 90) == Theme.color(for: 100))
        check("89 is not", Theme.color(for: 89) == Theme.brand)
        check("and the panel keeps its own half-way step", Theme.color(for: 49) != Theme.warning)

        print("\n▸ Matching — a report that cannot name its account")
        // What actually happened: claude.ai stopped answering the extension's identity
        // lookup, the lookup overwrote the cached uuid with an org, and three accounts
        // that already had rows came back as three more — named after the tail of an
        // organization uuid, holding the same numbers, and impossible to merge away.
        func anon(org: String, browser: String) -> IncomingReport {
            IncomingReport(source: .ext, browser: browser, orgId: org,
                           limits: [LimitID.fiveHour: reading(3, t0)], receivedAt: t0)
        }
        func named(_ key: String, uuid: String?, org: String, browsers: [String]) -> AccountSnapshot {
            var a = AccountSnapshot(key: key)
            a.accountUuid = uuid
            a.orgId = org
            a.browsers = browsers
            return a
        }

        // Two accounts, one Team organization, one Chrome profile each — the case that
        // stops orgId from being an identity, and the reason the profile name is needed.
        let team = [named("acct:a", uuid: "u-a", org: "org-7", browsers: ["7Sol"]),
                    named("acct:b", uuid: "u-b", org: "org-7", browsers: ["Novem"])]
        check("an anonymous report goes to the row its profile already feeds",
              AccountMatch.index(of: anon(org: "org-7", browser: "7Sol"), in: team) == 0)
        check("and not to the other account in the same organization",
              AccountMatch.index(of: anon(org: "org-7", browser: "Novem"), in: team) == 1)
        check("a profile nobody has seen still gets a row of its own",
              AccountMatch.index(of: anon(org: "org-7", browser: "Raven"), in: team) == nil)
        check("a profile of the same name in another organization is not the same account",
              AccountMatch.index(of: anon(org: "org-9", browser: "7Sol"), in: team) == nil)

        // The state as it stood: the named row and the leftover both carry the profile.
        let leftover = team + [named("org:org-7", uuid: nil, org: "org-7", browsers: ["7Sol", "Novem"])]
        check("a row that knows whose account it is wins over one that does not",
              AccountMatch.index(of: anon(org: "org-7", browser: "7Sol"), in: leftover) == 0)
        check("so the leftover stops being fed and is retired",
              AccountMatch.redundantAnonymousKeys(in: leftover) == ["org:org-7"])
        check("a report that names the account still matches on the uuid, not the profile",
              AccountMatch.index(of: IncomingReport(source: .ext, browser: "Novem", accountUuid: "u-a",
                                                    limits: [:], receivedAt: t0), in: leftover) == 0)

        // The proviso: an organization can hold an account nothing has ever identified.
        let unclaimed = [named("acct:a", uuid: "u-a", org: "org-7", browsers: ["7Sol"]),
                         named("org:org-7", uuid: nil, org: "org-7", browsers: ["7Sol", "Raven"])]
        check("a row with a source no named row covers is kept",
              AccountMatch.redundantAnonymousKeys(in: unclaimed).isEmpty)
        check("and keeps receiving, because two rows claim its profile",
              AccountMatch.index(of: anon(org: "org-7", browser: "7Sol"), in: unclaimed) == 0)
        check("nothing is retired when no row is named at all",
              AccountMatch.redundantAnonymousKeys(in: [named("org:org-7", uuid: nil, org: "org-7",
                                                             browsers: ["7Sol"])]).isEmpty)
        check("a CLI-only row carries no browser and is never a candidate",
              AccountMatch.redundantAnonymousKeys(in: [
                  named("acct:a", uuid: "u-a", org: "org-7", browsers: ["7Sol"]),
                  named("org:org-7", uuid: nil, org: "org-7", browsers: [])
              ]).isEmpty)

        print("\n▸ Persistence — a file from an earlier build must survive")
        // `AppSettings.load()` answers a failed decode with defaults, and Swift's
        // synthesized `Decodable` ignores property defaults: one new stored field in
        // `FreshnessThresholds` would take every label the user has typed with it.
        let earlierSettings = """
        {"hidden":[],"labels":{"acct:1":"Menn"},"order":[],"port":47821,
         "readCLIStatusline":true,"readStatsCache":true,"showPercentInMenuBar":true,
         "thresholds":{"aging":1800,"fresh":180,"stale":10800}}
        """
        if let s = try? JSONIO.decoder.decode(AppSettings.self, from: Data(earlierSettings.utf8)) {
            check("settings still decode", s.labels["acct:1"] == "Menn")
            check("and keep the chosen port", s.port == 47821)
            check("a field added since takes its default", s.readQuotaAPI == false)
            check("Team model caps stay hidden on an older file", s.showTeamModelCaps == false)
        } else { failed += 1; print("  ✗  a settings file from an earlier build no longer decodes") }

        // The rule the custom decoder buys: one unreadable field costs that field, not
        // the file. A `thresholds` that gains a stored property in some later build must
        // not take the labels with it.
        let futureSettings = """
        {"labels":{"acct:1":"Menn"},"port":47999,"readQuotaAPI":true,
         "thresholds":{"aging":"not-a-number"}}
        """
        if let s = try? JSONIO.decoder.decode(AppSettings.self, from: Data(futureSettings.utf8)) {
            check("a malformed nested block costs only itself", s.labels["acct:1"] == "Menn")
            check("neighbouring fields survive it", s.port == 47999 && s.readQuotaAPI)
            check("and it falls back to its own defaults",
                  s.thresholds == FreshnessThresholds())
        } else { failed += 1; print("  ✗  a settings file with one bad field threw the lot away") }

        // Round-trip every field, so the next one added to the struct but forgotten in
        // `CodingKeys` is caught here rather than by a user losing their labels.
        var full = AppSettings()
        full.port = 47999
        full.labels = ["acct:1": "Menn"]
        full.hidden = ["acct:2"]
        full.order = ["acct:1", "acct:2"]
        full.thresholds = FreshnessThresholds(fresh: 11, aging: 22, stale: 33)
        full.readCLIStatusline = false
        full.readStatsCache = false
        full.readQuotaAPI = true
        full.showTeamModelCaps = true
        if let d = try? JSONIO.encoder.encode(full),
           let back = try? JSONIO.decoder.decode(AppSettings.self, from: d) {
            check("every settings field survives a round trip", back == full)
        } else { failed += 1; print("  ✗  settings did not round-trip") }

        let earlierAccount = """
        {"key":"acct:1","browsers":["Menn"],"sawCLI":true,"firstSeen":1787600000,
         "limits":{"five_hour":{"pct":5,"observedAt":1787700000,"source":"extension"}}}
        """
        if let a = try? JSONIO.decoder.decode(AccountSnapshot.self, from: Data(earlierAccount.utf8)) {
            check("a state file with no contact field decodes", a.lastContactAt == nil)
            check("nor plan statements", a.planStatements == nil)
            check("and its readings come back", a.limits[LimitID.fiveHour]?.pct == 5)
        } else { failed += 1; print("  ✗  a state file from an earlier build no longer decodes") }

        print("\n▸ Fmt — a silence is worded as one")
        check("minutes", Fmt.gap(41 * 60) == "41 นาที")
        check("hours", Fmt.gap(2 * 3600 + 300) == "2 ชม.")
        check("days", Fmt.gap(3 * 86400) == "3 วัน")
        check("not phrased as an age", Fmt.quiet(41 * 60) == "เงียบ 41 นาที")

        // MARK: - The quota API source

        print("\n▸ CLICredential — the keychain item, without a keychain")
        let credential = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-xxx","refreshToken":"sk-ant-ort01-yyy",
         "expiresAt":1788280623435,"scopes":["user:inference"],"subscriptionType":"team"}}
        """
        if let t = CLICredential.parse(Data(credential.utf8)) {
            check("the access token is picked out", t.value == "sk-ant-oat01-xxx")
            check("a millisecond expiry is read as seconds",
                  t.expiresAt.map { abs($0.timeIntervalSince1970 - 1_788_280_623.435) < 1 } ?? false)
            check("live at a moment before it", !t.isExpired(at: Date(timeIntervalSince1970: 1_788_270_000)))
            check("expired at a moment after it", t.isExpired(at: Date(timeIntervalSince1970: 1_788_290_000)))
            // Treated as expired slightly early on purpose: a token that dies in flight
            // shows up as a network failure, which is a worse thing to put on screen.
            check("and expired just before it, not exactly on it",
                  t.isExpired(at: Date(timeIntervalSince1970: 1_788_280_600)))
        } else { failed += 1; print("  ✗  a well-formed credential did not parse") }

        check("an item with no OAuth block is refused",
              CLICredential.parse(Data(#"{"other":1}"#.utf8)) == nil)
        check("an empty access token is refused",
              CLICredential.parse(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
        check("a credential with no expiry never reads as expired",
              CLICredential.parse(Data(#"{"claudeAiOauth":{"accessToken":"x"}}"#.utf8))?
                  .isExpired(at: Date(timeIntervalSince1970: 4_000_000_000)) == false)

        print("\n▸ QuotaAPI — slugs must match bridge.js exactly")
        // Both sides write into one key space; a mismatch draws one model as two rows.
        check("a plain name", QuotaAPI.slug("Opus") == "opus")
        check("a spaced name", QuotaAPI.slug("Claude Design") == "claude-design")
        check("runs of punctuation collapse", QuotaAPI.slug("Opus  4.5 (1M)") == "opus-4-5-1m")
        check("leading and trailing separators are trimmed", QuotaAPI.slug(" -Fable- ") == "fable")
        check("capped at 32 characters", QuotaAPI.slug(String(repeating: "a", count: 40)).count == 32)
        check("a name with nothing usable slugs to empty", QuotaAPI.slug("…") == "")

        print("\n▸ QuotaAPI — /api/oauth/profile")
        let profile = """
        {"account":{"uuid":"acc-1","full_name":"A B","email":"Me@Example.com"},
         "organization":{"uuid":"org-1","name":"SeedWebs","rate_limit_tier":"default_claude_max_5x"},
         "application":{"slug":"claude-code"}}
        """
        if let id = QuotaAPI.identity(fromProfile: Data(profile.utf8)) {
            check("the account is named", id.accountUuid == "acc-1")
            check("the email is lowercased, as every other path stores it", id.email == "me@example.com")
            check("the organization rides along", id.orgId == "org-1" && id.orgName == "SeedWebs")
            // This endpoint words a Team seat as a Max tier, so carrying it would badge a
            // Team card as Max wherever the extension is not reporting it.
            check("the plan is deliberately not carried", id.plan == nil)
        } else { failed += 1; print("  ✗  a well-formed profile did not parse") }

        check("the tier is still available for display",
              QuotaAPI.tier(fromProfile: Data(profile.utf8)) == "default_claude_max_5x")
        check("a profile that names nobody is not an identity",
              QuotaAPI.identity(fromProfile: Data(#"{"account":{},"organization":{"uuid":"o"}}"#.utf8)) == nil)

        print("\n▸ QuotaAPI — /api/oauth/usage")
        // Trimmed from a real response, nulls and all: the retired `seven_day_*` fields
        // still arrive, and `extra_usage` carries nulls rather than zeros while it is off.
        let usage = """
        {"five_hour":{"utilization":69.0,"resets_at":"2026-09-01T11:30:00.236607+00:00"},
         "seven_day":{"utilization":9.0,"resets_at":"2026-09-07T17:00:00.236628+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":null,"nimbus_quill":{"utilization":0.0},
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"currency":"USD"},
         "limits":[
           {"kind":"session","group":"session","percent":69,"resets_at":"2026-09-01T11:30:00.236607+00:00"},
           {"kind":"weekly_all","group":"weekly","percent":9},
           {"kind":"weekly_scoped","group":"weekly","percent":35,
            "resets_at":"2026-09-07T17:00:00+00:00","scope":{"model":{"display_name":"Fable"}}},
           {"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":"Claude Design"}}},
           {"kind":"weekly_scoped","percent":1,"scope":{}}
         ]}
        """
        let observed = Date(timeIntervalSince1970: 1_788_260_000)
        let read = QuotaAPI.reading(fromUsage: Data(usage.utf8), observedAt: observed)
        check("the session ceiling keeps its fractional percentage",
              read.limits[LimitID.fiveHour]?.pct == 69)
        check("its ISO reset parses",
              read.limits[LimitID.fiveHour]?.resetsAt != nil)
        check("the weekly ceiling comes through", read.limits[LimitID.sevenDay]?.pct == 9)
        check("a per-model cap is keyed by slug", read.limits["weekly:fable"]?.pct == 35)
        check("and carries the name to display", read.limits["weekly:fable"]?.label == "Fable")
        check("a multi-word model name survives slugging",
              read.limits["weekly:claude-design"]?.label == "Claude Design")
        check("a scoped entry naming no model is dropped", read.limits.count == 4)
        check("the retired seven_day_* nulls invent nothing",
              read.limits["weekly:opus"] == nil && read.limits["weekly:sonnet"] == nil)
        // A top-level key we have never heard of is not a limit just because it is shaped
        // like one; only `limits[]` may add rows.
        check("an unknown top-level block is ignored", read.limits["nimbus_quill"] == nil)
        check("every reading is stamped with the observation time",
              read.limits.values.allSatisfy { $0.observedAt == observed })
        check("and attributed to the API", read.limits.values.allSatisfy { $0.source == .api })
        check("extra usage reads as off", read.extra?.enabled == false)
        check("its nulls become zero rather than dropping the block",
              read.extra?.used == 0 && read.extra?.limit == 0)
        check("its currency survives", read.extra?.currency == "USD")

        check("a body that is not JSON yields nothing",
              QuotaAPI.reading(fromUsage: Data("nope".utf8), observedAt: observed).limits.isEmpty)
        check("a body with no limit we understand yields nothing",
              QuotaAPI.reading(fromUsage: Data(#"{"spend":{"percent":0}}"#.utf8), observedAt: observed)
                  .limits.isEmpty)

        print("\n▸ Model caps retire per source, not across sources")
        // The extension and the API both list caps but poll on their own clocks, so one
        // dropping Opus must not erase the other's live Opus reading.
        func capped(_ source: ReadingSource, _ at: Date) -> LimitReading {
            LimitReading(pct: 20, resetsAt: nil, observedAt: at, source: source, label: "Opus")
        }
        let long = Date(timeIntervalSince1970: 1_788_000_000)   // older than the retirement age
        var row = AccountSnapshot(key: "acct:1")
        row.limits["weekly:opus"] = capped(.ext, long)
        row.absorb(IncomingReport(source: .api, browser: nil, accountUuid: "1", email: nil,
                                  orgId: nil, orgName: nil, plan: nil,
                                  limits: [LimitID.fiveHour: LimitReading(pct: 1, resetsAt: nil,
                                                                          observedAt: observed,
                                                                          source: .api, label: nil)],
                                  extra: nil, receivedAt: observed))
        check("an API report leaves the extension's cap alone", row.limits["weekly:opus"] != nil)

        row.limits["weekly:opus"] = capped(.api, long)
        row.absorb(IncomingReport(source: .ext, browser: "Menn", accountUuid: "1", email: nil,
                                  orgId: nil, orgName: nil, plan: nil,
                                  limits: [LimitID.fiveHour: LimitReading(pct: 1, resetsAt: nil,
                                                                          observedAt: observed,
                                                                          source: .ext, label: nil)],
                                  extra: nil, receivedAt: observed))
        check("an extension report leaves the API's cap alone", row.limits["weekly:opus"] != nil)

        row.limits["weekly:opus"] = capped(.api, long)
        row.absorb(IncomingReport(source: .api, browser: nil, accountUuid: "1", email: nil,
                                  orgId: nil, orgName: nil, plan: nil,
                                  limits: [LimitID.fiveHour: LimitReading(pct: 1, resetsAt: nil,
                                                                          observedAt: observed,
                                                                          source: .api, label: nil)],
                                  extra: nil, receivedAt: observed))
        check("but it does retire its own stale cap", row.limits["weekly:opus"] == nil)
        check("the API earns a badge of its own",
              row.sourceBadges(rowLabel: "Menn", at: observed).contains("API"))

        print("\n▸ A profile identity settles the status line outright")
        // The case the file-based rule refuses: `oauthAccount` names one account, the
        // cached block another, and the seven-day windows do not line up — so nothing in
        // the file ties either account to these numbers.
        let statusline = """
        {"rate_limits":{"five_hour":{"used_percentage":69,"resets_at":1788262200},
                        "seven_day":{"used_percentage":9,"resets_at":1788800400}}}
        """
        let ambiguous = CLIIdentity(
            accountUuid: "from-claude-json", email: "stale@example.com",
            orgId: "org-stale", orgName: "Stale Org", plan: "default_claude_max_20x",
            credential: CLIIdentity.Credential(accountUuid: "from-token",
                                               sevenDayResetsAt: Date(timeIntervalSince1970: 1)))
        check("with only the file to go on, the reading is dropped rather than guessed at",
              Ingest.cliReport(statuslineJSON: Data(statusline.utf8),
                               identity: ambiguous, observedAt: observed) == nil)

        // What `/api/oauth/profile` hands back: the credential's own account, with no
        // cached block to be weighed against, so it is taken at its word.
        let fromProfile = CLIIdentity(accountUuid: "from-token", email: "real@example.com",
                                      orgId: "org-real", orgName: "Real Org", plan: nil)
        if let r = Ingest.cliReport(statuslineJSON: Data(statusline.utf8),
                                    identity: fromProfile, observedAt: observed) {
            check("the same reading now lands, on the token's account",
                  r.preferredKey == "acct:from-token")
            check("with the profile's email", r.email == "real@example.com")
            check("and its organization", r.orgId == "org-real" && r.orgName == "Real Org")
            check("carrying the numbers untouched", r.limits[LimitID.fiveHour]?.pct == 69)
            check("as a CLI reading, not an API one", r.source == .cli)
        } else { failed += 1; print("  ✗  a profile identity did not produce a report") }

        print("\n▸ An empty panel offers the route this machine can actually take")
        func hint(login: Bool, on: Bool, _ st: APISource.Status = .off) -> String? {
            PanelView.EmptyStateHint.cli(sawClaudeCodeLogin: login, apiEnabled: on, apiStatus: st)
        }
        // The case this exists for: Claude Code is here, no browser profile is reporting,
        // and the panel used to name only the extension — which reads as "not for you".
        check("Claude Code signed in and the source off — it is offered",
              hint(login: true, on: false)?.contains("quota API") == true)
        check("no Claude Code on this machine — nothing is offered",
              hint(login: false, on: false) == nil)
        check("a switch already on is not offered again",
              hint(login: true, on: true, .ok(account: "a", org: nil, tier: nil, at: Date())) == nil)
        check("nor while its first answer is still coming", hint(login: true, on: true, .waiting) == nil)
        // Expired is Claude Code's to fix by running; these are the user's to clear, and
        // an empty panel with no route to the reason it is empty is a dead end.
        check("an expired token needs no instruction here", hint(login: true, on: true, .expired) == nil)
        check("a declined keychain points at settings",
              hint(login: true, on: true, .denied)?.contains("ตั้งค่า") == true)
        check("so does a missing credential", hint(login: true, on: true, .noCredential) != nil)
        check("and an outright failure", hint(login: true, on: true, .failed("HTTP 500")) != nil)

        print("\n\(passed) passed, \(failed) failed\n")
        return failed == 0 ? 0 : 1
    }

    private static func diffLineCount(_ a: String, _ b: String) -> Int {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        guard x.count == y.count else { return max(x.count, y.count) }
        return zip(x, y).filter { $0 != $1 }.count
    }
}
