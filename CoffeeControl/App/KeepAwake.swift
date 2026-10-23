import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import notify

/// Keeps the Mac awake – entirely on its own, without relying on any shell command (the assertions held here belong
/// to Coffee Control, no other command can release them):
/// 1. Own power assertions (IOPMAssertion): no sleep and no dimmed display on idle, like
///    `caffeinate -dims`. They apply only with the lid open – with it closed a MacBook sleeps despite any assertion.
/// 2. Disable sleep in the kernel (`pmset -a disablesleep 1`, needs root): then the Mac does not sleep at all,
///    not even with the lid closed or on battery. This needs a one-time sudo rule for exactly these commands only
///    (`SleepHelper`). Whether it takes effect is reported by the kernel itself (`IOPMrootDomain` → `SleepDisabled`).
/// 3. Optionally low power mode while the lid is closed (`pmset -c/-b powermode 1`): the user's values per power source
///    are saved beforehand and written back exactly as they were when the lid opens.
/// 4. Optionally only on the charger (`awakeOnBattery` off): on battery Coffee Control pauses and the Mac sleeps
///    normally until power is connected again.
/// 5. Display off with the lid closed: without sleep the built-in display would stay on behind the lid (the display
///    assertion keeps it awake). So with the lid closed Coffee Control releases the display assertion and turns it off
///    (`pmset displaysleepnow`), re-checks on each tick and wakes it when the lid opens. With an external monitor everything stays on.
///
/// Three modes (`Mode`): force awake (above), normal (Coffee Control does nothing, as if the app did not exist)
/// and force sleep: assertions from other processes (`caffeinate`, videos, apps) and a foreign `disablesleep 1` no
/// longer count. With the lid closed the Mac sleeps immediately (`pmset sleepnow`, like "Sleep" in the Apple menu – overrides every
/// assertion except `disablesleep`); with the lid open Coffee Control reproduces the sleep timeouts from System Settings itself
/// (idle time `HIDIdleTime`, `displaysleep`/`sleep` per power source) – only while foreign assertions exist,
/// otherwise macOS handles it. With an external monitor and the lid closed everything stays as macOS does it.
/// Exception `PreventSystemSleep` (`caffeinate -s`): on the charger not even `sleepnow` overrides
/// this assertion (device test). So before sleeping Coffee Control ends the `caffeinate` processes holding it
/// – only `caffeinate` itself, never the program that started it; newly started ones on the next attempt.
///
/// Safe on errors: the kernel value and power mode stay in place after a crash or hard quit (the Mac stays awake);
/// on the next launch `enforce()` aligns everything with the stored switch. Only what Coffee
/// Control set itself is reset (`ownsSleepDisabled`, `savedPowerModes`).
///
/// Not MainActor: calls run one after another on their own queue (`pmset` takes some 10 ms).
final class KeepAwake: @unchecked Sendable {
    struct Backend {
        var readSleepDisabled: () -> Bool?
        var setSleepDisabled: (Bool) -> Bool
        var helperInstalled: () -> Bool
        var lidClosed: () -> Bool?
        /// Power comes from the battery (nil = unknown, counts as charger).
        var onBattery: () -> Bool?
        /// Power mode per power source ("c" charger, "b" battery): 0 automatic, 1 low power, 2 high performance.
        var readPowerModes: () -> [String: Int]?
        var setPowerMode: (String, Int) -> Bool
        /// The built-in display is lit (on and not asleep); nil = unknown.
        var internalDisplayOn: () -> Bool?
        /// An external monitor is connected (then turn nothing off with the lid closed).
        var externalDisplay: () -> Bool
        var sleepDisplay: () -> Void
        var wakeDisplay: () -> Void
        /// Sleep immediately (`pmset sleepnow`).
        var sleepNow: () -> Void
        /// End the `caffeinate` processes that prevent sleep on the charger; returns the count.
        var endCaffeinate: () -> Int
        /// Seconds since the last input (keyboard, mouse, trackpad); nil = unknown.
        var idleSeconds: () -> TimeInterval?
        /// Assertions against sleep / display dimming, system-wide (in force-sleep mode Coffee Control holds none itself).
        var sleepBlockers: () -> (system: Bool, display: Bool)
        /// Sleep timeouts from System Settings per power source ("c"/"b").
        var readIdleTimeouts: () -> [String: IdleTimeouts]?
        var assertionName = "Coffee Control: keep Mac awake"
    }

