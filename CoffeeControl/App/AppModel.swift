import AppKit
import Observation
import os

/// Central app state.
///
/// Performance pattern: if the app needs a tick, use exactly one `Timer` (with `tolerance`, run-loop mode `.common`).
/// Sampled values go into `@ObservationIgnored` buffers and are handed to observed properties only while the menu is
/// open – otherwise SwiftUI re-evaluates the invisible menu on every tick.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// SF Symbols in the menu bar (and in the app icon): steaming cup = awake, empty cup = normal,
    /// crossed-out cup = force sleep (no moon: macOS itself uses that for Focus/night mode).
    static let menuBarSymbol = "cup.and.heat.waves.fill"
    static let menuBarSymbolOff = "cup.and.saucer"

    /// Actual state (assertions, kernel value, helper rule, lid) – reported by `KeepAwake`, not assumed.
    private(set) var state = KeepAwake.State()
    private(set) var lowPowerWhenClosed: Bool
    private(set) var awakeOnBattery: Bool
    /// Password dialog in progress (setting up/removing the helper rule).
    private(set) var isBusy = false
    private(set) var setupError: String?

    /// Which cup is shown: awake without a real assertion counts as normal.
    var iconMode: KeepAwake.Mode { state.mode == .awake && !state.active ? .normal : state.mode }

    /// Snapshots and self-test work on their own storage and with stand-ins, never on the real system.
    @ObservationIgnored private let keepAwake: KeepAwake
    @ObservationIgnored private let queue = DispatchQueue(label: "io.github.ape97.coffeecontrol.keepawake", qos: .userInitiated)
    @ObservationIgnored private var lidMonitor: LidMonitor?
    @ObservationIgnored private var timer: Timer?

    /// Incremented once the menu window has closed (resets sub-pages and lists).
    private(set) var menuGeneration = 0
    private(set) var isMenuOpen = false

    @ObservationIgnored private var closeChecks: Set<ObjectIdentifier> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        keepAwake = Runtime.headless ? KeepAwake(defaults: AppModel.scratchDefaults(), backend: .inert) : KeepAwake(defaults: .standard)
        lowPowerWhenClosed = keepAwake.lowPowerWhenClosed
        awakeOnBattery = keepAwake.awakeOnBattery
        guard !Runtime.headless else { return }
        observeMenu()
        // On launch (also after a crash): bring reality in line with the stored switch.
        perform { $0.enforce() }
        lidMonitor = LidMonitor(queue: queue) { [keepAwake] in
            let state = keepAwake.enforce()
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.apply(state) } }
        }
        // On a clean quit: restore normal sleep behavior (synchronous – nothing runs afterwards).
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [keepAwake, queue] _ in
            queue.sync { keepAwake.releaseAll() }
        })
    }

    static func scratchDefaults() -> UserDefaults {
        let name = "io.github.ape97.coffeecontrol." + (Runtime.isDemo ? "demo" : "test")
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Keep awake

    func setMode(_ mode: KeepAwake.Mode) {
        state.mode = mode   // the switch follows immediately, the rest after the report
        perform { $0.set(mode: mode) }
    }

    func setLowPowerWhenClosed(_ value: Bool) {
        lowPowerWhenClosed = value
        perform { $0.set(lowPowerWhenClosed: value) }
    }

    func setAwakeOnBattery(_ value: Bool) {
        awakeOnBattery = value
        perform { $0.set(awakeOnBattery: value) }
    }

    /// Set up the helper rule once via a password dialog; it takes effect immediately.
    func installHelper() {
        guard let user = SleepHelper.userName else { setupError = "Unsupported user name."; return }
        admin(SleepHelper.installCommand(user: user), prompt: "Coffee Control wants to keep your Mac awake with the lid closed.") { _ in }
    }

    /// First undo everything that was set with the rule, then remove the rule.
    func removeHelper() {
        admin(SleepHelper.removeCommand, prompt: "Coffee Control wants to remove its sleep rule.") { $0.releaseAll() }
    }

    private func admin(_ command: String, prompt: String, before: @escaping @Sendable (KeepAwake) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        setupError = nil
        queue.async { [keepAwake] in
            before(keepAwake)
            let error = SleepHelper.runAsAdmin(command, prompt: prompt)
            let state = keepAwake.enforce()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    model.isBusy = false
                    model.setupError = error
                    model.apply(state)
                }
            }
        }
    }

    private func perform(_ work: @escaping @Sendable (KeepAwake) -> KeepAwake.State) {
        queue.async { [keepAwake] in
            let state = work(keepAwake)
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.apply(state) } }
        }
    }

    private func apply(_ new: KeepAwake.State) {
        if new != state { state = new }
        updateTimer()
    }

    /// Awake: every 2 s check whether someone allowed idle sleep again (e.g. `pmset disablesleep 0`) and revert it –
    /// so at most a window of a little over 2 s remains. Force sleep: every 5 s check foreign assertions and
    /// idle time (sleep timeouts are minutes). Checking costs only registry and assertion queries (microseconds);
    /// `pmset` runs only on a mismatch. Normal: no tick. Closing the lid and power source changes report immediately as well.
    private func updateTimer() {
        let interval: TimeInterval? = switch state.mode {
        case .awake: 2
        case .sleep: 5
        case .normal: nil
        }
        guard interval != timer?.timeInterval else { return }
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.perform { $0.enforce() } }
        }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Menu open / closed

    private func menuOpened() {
        guard !isMenuOpen else { return }
        isMenuOpen = true
    }

    private func menuClosed() {
        isMenuOpen = false
        menuGeneration += 1
    }

    /// Opened = the menu window becomes key; closed = the window is no longer visible
    /// (a mere loss of focus from a context menu or tooltip does not count).
    private func observeMenu() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.menuOpened() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { AppModel.shared.awaitClose(window) }
        })
    }

    private func awaitClose(_ window: NSWindow) {
        guard closeChecks.insert(ObjectIdentifier(window)).inserted else { return }
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak window] in
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    guard let window, !window.isKeyWindow else {
                        if let window { model.closeChecks.remove(ObjectIdentifier(window)) }
                        return
                    }
                    if window.isVisible { return check() }
                    model.closeChecks.remove(ObjectIdentifier(window))
                    // Measuring aid: scripts/measure-menu.sh ends on this line.
                    Logger(subsystem: "io.github.ape97.coffeecontrol", category: "menu").notice("Menu closed")
                    model.menuClosed()
                }
            }
        }
        check()
    }

    // MARK: Testing

    /// For snapshots and the performance check: set up state as if the menu had been open for a few seconds.
    func prepareSnapshot() {
        let args = Runtime.arguments
        let helper = !args.contains("--nohelper")
        let mode: KeepAwake.Mode = args.contains("--sleep") ? .sleep : args.contains("--off") ? .normal : .awake
        let on = mode == .awake
        let paused = on && args.contains("--battery")
        state = KeepAwake.State(mode: mode, assertionsHeld: on && !paused, sleepDisabled: on && helper && !paused, helperInstalled: helper,
                                lidClosed: args.contains("--closed"), lowPowerActive: on && args.contains("--closed"), pausedOnBattery: paused,
                                blockersOverridden: args.contains("--blocked"))
        if paused { awakeOnBattery = false }
        setupError = args.contains("--error") ? "visudo: syntax error" : nil
    }

    /// Performance check: exactly one update as with the menu open (e.g. a tick with new values).
    /// Fill it with its own function once the menu content changes by itself.
    func testStep() {}
}

