import Foundation

/// Edits one value inside a JSON file without reserializing it.
///
/// `~/.claude/settings.json` is hand-written: key order carries meaning to whoever
/// wrote it, and comments-by-formatting are real. Round-tripping it through
/// `JSONSerialization` alphabetizes every key and rewrites every separator — a diff
/// full of changes nobody asked for. So the statusLine command is patched as text,
/// leaving every other byte alone.
enum JSONTextPatch {
    enum PatchError: LocalizedError {
        case unparsable(String)

        var errorDescription: String? {
            switch self {
            case .unparsable(let why):
                return "แก้ settings.json แบบไม่กระทบส่วนอื่นไม่ได้ (\(why)) — กรุณาแก้ statusLine.command เองเพื่อความปลอดภัย"
            }
        }
    }

    /// Sets `statusLine.command`, creating `statusLine` if it is missing.
    static func setStatusLineCommand(in text: String, to command: String) throws -> String {
        let chars = Array(text)
        guard let rootOpen = firstIndex(of: "{", in: chars) else {
            throw PatchError.unparsable("ไม่พบ object ระดับบนสุด")
        }

        guard let statusLine = findMember("statusLine", in: chars, objectOpenAt: rootOpen) else {
            let insert = "\n  \"statusLine\": { \"type\": \"command\", \"command\": \(quote(command)) },"
            return String(chars[..<(rootOpen + 1)]) + insert + String(chars[(rootOpen + 1)...])
        }
        guard chars[statusLine.valueStart] == "{" else {
            throw PatchError.unparsable("statusLine ไม่ใช่ object")
        }

        if let commandMember = findMember("command", in: chars, objectOpenAt: statusLine.valueStart) {
            return String(chars[..<commandMember.valueStart])
                + quote(command)
                + String(chars[(commandMember.valueEnd + 1)...])
        }

        let insert = " \"command\": \(quote(command)),"
        return String(chars[...statusLine.valueStart]) + insert + String(chars[(statusLine.valueStart + 1)...])
    }

    /// Removes the whole `statusLine` member, along with the comma that held it in place.
    static func removeStatusLine(in text: String) throws -> String {
        let chars = Array(text)
        guard let rootOpen = firstIndex(of: "{", in: chars) else {
            throw PatchError.unparsable("ไม่พบ object ระดับบนสุด")
        }
        guard let member = findMember("statusLine", in: chars, objectOpenAt: rootOpen) else { return text }

        var start = member.keyStart
        var end = member.valueEnd + 1

        // Take the separating comma with it: the one after when another member follows,
        // otherwise the one before — leaving either behind produces invalid JSON.
        var after = end
        while after < chars.count, chars[after].isWhitespace { after += 1 }
        if after < chars.count, chars[after] == "," {
            end = after + 1
        } else {
            var before = start - 1
            while before >= 0, chars[before].isWhitespace { before -= 1 }
            if before >= 0, chars[before] == "," { start = before }
        }

        // Swallow the now-blank line so removal does not leave a gap.
        while start > 0, chars[start - 1] == " " || chars[start - 1] == "\t" { start -= 1 }
        if start > 0, chars[start - 1] == "\n", end < chars.count, chars[end] == "\n" { start -= 1 }

        return String(chars[..<start]) + String(chars[end...])
    }

    // MARK: - Scanning

    private struct Member {
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int   // inclusive
    }

    private static func firstIndex(of character: Character, in chars: [Character]) -> Int? {
        chars.firstIndex(of: character)
    }

    /// Finds a direct member of the object that opens at `objectOpenAt`. Nested objects
    /// are skipped wholesale, so a `"command"` key deeper in the tree cannot be mistaken
    /// for this object's own.
    private static func findMember(_ name: String, in chars: [Character], objectOpenAt: Int) -> Member? {
        var i = objectOpenAt + 1
        var depth = 0

        while i < chars.count {
            let c = chars[i]

            if c == "\"" {
                let keyStart = i
                guard let keyEnd = endOfString(in: chars, from: i) else { return nil }
                if depth == 0, String(chars[(keyStart + 1)..<keyEnd]) == name {
                    var j = keyEnd + 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    guard j < chars.count, chars[j] == ":" else { i = keyEnd + 1; continue }
                    j += 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    guard j < chars.count, let valueEnd = endOfValue(in: chars, from: j) else { return nil }
                    return Member(keyStart: keyStart, valueStart: j, valueEnd: valueEnd)
                }
                i = keyEnd + 1
                continue
            }

            if c == "{" || c == "[" { depth += 1 }
            if c == "}" || c == "]" {
                if depth == 0 { return nil }   // end of our object
                depth -= 1
            }
            i += 1
        }
        return nil
    }

    /// Index of the closing quote of the string starting at `from`.
    private static func endOfString(in chars: [Character], from: Int) -> Int? {
        var i = from + 1
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "\"" { return i }
            i += 1
        }
        return nil
    }

    /// Last index (inclusive) of the value starting at `from`.
    private static func endOfValue(in chars: [Character], from: Int) -> Int? {
        switch chars[from] {
        case "\"":
            return endOfString(in: chars, from: from)
        case "{", "[":
            let close: Character = chars[from] == "{" ? "}" : "]"
            var depth = 0
            var i = from
            while i < chars.count {
                if chars[i] == "\"" {
                    guard let e = endOfString(in: chars, from: i) else { return nil }
                    i = e + 1
                    continue
                }
                if chars[i] == chars[from] { depth += 1 }
                if chars[i] == close {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i += 1
            }
            return nil
        default:
            var i = from
            while i < chars.count, chars[i] != ",", chars[i] != "}", chars[i] != "]" { i += 1 }
            var end = i - 1
            while end > from, chars[end].isWhitespace { end -= 1 }
            return end
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }
}
