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

        print("\n\(passed) passed, \(failed) failed\n")
        return failed == 0 ? 0 : 1
    }

    private static func diffLineCount(_ a: String, _ b: String) -> Int {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        guard x.count == y.count else { return max(x.count, y.count) }
        return zip(x, y).filter { $0 != $1 }.count
    }
}
