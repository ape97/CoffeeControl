import Foundation

/// One-time sudo rule so Coffee Control may run exactly these `pmset` calls without a password – and no
/// others. Its own file `/etc/sudoers.d/coffeecontrol` (root:wheel 0440), installed and removed via the
/// macOS password dialog; before installing, `visudo` checks the syntax (a broken rule would lock sudo entirely).
/// No background service, no dependency on the user's shell configuration.
enum SleepHelper {
    static let sudoersPath = "/etc/sudoers.d/coffeecontrol"
    static let pmsetPath = "/usr/bin/pmset"

    /// All permitted calls; the same list generates the rule and checks every call.
    static let allowed: [[String]] = [["-a", "disablesleep", "1"], ["-a", "disablesleep", "0"]]
        + ["-c", "-b"].flatMap { source in (0...2).map { [source, "powermode", String($0)] } }

    /// Short name of the user; only harmless characters, otherwise no rule.
    static var userName: String? {
        let name = NSUserName()
        return name.range(of: "^[a-z0-9_.-]+$", options: .regularExpression) != nil ? name : nil
    }

    static func sudoersLines(user: String) -> [String] {
        ["# Coffee Control: sleep and power mode without a password",
         "\(user) ALL = (root) NOPASSWD: " + allowed.map { ([pmsetPath] + $0).joined(separator: " ") }.joined(separator: ", ")]
    }

    /// Shell command (runs as root): write to a temp file, validate, set permissions, only then move into place.
    static func installCommand(user: String) -> String {
        let lines = sudoersLines(user: user).map(quoted).joined(separator: " ")
        return "t=$(/usr/bin/mktemp /tmp/coffeecontrol.XXXXXX) || exit 1; "
            + "printf '%s\\n' \(lines) > \"$t\" && /usr/sbin/visudo -cf \"$t\" && /usr/sbin/chown root:wheel \"$t\" "
            + "&& /bin/chmod 0440 \"$t\" && /bin/mv -f \"$t\" \(quoted(sudoersPath)); s=$?; /bin/rm -f \"$t\"; exit $s"
    }

    static var removeCommand: String { "/bin/rm -f \(quoted(sudoersPath))" }

    /// `sudo -n pmset …`; only calls from `allowed`. Success = exit status 0 (without the rule, sudo fails immediately).
    static func pmset(_ arguments: [String]) -> Bool {
        guard allowed.contains(arguments) else { return false }
        return run("/usr/bin/sudo", ["-n", pmsetPath] + arguments).status == 0
    }

    /// Display off immediately (`pmset displaysleepnow`, needs no root). Only when closed with the
    /// display lit, at most every 20 s (`KeepAwake.displayRetry`).
    static func sleepDisplay() {
        _ = run(pmsetPath, ["displaysleepnow"])
    }

    /// Sleep immediately (`pmset sleepnow`, needs no root) – like "Sleep" in the Apple menu, overrides all assertions
    /// except `disablesleep`. Only in force-sleep mode: closed at most every 30 s, open once per idle period.
    static func sleepNow() {
        _ = run(pmsetPath, ["sleepnow"])
    }

    /// Sleep timeouts (`displaysleep`, `sleep` in minutes) per power source from `pmset -g custom` (force-sleep mode only, never on a tick).
    static func idleTimeouts() -> [String: KeepAwake.IdleTimeouts]? {
        let result = run(pmsetPath, ["-g", "custom"])
        guard result.status == 0 else { return nil }
        return parseIdleTimeouts(result.output)
    }

    static func parseIdleTimeouts(_ text: String) -> [String: KeepAwake.IdleTimeouts] {
        let display = parseSetting(text, "displaysleep"), sleep = parseSetting(text, "sleep")
        return Dictionary(uniqueKeysWithValues: Set(display.keys).union(sleep.keys).map {
            ($0, KeepAwake.IdleTimeouts(display: display[$0] ?? 0, sleep: sleep[$0] ?? 0))
        })
    }

    /// Power mode per power source from `pmset -g custom` (needs no root; only on lid close/open, never on a tick).
    static func powerModes() -> [String: Int]? {
        let result = run(pmsetPath, ["-g", "custom"])
        guard result.status == 0 else { return nil }
        return parsePowerModes(result.output)
    }

    static func parsePowerModes(_ text: String) -> [String: Int] {
        parseSetting(text, "powermode").filter { (0...2).contains($0.value) }
    }

    /// One numeric setting per power source ("c" charger, "b" battery) from `pmset -g custom`.
    static func parseSetting(_ text: String, _ key: String) -> [String: Int] {
        var values: [String: Int] = [:]
        var source: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Battery Power") { source = "b" } else if line.hasPrefix("AC Power") { source = "c" }
            let parts = line.split(separator: " ")
            if let source, parts.count == 2, parts[0] == key, let value = Int(parts[1]) { values[source] = value }
        }
        return values
    }

    /// macOS password dialog; nil = done or cancelled, otherwise an error message.
    static func runAsAdmin(_ shell: String, prompt: String) -> String? {
        let script = "do shell script \(literal(shell)) with administrator privileges with prompt \(literal(prompt))"
        let result = run("/usr/bin/osascript", ["-e", script], errors: true)
        guard result.status != 0, !result.output.contains("-128") else { return nil }
        return result.output.isEmpty ? "Failed." : result.output
    }

    private static func run(_ path: String, _ arguments: [String], errors: Bool = false) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = errors ? FileHandle.nullDevice : pipe
        p.standardError = errors ? pipe : FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
