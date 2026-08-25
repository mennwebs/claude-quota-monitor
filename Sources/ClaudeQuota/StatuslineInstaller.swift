import Foundation

/// Installs the statusline shim.
///
/// Claude Code passes the live `rate_limits` block to whatever command is configured as
/// the status line, on every render. That makes it the freshest quota source on the
/// machine — and the only local one, since hooks do not carry rate limits.
///
/// Rather than patch the user's own status line script (which can be anything), the shim
/// wraps it: tee the JSON to a file, then hand the same JSON to the original command
/// unchanged. Nothing about the visible status line changes, and uninstalling is a
/// one-key restore of `statusLine.command`.
enum StatuslineInstaller {
    enum Status: Equatable {
        case notConfigured              // no statusLine in ~/.claude/settings.json
        case installed(wrapping: String?)
        case foreign(String)            // some other command is configured
    }

    static var shimPath: URL { Paths.home.appendingPathComponent(".claude/cqm-statusline.sh") }
    static var claudeSettings: URL { Paths.home.appendingPathComponent(".claude/settings.json") }

    static func status() -> Status {
        guard let root = readSettings(), let sl = root["statusLine"] as? [String: Any],
              let command = sl["command"] as? String, !command.isEmpty
        else { return .notConfigured }

        if command == shimPath.path || command.contains("cqm-statusline.sh") {
            return .installed(wrapping: wrappedCommand())
        }
        return .foreign(command)
    }

    /// The original command, recovered from the shim itself so uninstall works even
    /// across app reinstalls.
    static func wrappedCommand() -> String? {
        guard let text = try? String(contentsOf: shimPath, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") where line.hasPrefix("REAL=") {
            let raw = String(line.dropFirst("REAL=".count))
            return unquote(raw).isEmpty ? nil : unquote(raw)
        }
        return nil
    }

    @discardableResult
    static func install() throws -> Status {
        let existing: String? = {
            if case .foreign(let c) = status() { return c }
            if case .installed(let w) = status() { return w }
            return nil
        }()

        // The shim only writes when its target directory already exists (creating it
        // would mean a fork on every render). Make sure it does, so installing the shim
        // before ever opening the app still works.
        _ = Paths.appSupport
        try writeShim(wrapping: existing)

        try backupSettings()
        try patchSettings { try JSONTextPatch.setStatusLineCommand(in: $0, to: shimPath.path) }
        return status()
    }

    @discardableResult
    static func uninstall() throws -> Status {
        let original = wrappedCommand()
        try backupSettings()
        try patchSettings { text in
            // Restore what was there before; if there was nothing, take the whole
            // member back out rather than leave a status line pointing at a deleted file.
            if let original, !original.isEmpty {
                return try JSONTextPatch.setStatusLineCommand(in: text, to: original)
            }
            return try JSONTextPatch.removeStatusLine(in: text)
        }
        try? FileManager.default.removeItem(at: shimPath)
        return status()
    }

    // MARK: - Shim script

    private static func writeShim(wrapping original: String?) throws {
        let real = original.map(shellSingleQuote) ?? "''"
        let script = """
        #!/usr/bin/env bash
        # Claude Quota Monitor — statusline shim (generated; safe to delete)
        #
        # Claude Code feeds the status line a JSON blob on stdin that includes the live
        # rate_limits block. Copying it to a file is the cheapest possible way to get this
        # account's quota to the menu bar app: no API call, no polling, no extra process.
        #
        # This runs on every render, so it must not fork. Both the directory test and the
        # write below are shell builtins.

        input=$(cat)

        CQM_OUT="$HOME/Library/Application Support/ClaudeQuotaMonitor/cli.json"
        [ -d "${CQM_OUT%/*}" ] && printf '%s' "$input" > "$CQM_OUT"

        # The status line the user had configured before the shim was installed.
        REAL=\(real)

        if [ -n "$REAL" ]; then
          printf '%s' "$input" | eval "$REAL"
        elif command -v jq >/dev/null 2>&1; then
          # No status line was configured, so print a minimal one rather than leaving
          # an empty row where Claude Code's footer hints used to be.
          printf '%s' "$input" | jq -r '
            "\\(.model.display_name // "?")  ctx \\((.context_window.used_percentage // 0) | floor)%  " +
            "5h \\((.rate_limits.five_hour.used_percentage // 0) | floor)%"'
        fi
        """
        try FileManager.default.createDirectory(at: shimPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(script.utf8).write(to: shimPath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPath.path)
    }

    // MARK: - ~/.claude/settings.json

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeSettings),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root
    }

    /// Claude Code's settings file is hand-edited and holds unrelated configuration.
    /// Keep a dated copy before every write.
    private static func backupSettings() throws {
        guard FileManager.default.fileExists(atPath: claudeSettings.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = claudeSettings.deletingLastPathComponent()
            .appendingPathComponent("settings.json.cqm-backup.\(stamp)")
        try? FileManager.default.copyItem(at: claudeSettings, to: backup)
        pruneBackups()
    }

    /// Keep a few, not one per install. Anything older is noise in a directory the
    /// user browses.
    private static func pruneBackups(keeping keep: Int = 5) {
        let dir = claudeSettings.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let backups = names
            .filter { $0.hasPrefix("settings.json.cqm-backup.") }
            .sorted()                      // the suffix is a zero-padded-by-magnitude epoch
        for name in backups.dropLast(keep) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Reads the file as text, hands it to `edit`, checks the result still parses,
    /// and only then writes. A patch that produced invalid JSON would take Claude Code
    /// down with it, so it is never written.
    private static func patchSettings(_ edit: (String) throws -> String) throws {
        let existing = (try? String(contentsOf: claudeSettings, encoding: .utf8)) ?? ""
        let text = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{\n}\n" : existing

        let patched = try edit(text)
        guard let data = patched.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { throw JSONTextPatch.PatchError.unparsable("ผลลัพธ์ไม่ใช่ JSON ที่ถูกต้อง") }

        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONIO.atomicWrite(data, to: claudeSettings, mode: 0o644)
    }

    // MARK: - Quoting

    private static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("'"), t.hasSuffix("'"), t.count >= 2 else { return t }
        t = String(t.dropFirst().dropLast())
        return t.replacingOccurrences(of: "'\\''", with: "'")
    }
}
