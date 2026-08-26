import Foundation

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

        print("\n▸ Source badges")
        var badged = AccountSnapshot(key: "acct:badges")
        badged.browsers = ["Chrome", "Seed"]
        check("a badge that only repeats the row name goes",
              badged.sourceBadges(rowLabel: "Seed") == ["Chrome"])
        check("case and padding do not save it",
              badged.sourceBadges(rowLabel: "  seed ") == ["Chrome"])
        check("one that says something new is kept",
              badged.sourceBadges(rowLabel: "Menn") == ["Chrome", "Seed"])
        var solo = AccountSnapshot(key: "acct:solo")
        solo.browsers = ["Novem"]
        check("and the only badge may go entirely", solo.sourceBadges(rowLabel: "Novem").isEmpty)

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
        } else { failed += 1; print("  ✗  a settings file from an earlier build no longer decodes") }

        let earlierAccount = """
        {"key":"acct:1","browsers":["Menn"],"sawCLI":true,"firstSeen":1787600000,
         "limits":{"five_hour":{"pct":5,"observedAt":1787700000,"source":"extension"}}}
        """
        if let a = try? JSONIO.decoder.decode(AccountSnapshot.self, from: Data(earlierAccount.utf8)) {
            check("a state file with no contact field decodes", a.lastContactAt == nil)
            check("and its readings come back", a.limits[LimitID.fiveHour]?.pct == 5)
        } else { failed += 1; print("  ✗  a state file from an earlier build no longer decodes") }

        print("\n▸ Fmt — a silence is worded as one")
        check("minutes", Fmt.gap(41 * 60) == "41 นาที")
        check("hours", Fmt.gap(2 * 3600 + 300) == "2 ชม.")
        check("days", Fmt.gap(3 * 86400) == "3 วัน")
        check("not phrased as an age", Fmt.quiet(41 * 60) == "เงียบ 41 นาที")

        print("\n\(passed) passed, \(failed) failed\n")
        return failed == 0 ? 0 : 1
    }

    private static func diffLineCount(_ a: String, _ b: String) -> Int {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        guard x.count == y.count else { return max(x.count, y.count) }
        return zip(x, y).filter { $0 != $1 }.count
    }
}