    enum Mode: String, CaseIterable, Sendable {
        case awake, normal, sleep
    }

    /// Minutes from `pmset -g custom`; 0 = never.
    struct IdleTimeouts: Equatable, Sendable {
        var display: Int
        var sleep: Int

        var displayAfter: TimeInterval? { display > 0 ? TimeInterval(display * 60) : nil }
        /// Sleep at the earliest one minute after the display (macOS never sleeps while the display is lit).
        var systemAfter: TimeInterval? { sleep > 0 ? TimeInterval(max(sleep, display > 0 ? display + 1 : 0) * 60) : nil }
    }

    struct State: Equatable {
        var mode = Mode.normal
        var assertionsHeld = false
        /// Kernel value; nil = not readable.
        var sleepDisabled: Bool?
        var helperInstalled = false
        var lidClosed = false
        /// Low power mode was switched on by Coffee Control (lid closed).
        var lowPowerActive = false
        /// Switch on, but on battery with "Also on Battery" off: the Mac sleeps normally.
        var pausedOnBattery = false
        /// Force-sleep mode: other processes currently hold assertions, Coffee Control overrides them.
        var blockersOverridden = false

        var on: Bool { mode == .awake }
        /// Currently really keeps awake (switch on and not paused).
        var active: Bool { on && !pausedOnBattery }
        /// Really nothing falls asleep – not even with the lid closed.
        var fullyAwake: Bool { active && assertionsHeld && sleepDisabled == true }
    }

    static let systemAssertionTypes = [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep]
    static let displayAssertionType = kIOPMAssertPreventUserIdleDisplaySleep
    static let lowPowerMode = 1
    /// Turn the display off again at most this often if it comes back on with the lid closed.
    static let displayRetry: TimeInterval = 20
    /// With the lid closed in force-sleep mode, `sleepnow` again at most this often (e.g. after a wake in the dark).
    static let sleepRetry: TimeInterval = 30
    /// Re-read the sleep timeouts from System Settings at most this often (process start, force-sleep mode only).
    static let timeoutsMaxAge: TimeInterval = 300

    private let defaults: UserDefaults
    private let backend: Backend
    private var ids: [String: IOPMAssertionID] = [:]
    private var lidWasClosed = false
    private var displaySleptAt: Date?
    private var forcedSleepAt: Date?
    /// Idle emulation: step in again only after new input (no repeated `sleepnow` after waking).
    private var displayArmed = true
    private var sleepArmed = true
    private var timeouts: (read: Date, values: [String: IdleTimeouts])?

    init(defaults: UserDefaults, backend: Backend = .real) {
        self.defaults = defaults
        self.backend = backend
        defaults.register(defaults: ["lowPowerWhenClosed": true, "awakeOnBattery": true])
    }

