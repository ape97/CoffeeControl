import AppKit

/// Invisible self-test (scripts/check.sh): checks the core logic and writes the result as JSON.
/// Must not touch any window, focus, system settings or foreign processes – the user should notice nothing.
@MainActor
enum SelfTest {
    static func run(writingTo path: String) {
        var failures: [String] = []
        var report: [String: Any] = [:]
        report["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        for symbol in [AppModel.menuBarSymbol, AppModel.menuBarSymbolOff]
        where NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
            failures.append("menu bar symbol missing: \(symbol)")
        }
        checkHelper(&failures)
        checkLogic(&failures)
        checkTimer(&failures)
        checkTimerRuns(&failures)
        // Only read the real system.
        if KeepAwake.rootDomainBool("SleepDisabled") == nil { failures.append("IOPMrootDomain SleepDisabled not readable") }
        report["sleepDisabled"] = KeepAwake.rootDomainBool("SleepDisabled") ?? "?"
        report["lidClosed"] = KeepAwake.rootDomainBool("AppleClamshellState") ?? "?"
        report["powerModes"] = SleepHelper.powerModes() ?? [:]
        report["onBattery"] = KeepAwake.onBattery() ?? "?"
        let displays = KeepAwake.displays()
        report["internalDisplayOn"] = displays.internalOn ?? "?"
        report["externalDisplay"] = displays.external

        report["ok"] = failures.isEmpty
        report["failures"] = failures
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    /// Timer: countdown arithmetic and the flow on the (stand-in) model – start, count down, cancel by hand, expire.
    private static func checkTimer(_ failures: inout [String]) {
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append("timer: \(what)") } }
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let end = now.addingTimeInterval(30 * 60)
        expect(CoffeeTimer.minutesLeft(until: end, now: now) == 30, "full duration")
        expect(CoffeeTimer.minutesLeft(until: end, now: now.addingTimeInterval(1)) == 30, "rounds up")
        expect(CoffeeTimer.minutesLeft(until: end, now: now.addingTimeInterval(60)) == 29, "one minute later")
        expect(CoffeeTimer.minutesLeft(until: end, now: end.addingTimeInterval(5)) == 0, "never negative")
        expect(CoffeeTimer.nextChange(end: end, now: now.addingTimeInterval(1)) == now.addingTimeInterval(60), "next change on the minute")
        expect(CoffeeTimer.nextChange(end: end, now: end.addingTimeInterval(-30)) == end, "last minute ends at the end")
        expect(CoffeeTimer.defaultChoices.map(CoffeeTimer.short) == ["15m", "30m", "1h", "2h", "4h"], "segment labels")
        let typed = ["45", "45m", "45 min", "8h", "16 H", "1.5h", "1,5h", "1h30", "1h 30m", "1:30", "99h"].map(CoffeeTimer.parse)
        expect(typed == [45, 45, 45, 480, 960, 90, 90, 90, 90, 90, 5940], "typed durations: \(typed)")
        expect(["", "h", "abc", "0", "0m", "100h", "-5", "1:75", "inf"].allSatisfy { CoffeeTimer.parse($0) == nil }, "rejects nonsense")
        expect(CoffeeTimer.sanitized([960, 30, 30, 0, 480, 15, 60, 120, 240]) == [15, 30, 60, 120, 240, 480], "sorted, unique, at most six")
        expect(CoffeeTimer.short(65) == "1h 5m", "hours and minutes")
        expect(CoffeeTimer.target(.sleep, current: .awake) == .sleep && CoffeeTimer.target(.normal, current: .normal) == .sleep
               && CoffeeTimer.target(.sleep, current: .sleep) == .normal, "never follows itself")

        let model = AppModel.shared
        let before = model.state.mode
        model.setMode(.awake)
        model.setTimerThen(.sleep)
        model.setTimer(30)
        expect(model.timerMinutes == 30 && model.minutesLeft == 30, "start: \(String(describing: model.minutesLeft))")
        model.advanceTimer(by: 60)
        expect(model.minutesLeft == 29, "counts down: \(String(describing: model.minutesLeft))")
        let image = CoffeeIcon.menuBar(.awake, minutesLeft: 29)
        expect(image.isTemplate && image.size.width > CoffeeIcon.image(.awake, pointSize: 14, weight: .regular).size.width + 10, "menu bar shows the time")
        model.setMode(.normal)
        expect(model.timerMinutes == nil && model.minutesLeft == nil, "switching by hand cancels")
        model.setMode(.awake)
        model.setTimer(15)
        model.advanceTimer(by: 15 * 60)
        expect(model.state.mode == .sleep && model.timerMinutes == nil && model.minutesLeft == nil, "expires into the chosen mode")
        let shown = model.showTimer
        model.setTimer(30)
        model.setShowTimer(false)
        expect(model.timerMinutes == nil && model.minutesLeft == nil, "hiding the timer cancels it")
        model.setShowTimer(shown)

