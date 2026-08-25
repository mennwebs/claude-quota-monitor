import Foundation

/// A few flags handled before the UI exists.
///
/// The statusline shim edits `~/.claude/settings.json`, which is a file people hand-edit
/// and care about. Being able to install, inspect and undo it from a terminal — rather
/// than only from a button — makes that change auditable and scriptable.
private func runCommand(_ argument: String) -> Int32 {
    switch argument {
    case "--statusline-status":
        switch StatuslineInstaller.status() {
        case .installed(let wrapping):
            print("installed" + (wrapping.map { " (wrapping \($0))" } ?? " (no previous status line)"))
        case .foreign(let command):
            print("not installed (current status line: \(command))")
        case .notConfigured:
            print("not installed (no status line configured)")
        }
        return 0

    case "--install-statusline":
        do {
            let result = try StatuslineInstaller.install()
            print("ok: \(result)")
            print("shim: \(StatuslineInstaller.shimPath.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
            return 1
        }

    case "--uninstall-statusline":
        do {
            print("ok: \(try StatuslineInstaller.uninstall())")
            return 0
        } catch {
            FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8))
            return 1
        }

    case "--print-token":
        print(TokenStore.loadOrCreate())
        return 0

    case "--print-port":
        print(AppSettings.load().port)
        return 0

    case "--selftest":
        return SelfTest.run()

    default:
        print("""
        Claude Quota — menu bar quota monitor

          --install-statusline     wrap the configured Claude Code status line so it also
                                   writes its rate_limits to \(Paths.cliDump.path)
          --uninstall-statusline   restore the previous status line command
          --statusline-status      report whether the shim is installed
          --print-token            print the loopback token for the extension's options
          --print-port             print the port the app listens on
          --selftest               run the settings.json patcher checks

        With no arguments the menu bar app starts.
        """)
        return argument == "--help" ? 0 : 2
    }
}

let flags = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") }
if let first = flags.first {
    exit(runCommand(first))
}

ClaudeQuotaApp.main()