    /// Stored mode (survives app and Mac restarts); up to 1.0.x a switch "enabled".
    var mode: Mode {
        get {
            if let raw = defaults.string(forKey: "mode"), let mode = Mode(rawValue: raw) { return mode }
            return defaults.bool(forKey: "enabled") ? .awake : .normal
        }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    var lowPowerWhenClosed: Bool {
        get { defaults.bool(forKey: "lowPowerWhenClosed") }
        set { defaults.set(newValue, forKey: "lowPowerWhenClosed") }
    }

    /// Also keep awake on battery (default on).
    var awakeOnBattery: Bool {
        get { defaults.bool(forKey: "awakeOnBattery") }
        set { defaults.set(newValue, forKey: "awakeOnBattery") }
    }

    /// Timer section in the menu (default off: it only shows up for those who want it).
    var showTimer: Bool {
        get { defaults.bool(forKey: "showTimer") }
        set { defaults.set(newValue, forKey: "showTimer") }
    }

    /// Durations the timer offers, in minutes (default 15m to 4h).
    var timerChoices: [Int] {
        get {
            let stored = (defaults.array(forKey: "timerChoices") as? [Int]).map(CoffeeTimer.sanitized) ?? []
            return stored.isEmpty ? CoffeeTimer.defaultChoices : stored
        }
        set { defaults.set(newValue, forKey: "timerChoices") }
    }

    /// Coffee Control changed `disablesleep` from 0 to 1 and must revert it.
    var ownsSleepDisabled: Bool {
        get { defaults.bool(forKey: "ownsSleepDisabled") }
        set { defaults.set(newValue, forKey: "ownsSleepDisabled") }
    }

    /// The user's power modes before the lid closed; set = Coffee Control must write them back.
    var savedPowerModes: [String: Int]? {
        get { defaults.dictionary(forKey: "savedPowerModes") as? [String: Int] }
        set { defaults.set(newValue, forKey: "savedPowerModes") }
    }

    func set(mode: Mode) -> State {
        self.mode = mode
        timeouts = nil   // re-read sleep timeouts
        return enforce()
    }

    func set(lowPowerWhenClosed value: Bool) -> State {
        lowPowerWhenClosed = value
        return enforce()
    }

    func set(awakeOnBattery value: Bool) -> State {
        awakeOnBattery = value
        return enforce()
    }

    /// Align reality with the switches. On launch, after every toggle, on every lid close/open and
    /// power source change, and on the tick (awake every 2 s – in case someone calls `pmset -a disablesleep 0` or the
    /// sudo rule was added –, force-sleep mode every 5 s).
    func enforce() -> State {
        let mode = self.mode
        let on = mode == .awake
        let paused = on && !awakeOnBattery && backend.onBattery() == true
        let helper = backend.helperInstalled()
        let lid = backend.lidClosed() == true
        var disabled: Bool?
        var overridden = false
        let wanted: [String]
        if on && !paused {
            let darkLid = lid && !backend.externalDisplay()
            wanted = Self.systemAssertionTypes + (darkLid ? [] : [Self.displayAssertionType])
            holdAssertions(wanted)
            disabled = enforceSleepDisabled(on: true, helper: helper)   // keep awake first, then save power
            enforcePowerMode(low: lowPowerWhenClosed && lid && helper)
            enforceDisplay(dark: darkLid)
        } else {
            wanted = []
            enforcePowerMode(low: false)   // before releasing: with the lid closed the Mac sleeps right afterwards
            disabled = enforceSleepDisabled(on: false, helper: helper, force: mode == .sleep)
            releaseAssertions()
            displaySleptAt = nil
            if mode == .sleep { overridden = enforceSleep(lid: lid, sleepDisabled: disabled) } else { resetSleep() }
        }
        // Lid open: wake the display (it was turned off by us or by the lid closing).
        if on && lidWasClosed && !lid { backend.wakeDisplay() }
        lidWasClosed = lid
        return State(mode: mode, assertionsHeld: Set(ids.keys) == Set(wanted) && !wanted.isEmpty, sleepDisabled: disabled,
                     helperInstalled: helper, lidClosed: lid, lowPowerActive: savedPowerModes != nil, pausedOnBattery: paused,
                     blockersOverridden: overridden)
    }

    /// Undo everything Coffee Control set on the system (app quit, removing the helper rule).
    /// The switch stays stored – it applies again on the next launch.
    func releaseAll() {
        enforcePowerMode(low: false)
        if ownsSleepDisabled, backend.setSleepDisabled(false) { ownsSleepDisabled = false }
        releaseAssertions()
    }

    /// `force` (force-sleep mode): also revert a foreign `disablesleep 1`.
    private func enforceSleepDisabled(on: Bool, helper: Bool, force: Bool = false) -> Bool? {
        let disabled = backend.readSleepDisabled()
        if on, helper, disabled != true {
            ownsSleepDisabled = true   // store first: if the app dies midway, the next launch reverts it
            _ = backend.setSleepDisabled(true)
        } else if !on, ownsSleepDisabled || (force && helper && disabled == true) {
            if disabled == false || backend.setSleepDisabled(false) { ownsSleepDisabled = false }
        } else {
            return disabled
        }
        return backend.readSleepDisabled()
    }

    private func enforcePowerMode(low: Bool) {
        if low, savedPowerModes == nil, let modes = backend.readPowerModes(), !modes.isEmpty {
            savedPowerModes = modes   // back up first, see above
            for (source, mode) in modes where mode != Self.lowPowerMode { _ = backend.setPowerMode(source, Self.lowPowerMode) }
        } else if !low, let saved = savedPowerModes {
            var ok = true
            for (source, mode) in saved { ok = backend.setPowerMode(source, mode) && ok }
            if ok { savedPowerModes = nil }
        }
    }

    /// Lid closed (without external monitor): display off; if it comes back on, again after `displayRetry`.
    private func enforceDisplay(dark: Bool) {
        guard dark else { displaySleptAt = nil; return }
        if backend.internalDisplayOn() == true,
           displaySleptAt.map({ Date().timeIntervalSince($0) >= Self.displayRetry }) ?? true {
            backend.sleepDisplay()
            displaySleptAt = Date()
        } else if displaySleptAt == nil {
            displaySleptAt = Date()   // already dark: step in again only after the wait
        }
    }

    /// Force sleep; returns whether there is currently something to override (foreign assertions or `disablesleep`).
    private func enforceSleep(lid: Bool, sleepDisabled: Bool?) -> Bool {
        let blockers = backend.sleepBlockers()
        let blocked = blockers.system || blockers.display || sleepDisabled == true
        if lid && !backend.externalDisplay() {
            // Lid closed: sleep immediately – without assertions macOS does that itself.
            if blocked, forcedSleepAt.map({ Date().timeIntervalSince($0) >= Self.sleepRetry }) ?? true {
                sleepNow(systemBlocked: blockers.system)
                forcedSleepAt = Date()
            }
            return blocked
        }
        forcedSleepAt = nil
        guard blocked, let idle = backend.idleSeconds(), let limits = idleTimeouts() else {
            displayArmed = true
            sleepArmed = true
            return blocked
        }
        // Lid open: sleep timeouts like macOS without the foreign assertions, once per idle period.
        if blockers.display, let after = limits.displayAfter {
            if idle < after { displayArmed = true } else if displayArmed { displayArmed = false; backend.sleepDisplay() }
        }
        if let after = limits.systemAfter {
            if idle < after { sleepArmed = true } else if sleepArmed { sleepArmed = false; sleepNow(systemBlocked: blockers.system) }
        }
        return blocked
    }

    /// On battery `PreventSystemSleep` doesn't count anyway; on the charger end the `caffeinate` assertions first.
    private func sleepNow(systemBlocked: Bool) {
        if systemBlocked, backend.onBattery() != true { _ = backend.endCaffeinate() }
        backend.sleepNow()
    }

    private func resetSleep() {
        forcedSleepAt = nil
        displayArmed = true
        sleepArmed = true
    }

    /// Sleep timeouts of the current power source; read only when needed, then at most every `timeoutsMaxAge`.
    private func idleTimeouts() -> IdleTimeouts? {
        if timeouts.map({ Date().timeIntervalSince($0.read) >= Self.timeoutsMaxAge }) ?? true {
            timeouts = (Date(), backend.readIdleTimeouts() ?? [:])
        }
        return timeouts?.values[backend.onBattery() == true ? "b" : "c"]
    }

    /// Hold exactly the desired assertions (with the lid closed without the display assertion).
    private func holdAssertions(_ types: [String]) {
        for (type, id) in ids where !types.contains(type) {
            IOPMAssertionRelease(id)
            ids[type] = nil
        }
        for type in types where ids[type] == nil {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           backend.assertionName as CFString, &id) == kIOReturnSuccess {
                ids[type] = id
            }
        }
    }