        let choices = model.timerChoices
        model.removeTimerChoice(240)
        expect(model.addTimerChoice("8h") && model.addTimerChoice("16h") && !model.addTimerChoice("soon"), "add typed durations")
        expect(model.timerChoices == [15, 30, 60, 120, 480, 960], "custom durations: \(model.timerChoices)")
        model.addTimerChoice("3h")
        expect(model.timerChoices.count == CoffeeTimer.maxChoices && !model.timerChoices.contains(180), "list stays at six")
        for minutes in model.timerChoices { model.removeTimerChoice(minutes) }
        expect(model.timerChoices == [960], "the last duration stays")
        for minutes in choices { model.addTimerChoice("\(minutes)") }
        model.removeTimerChoice(960)
        expect(model.timerChoices == choices, "restored: \(model.timerChoices)")
        model.setMode(before)
    }

    /// Timer on the real run loop (a few seconds): the minute change and the expiry must fire by themselves,
    /// without `advanceTimer` doing the work. The inert stand-in keeps the switch away from the system.
    private static func checkTimerRuns(_ failures: inout [String]) {
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append("timer run: \(what)") } }
        func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let model = AppModel.shared
        let before = model.state.mode
        model.setMode(.awake)
        model.setTimerThen(.sleep)
        // 2 minutes, 62 s left: the shown minute changes in 2 s, then the end is 60 s away.
        model.setTimer(2)
        model.advanceTimer(by: 58)
        expect(model.minutesLeft == 2, "start: \(String(describing: model.minutesLeft))")
        wait(4)
        expect(model.minutesLeft == 1 && model.state.mode == .awake, "minute changes: \(String(describing: model.minutesLeft))")
        // Bring the end to 2 s from now (replaces the planned timer), then wait for it.
        model.advanceTimer(by: 58)
        wait(4)
        expect(model.state.mode == .sleep && model.timerMinutes == nil && model.minutesLeft == nil,
               "expires by itself: \(model.state.mode) \(String(describing: model.minutesLeft))")
        model.setMode(before)
    }

    /// Sudo rule: syntax via `visudo -cf` on its own temp file; the install command validates before installing.
    private static func checkHelper(_ failures: inout [String]) {
        let lines = SleepHelper.sudoersLines(user: "user")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("coffeecontrol-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: file) }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        p.arguments = ["-cf", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { p.waitUntilExit() }
        if p.terminationStatus != 0 { failures.append("sudoers rule rejected by visudo") }
        let rule = lines[1]
        if rule.components(separatedBy: ", ").count != SleepHelper.allowed.count || rule.contains("ALL = (root) NOPASSWD: ALL") {
            failures.append("sudoers rule not limited to pmset calls: \(rule)")
        }
        let cmd = SleepHelper.installCommand(user: "user")
        guard let check = cmd.range(of: "visudo -cf"), let move = cmd.range(of: "/bin/mv -f"), check.upperBound < move.lowerBound,
              cmd.contains("chmod 0440"), cmd.contains("chown root:wheel") else {
            return failures.append("install command must check, chown and chmod before moving")
        }
        if SleepHelper.pmset(["-a", "sleep", "0"]) { failures.append("pmset accepted a call outside the rule") }
        let sample = "Battery Power:\n lowpowermode         0\n powermode            0\n sleep 1\nAC Power:\n powermode            2\n"
        if SleepHelper.parsePowerModes(sample) != ["b": 0, "c": 2] { failures.append("power mode parser wrong") }
        let timeouts = "Battery Power:\n Sleep On Power Button 1\n displaysleep         5\n sleep                1\nAC Power:\n displaysleep 10\n sleep 0\n"
        if SleepHelper.parseIdleTimeouts(timeouts) != ["b": .init(display: 5, sleep: 1), "c": .init(display: 10, sleep: 0)] {
            failures.append("idle timeout parser wrong")
        }
    }

    /// Switching logic on a replica system (stand-in): none of it reaches pmset or the kernel.
    private static func checkLogic(_ failures: inout [String]) {
        final class Fake: @unchecked Sendable {
            var sleepDisabled = false
            var helper = true
            var lid = false
            var battery = false
            var modes = ["c": 2, "b": 0]
            var failRestore = false
            var displayOn = true
            var displayStuck = false
            var external = false
            var idle: TimeInterval = 0
            var blockers = (system: false, display: false)
            var timeouts = ["c": KeepAwake.IdleTimeouts(display: 10, sleep: 1), "b": KeepAwake.IdleTimeouts(display: 5, sleep: 1)]
            var timeoutReads = 0
            var log: [String] = []
        }
        func make(_ fake: Fake) -> KeepAwake {
            let backend = KeepAwake.Backend(
                readSleepDisabled: { fake.sleepDisabled },
                setSleepDisabled: { v in fake.log.append("sleep\(v ? 1 : 0)"); guard fake.helper else { return false }; fake.sleepDisabled = v; return true },
                helperInstalled: { fake.helper },
                lidClosed: { fake.lid },
                onBattery: { fake.battery },
                readPowerModes: { fake.modes },
                setPowerMode: { s, m in fake.log.append("\(s)\(m)"); if fake.failRestore, m != 1 { return false }; fake.modes[s] = m; return true },
                internalDisplayOn: { fake.displayOn },
                externalDisplay: { fake.external },
                sleepDisplay: { fake.log.append("dark"); if !fake.displayStuck { fake.displayOn = false } },
                wakeDisplay: { fake.log.append("wake"); fake.displayOn = true },
                sleepNow: { fake.log.append("sleepnow") },
                endCaffeinate: { fake.log.append("endcaffeinate"); return 1 },
                idleSeconds: { fake.idle },
                sleepBlockers: { fake.blockers },
                readIdleTimeouts: { fake.timeoutReads += 1; return fake.timeouts },
                assertionName: "Coffee Control self-test")
            return KeepAwake(defaults: AppModel.scratchDefaults(), backend: backend)
        }
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append("logic: \(what)") } }

        // On/off with the helper rule; power assertions in our own process.
        var f = Fake()
        var k = make(f)
        var s = k.set(mode: .awake)
        expect(s.fullyAwake && s.assertionsHeld && k.ownsSleepDisabled && f.sleepDisabled, "on sets disablesleep and holds assertions")
        s = k.enforce()
        expect(f.log == ["sleep1"], "enforce while on is idempotent: \(f.log)")
        f.sleepDisabled = false   // someone calls "pmset -a disablesleep 0"
        s = k.enforce()
        expect(s.sleepDisabled == true && f.log == ["sleep1", "sleep1"], "re-enables after external change")
        s = k.set(mode: .normal)
        expect(!s.on && !s.assertionsHeld && !f.sleepDisabled && !k.ownsSleepDisabled, "off restores sleep")

        // Do not adopt or revert a foreign disablesleep.
        f = Fake(); f.sleepDisabled = true
        k = make(f)
        _ = k.set(mode: .awake); _ = k.set(mode: .normal)
        expect(f.log.isEmpty && f.sleepDisabled && !k.ownsSleepDisabled, "foreign disablesleep untouched: \(f.log)")

        // Without the helper rule: only assertions, honest state.
        f = Fake(); f.helper = false
        k = make(f)
        s = k.set(mode: .awake)
        expect(s.assertionsHeld && s.sleepDisabled == false && !s.fullyAwake && f.log.isEmpty, "no helper: assertions only")
        _ = k.set(mode: .normal)

        // After a crash: switch off, but disablesleep was still set by us → revert it.
        f = Fake(); f.sleepDisabled = true
        k = make(f)
        k.ownsSleepDisabled = true
        _ = k.enforce()
        expect(!f.sleepDisabled && !k.ownsSleepDisabled, "crash cleanup")

        // Low power mode with the lid closed: save, set, restore exactly on opening.
        f = Fake()
        k = make(f)
        _ = k.set(mode: .awake)
        f.lid = true
        s = k.enforce()
        expect(s.lowPowerActive && f.modes == ["c": 1, "b": 1] && k.savedPowerModes == ["c": 2, "b": 0], "lid closed → low power")
        f.lid = false
        s = k.enforce()
        expect(!s.lowPowerActive && f.modes == ["c": 2, "b": 0] && k.savedPowerModes == nil, "lid open → modes restored")

        // Switching off with the lid closed: power mode back first, then allow sleep.
        f.lid = true
        _ = k.enforce()
        f.log = []
        _ = k.set(mode: .normal)
        expect(f.log.last == "sleep0" && f.modes == ["c": 2, "b": 0], "off while closed restores modes before sleep: \(f.log)")

        // Option off: don't change the power mode with the lid closed.
        f = Fake(); f.lid = true
        k = make(f)
        _ = k.set(lowPowerWhenClosed: false)
        _ = k.set(mode: .awake)
        expect(f.modes == ["c": 2, "b": 0] && k.savedPowerModes == nil, "low power option off")
        _ = k.set(mode: .normal)

        // Writing back fails → the backup stays, the next attempt catches up.
        f = Fake(); f.lid = true
        k = make(f)
        _ = k.set(mode: .awake)
        f.failRestore = true; f.lid = false
        _ = k.enforce()
        expect(k.savedPowerModes == ["c": 2, "b": 0], "failed restore keeps saved modes")
        f.failRestore = false
        _ = k.enforce()
        expect(k.savedPowerModes == nil && f.modes == ["c": 2, "b": 0], "restore retried")
        k.releaseAll()
        expect(!f.sleepDisabled, "releaseAll restores sleep")

        // Battery: default stays awake; "Also on Battery" off → pause, awake again immediately on the charger.
        f = Fake(); f.battery = true
        k = make(f)
        s = k.set(mode: .awake)
        expect(s.fullyAwake && !s.pausedOnBattery && f.sleepDisabled, "awake on battery by default")
        f.lid = true
        s = k.enforce()
        f.log = []
        s = k.set(awakeOnBattery: false)
        expect(s.on && s.pausedOnBattery && !s.active && !s.assertionsHeld && !f.sleepDisabled && f.modes == ["c": 2, "b": 0]
               && f.log.last == "sleep0", "battery option off pauses (modes before sleep0): \(f.log)")
        f.battery = false
        s = k.enforce()
        expect(s.fullyAwake && !s.pausedOnBattery && s.lowPowerActive, "plugged in → awake again")
        _ = k.set(mode: .normal)
        expect(!f.sleepDisabled && f.modes == ["c": 2, "b": 0], "off after battery round trip")
        if KeepAwake.onBattery() == nil { failures.append("power source not readable") }

        // Lid closed: display off (once, not on every tick), system assertions stay; wake on opening.
        f = Fake()
        k = make(f)
        _ = k.set(mode: .awake)
        f.lid = true; f.log = []
        s = k.enforce(); s = k.enforce()
        expect(f.log.filter { $0 == "dark" }.count == 1 && !f.displayOn && s.assertionsHeld && s.fullyAwake, "lid closed → display off once: \(f.log)")
        f.lid = false; f.log = []
        s = k.enforce()
        expect(f.log.contains("wake") && f.displayOn && s.assertionsHeld, "lid opened → display woken: \(f.log)")
        // If it won't turn off with the lid closed, don't retry every 2 s (earliest after displayRetry).
        f.lid = true; f.displayStuck = true; f.log = []
        _ = k.enforce(); _ = k.enforce(); _ = k.enforce()
        expect(f.log.filter { $0 == "dark" }.count == 1, "display retry throttled: \(f.log)")
        _ = k.set(mode: .normal)
        // External monitor: turn nothing off with the lid closed.
        f = Fake(); f.external = true
        k = make(f)
        _ = k.set(mode: .awake)
        f.lid = true; f.log = []
        _ = k.enforce()
        expect(!f.log.contains("dark") && f.displayOn, "external display stays on")
        _ = k.set(mode: .normal)

        // State up to 1.0.x: the switch "enabled" becomes the mode.
        let legacy = AppModel.scratchDefaults()
        legacy.set(true, forKey: "enabled")
        expect(KeepAwake(defaults: legacy, backend: .inert).mode == .awake, "legacy switch → awake")

        // Force sleep: revert a foreign disablesleep 1, no own assertions, no power mode.
        f = Fake(); f.sleepDisabled = true
        k = make(f)
        s = k.set(mode: .sleep)
        expect(!f.sleepDisabled && !s.assertionsHeld && s.blockersOverridden == false && f.log == ["sleep0"],
               "sleep mode clears foreign disablesleep: \(f.log)")
        // Normal: a foreign disablesleep stays (checked above); awake → sleep releases its own.
        f = Fake()
        k = make(f)
        _ = k.set(mode: .awake)
        s = k.set(mode: .sleep)
        expect(!f.sleepDisabled && !s.assertionsHeld && !k.ownsSleepDisabled, "awake → sleep releases everything")
        // Without the helper rule a foreign disablesleep can't go away: report honestly.
        f = Fake(); f.sleepDisabled = true; f.helper = false
        k = make(f)
        s = k.set(mode: .sleep)
        expect(s.sleepDisabled == true && s.blockersOverridden && f.log.isEmpty, "sleep mode without helper reports block")

        // Lid closed with a foreign assertion: sleep immediately, don't repeat on the tick; without one macOS does it.
        f = Fake(); f.blockers = (true, false)
        k = make(f)
        _ = k.set(mode: .sleep)
        f.lid = true; f.log = []
        s = k.enforce(); s = k.enforce()
        expect(f.log == ["endcaffeinate", "sleepnow"] && s.blockersOverridden, "lid closed → end caffeinate, sleep now once: \(f.log)")
        // Battery: PreventSystemSleep doesn't count there → caffeinate stays; display assertion only → likewise.
        f.lid = false; _ = k.enforce(); f.battery = true; f.lid = true; f.log = []
        _ = k.enforce()
        expect(f.log == ["sleepnow"], "battery → caffeinate untouched: \(f.log)")
        f.lid = false; _ = k.enforce(); f.battery = false; f.blockers = (false, true); f.lid = true; f.log = []
        _ = k.enforce()
        expect(f.log == ["sleepnow"], "display block only → caffeinate untouched: \(f.log)")
        f.lid = false; f.blockers = (false, false); _ = k.enforce()
        f.lid = true; f.log = []
        _ = k.enforce()
        expect(f.log.isEmpty, "lid closed without blockers → macOS sleeps itself: \(f.log)")
        f.blockers = (true, true); f.external = true
        _ = k.enforce()
        expect(f.log.isEmpty, "lid closed with external display → unchanged: \(f.log)")

        // Lid open: sleep timeouts (charger 10/1 min → display after 10, sleep after 11 min) despite foreign assertions.
        f = Fake(); f.blockers = (true, true)
        k = make(f)
        _ = k.set(mode: .sleep)
        f.idle = 9 * 60; _ = k.enforce()
        expect(f.log.isEmpty, "idle below display timeout → nothing: \(f.log)")
        f.idle = 10 * 60; _ = k.enforce(); _ = k.enforce()
        expect(f.log == ["dark"], "display timeout → display off once: \(f.log)")
        f.idle = 11 * 60; _ = k.enforce(); _ = k.enforce()
        expect(f.log == ["dark", "endcaffeinate", "sleepnow"], "sleep timeout → sleep now once: \(f.log)")
        f.idle = 0; _ = k.enforce()
        f.idle = 11 * 60; _ = k.enforce()
        expect(f.log == ["dark", "endcaffeinate", "sleepnow", "dark", "endcaffeinate", "sleepnow"], "new idle period → again: \(f.log)")
        expect(f.timeoutReads == 1, "timeouts read once, not per tick: \(f.timeoutReads)")
        // Battery: own sleep timeouts (5/1 → display after 5, sleep after 6 min).
        f.battery = true; f.idle = 0; _ = k.enforce(); f.log = []
        f.idle = 6 * 60; _ = k.enforce()
        expect(f.log == ["dark", "sleepnow"], "battery timeouts: \(f.log)")
        // System assertion only (e.g. caffeinate -i): macOS handles the display itself.
        f = Fake(); f.blockers = (true, false); f.idle = 11 * 60
        k = make(f)
        _ = k.set(mode: .sleep)
        expect(f.log == ["endcaffeinate", "sleepnow"], "system block only → no display call: \(f.log)")
        // Without foreign assertions do nothing (macOS takes over); respect "sleep never".
        f = Fake(); f.idle = 60 * 60
        k = make(f)
        s = k.set(mode: .sleep)
        expect(f.log.isEmpty && !s.blockersOverridden && f.timeoutReads == 0, "no blockers → hands off: \(f.log)")
        f = Fake(); f.blockers = (true, true); f.idle = 60 * 60; f.timeouts["c"] = .init(display: 0, sleep: 0)
        k = make(f)
        _ = k.set(mode: .sleep)
        expect(f.log.isEmpty, "never sleep setting respected: \(f.log)")
        _ = k.set(mode: .normal)
        expect(f.log.isEmpty, "normal mode touches nothing: \(f.log)")
    }
}