/// Cup symbols as template images. SF Symbols has no crossed-out cup, so the slash is drawn by hand
/// (with a gap like Apple's `.slash` variants). Created once per size: same instance = no resetting.
@MainActor
enum CoffeeIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(_ mode: KeepAwake.Mode, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
        let key = "\(mode.rawValue)-\(pointSize)-\(weight.rawValue)"
        if let image = cache[key] { return image }
        let name = mode == .awake ? AppModel.menuBarSymbol : AppModel.menuBarSymbolOff
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) ?? NSImage()
        var image = base
        if mode == .sleep {
            let line = pointSize * (weight == .regular ? 0.09 : 0.11)
            image = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                guard let context = NSGraphicsContext.current?.cgContext else { return true }
                let inset = rect.width * 0.08
                context.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset * 0.4))
                context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset * 0.4))
                context.setLineCap(.round)
                context.setBlendMode(.clear)
                context.setLineWidth(line * 3)
                context.strokePath()
                context.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset * 0.4))
                context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset * 0.4))
                context.setBlendMode(.normal)
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(line)
                context.strokePath()
                return true
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = switch mode {
        case .awake: "Coffee Control: awake"
        case .normal: "Coffee Control: normal"
        case .sleep: "Coffee Control: force sleep"
        }
        cache[key] = image
        return image
    }
}