    private func releaseAssertions() {
        ids.values.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
    }
}

extension KeepAwake.Backend {
    static let real = KeepAwake.Backend(
        readSleepDisabled: { KeepAwake.rootDomainBool("SleepDisabled") },
        setSleepDisabled: { SleepHelper.pmset(["-a", "disablesleep", $0 ? "1" : "0"]) },
        helperInstalled: { FileManager.default.fileExists(atPath: SleepHelper.sudoersPath) },
        lidClosed: { KeepAwake.rootDomainBool("AppleClamshellState") },
        onBattery: { KeepAwake.onBattery() },
        readPowerModes: { SleepHelper.powerModes() },
        setPowerMode: { SleepHelper.pmset(["-\($0)", "powermode", String($1)]) },
        internalDisplayOn: { KeepAwake.displays().internalOn },
        externalDisplay: { KeepAwake.displays().external },
        sleepDisplay: { SleepHelper.sleepDisplay() },
        wakeDisplay: { KeepAwake.declareUserActivity() },
        sleepNow: { SleepHelper.sleepNow() },
        endCaffeinate: { KeepAwake.endCaffeinate() },
        idleSeconds: { KeepAwake.idleSeconds() },
        sleepBlockers: { KeepAwake.sleepBlockers() },
        readIdleTimeouts: { SleepHelper.idleTimeouts() })
}

