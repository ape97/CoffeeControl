import AppKit
import ServiceManagement
import SwiftUI

@main
struct CoffeeControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!Runtime.headless)) {
            // New identity after every close: sub-pages and lists start fresh again.
            MenuView()
                .id(model.menuGeneration)
                .environment(model)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Own view, so the minute count only updates the label – not the scene with the menu content.
/// Changes only on switching (awake = steaming cup, normal = empty cup, force sleep = crossed out)
/// and, with a timer running, once a minute.
private struct MenuBarLabel: View {
    private let model = AppModel.shared

    var body: some View {
        Image(nsImage: CoffeeIcon.menuBar(model.iconMode, minutesLeft: model.minutesLeft))
    }
}

/// Launch modes without a menu bar: snapshots, self-test and performance check run invisibly.
enum Runtime {
    static let arguments = CommandLine.arguments
    static let isSnapshot = arguments.contains("--snapshot")
    static let isSelfTest = arguments.contains("--selftest")
    static let isStructureTest = arguments.contains("--structuretest")
    /// Manual test of the update check from the installed app: one request, result as JSON, no menu.
    static let isCheckUpdate = arguments.contains("--check-update")
    static let headless = isSnapshot || isSelfTest || isStructureTest || isCheckUpdate
    /// Fixed, generic content for promotional images; only together with `--snapshot`, default settings from a throwaway suite.
    static let isDemo = isSnapshot && arguments.contains("--demo")

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let base = Runtime.value(after: "--snapshot") {
            MainActor.assumeIsolated { Snapshot.render(to: base) }
            NSApp.terminate(nil)
        } else if let path = Runtime.value(after: "--selftest") {
            MainActor.assumeIsolated { SelfTest.run(writingTo: path) }
        } else if let path = Runtime.value(after: "--structuretest") {
            MainActor.assumeIsolated { StructureTest.run(writingTo: path) }
        } else if let path = Runtime.value(after: "--check-update") {
            MainActor.assumeIsolated { UpdateCheck.report(writingTo: path) }
        } else {
            LoginItem.enableOnFirstLaunch()
            MainActor.assumeIsolated { UpdateCheck.shared.start() }
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { Runtime.isDemo || SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if enabled { UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemPath") }
        } catch {
            NSLog("Coffee Control: login item failed: \(error)")
        }
    }

    /// Register as a login item automatically on the very first launch – only from /Applications, never from the build folder.
    /// macOS remembers the path of the copy that registered. If the registration came from another copy
    /// (e.g. build folder), it is registered once more so the installed app starts at login.
    static func enableOnFirstLaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "loginItemConfigured") {
            set(true)
            defaults.set(true, forKey: "loginItemConfigured")
        } else if isEnabled, defaults.string(forKey: "loginItemPath") != path {
            try? SMAppService.mainApp.unregister()
            set(true)
        }
    }
}

/// Developer aid: renders the menu content invisibly into PNG files (light and dark) without showing windows.
/// Usage: CoffeeControl --snapshot /path/base [--settings] [--off|--sleep] [--timer <min> [--left <min>] [--then-sleep]] [--update <version>] [--demo] …
///   →  base-light.png, base-dark.png, base-symbol.png (menu bar, double resolution)
enum Snapshot {
    @MainActor
    static func render(to base: String) {
        let model = AppModel.shared
        model.prepareSnapshot()
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: name)!
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.appearance = appearance
            let host = NSHostingView(rootView: MenuView().environment(model))
            host.appearance = appearance
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let size = host.fittingSize
            effect.frame = NSRect(origin: .zero, size: size)
            host.frame = effect.bounds
            effect.addSubview(host)
            let window = NSWindow(contentRect: effect.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = effect
            effect.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { continue }
            effect.cacheDisplay(in: effect.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(suffix).png"))
        }
        DemoTargets.write(to: "\(base)-targets.json")
        // Menu bar: on a light and a dark strip, double resolution.
        let icon = CoffeeIcon.menuBar(model.iconMode, minutesLeft: model.minutesLeft)
        let size = NSSize(width: icon.size.width + 16, height: 24)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size.width, height: size.height * 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, background, ink) in [(1, NSColor.white, NSColor.black), (0, NSColor(white: 0.16, alpha: 1), NSColor.white)] {
            let frame = NSRect(x: 0, y: CGFloat(row) * size.height, width: size.width, height: size.height)
            background.setFill()
            frame.fill()
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: 8, y: frame.minY + (size.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-symbol.png"))
    }
}