extension KeepAwake {
    /// Value from `IOPMrootDomain`, straight from the registry (no process start, ~10 µs).
    static func rootDomainBool(_ key: String) -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    /// Built-in display lit? (if it is missing from the list, it is off) · external monitor connected?
    static func displays() -> (internalOn: Bool?, external: Bool) {
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &list, &count) == .success else { return (nil, false) }
        let online = list.prefix(Int(count))
        let internalOn = online.first(where: { CGDisplayIsBuiltin($0) != 0 }).map { CGDisplayIsAsleep($0) == 0 } ?? false
        return (internalOn, online.contains { CGDisplayIsBuiltin($0) == 0 })
    }

    /// Idle time from `IOHIDSystem` (registry, no process start, no permission needed).
    static func idleSeconds() -> TimeInterval? {
        let hid = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard hid != 0 else { return nil }
        defer { IOObjectRelease(hid) }
        let value = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber).map { $0.doubleValue / 1_000_000_000 }
    }

    /// System-wide counters of the power assertions (`IOPMCopyAssertionsStatus`, like `pmset -g assertions`).
    static func sleepBlockers() -> (system: Bool, display: Bool) {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let counts = status?.takeRetainedValue() as? [String: Any] else { return (false, false) }
        func any(_ keys: [String]) -> Bool { keys.contains { (counts[$0] as? Int ?? 0) > 0 } }
        return (any(["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]),
                any(["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]))
    }

    /// Ends the `caffeinate` processes with `PreventSystemSleep` (SIGTERM, like Ctrl-C) and waits up to ~1 s until their
    /// assertions are gone. With `caffeinate -s command`, caffeinate is a child of the command: that keeps running.
    static func endCaffeinate() -> Int {
        let pids = caffeinateHolders()
        let ended = pids.filter { kill($0, SIGTERM) == 0 }
        for _ in 0..<10 where !Set(caffeinateHolders()).isDisjoint(with: ended) { usleep(100_000) }
        return ended.count
    }

    /// Processes named `caffeinate` that currently hold `PreventSystemSleep` (`IOPMCopyAssertionsByProcess`).
    static func caffeinateHolders() -> [pid_t] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: Any] else { return [] }
        return byProcess.compactMap { pid, list in
            guard let list = list as? [[String: Any]],
                  list.contains(where: { $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventSystemSleep }),
                  processName(pid.int32Value) == "caffeinate" else { return nil }
            return pid.int32Value
        }
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Like a user input: wakes the display (lid opening).
    static func declareUserActivity() {
        var id = IOPMAssertionID(0)
        if IOPMAssertionDeclareUserActivity("Coffee Control: lid opened" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            IOPMAssertionRelease(id)
        }
    }

    /// Current power source from the system (`IOPowerSources`, no process start).
    static func onBattery() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// Reports lid close/open without a tick (`IOPMrootDomain` sends `kIOPMMessageClamshellStateChange`) and the change
/// between charger and battery (`kIOPSNotifyPowerSource`).
final class LidMonitor: @unchecked Sendable {
    /// `iokit_family_msg(sub_iokit_powermanagement, 0x100)` – not visible to Swift as a macro (IOPM.h).
    static let clamshellMessage: UInt32 = 0xE003_4100

    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var powerToken: Int32 = NOTIFY_TOKEN_INVALID

    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.onChange = onChange
        notify_register_dispatch(kIOPSNotifyPowerSource, &powerToken, queue) { _ in onChange() }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        self.port = port
        IONotificationPortSetDispatchQueue(port, queue)
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { refcon, _, type, _ in
            guard type == LidMonitor.clamshellMessage, let refcon else { return }
            Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
    }

    deinit {
        if powerToken != NOTIFY_TOKEN_INVALID { notify_cancel(powerToken) }
        if notifier != 0 { IOObjectRelease(notifier) }
        if let port { IONotificationPortDestroy(port) }
    }
}

extension KeepAwake.Backend {
    /// For snapshots: affects nothing.
    static let inert = KeepAwake.Backend(readSleepDisabled: { nil }, setSleepDisabled: { _ in false }, helperInstalled: { false },
                                         lidClosed: { nil }, onBattery: { nil }, readPowerModes: { nil }, setPowerMode: { _, _ in false },
                                         internalDisplayOn: { nil }, externalDisplay: { false }, sleepDisplay: {}, wakeDisplay: {},
                                         sleepNow: {}, endCaffeinate: { 0 }, idleSeconds: { nil }, sleepBlockers: { (false, false) }, readIdleTimeouts: { nil })
}
