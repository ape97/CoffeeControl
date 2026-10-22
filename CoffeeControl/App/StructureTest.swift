import AppKit
import ObjectiveC
import SwiftUI

/// Performance check (scripts/check.sh), invisible: the menu in a never-shown window, `AppModel.testStep()` several times.
/// Counts how often AppKit rebuilds the window structure or tracking areas meanwhile. Every such rebuild makes macOS reset
/// the pointer while the menu is open – with an accessibility pointer ~40–60 ms each time.
/// At most one rebuild is allowed (the list grows on the first step), none after that.
@MainActor
enum StructureTest {
    static let steps = 15
    private static var counting = false
    private static var structural = 0
    private static var tracking = 0
    private static var missing: [String] = []

    static func run(writingTo path: String) {
        hook(NSWindow.self, "_updateStructuralRegionsOnNextDisplayCycle", boolArgument: false) { structural += 1 }
        hook(NSView.self, "_setTrackingAreasDirty:", boolArgument: true) { tracking += 1 }

        let model = AppModel.shared
        model.prepareSnapshot()
        let host = NSHostingView(rootView: MenuView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        settle(host, window, seconds: 1)

        counting = true
        for _ in 0..<steps {
            model.testStep()
            settle(host, window, seconds: 0.3)
        }
        counting = false

        let failures = missing.map { "selector missing (macOS changed?): \($0)" }
            + (structural > 1 ? ["structural changes while open: \(structural) in \(steps) steps"] : [])
            + (tracking > 1 ? ["tracking areas dirty while open: \(tracking) in \(steps) steps"] : [])
        let report: [String: Any] = ["steps": steps, "structural": structural, "tracking": tracking,
                                     "ok": failures.isEmpty, "failures": failures]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    private static func settle(_ host: NSView, _ window: NSWindow, seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Counts calls of a (private) AppKit method. Hook methods without arguments using a pointer type, not `AnyObject?`
    /// (otherwise it crashes on release).
    private static func hook(_ cls: AnyClass, _ name: String, boolArgument: Bool, count: @escaping @MainActor () -> Void) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel) else { missing.append(name); return }
        let old = method_getImplementation(method)
        let note = { MainActor.assumeIsolated { if counting { count() } } }
        if boolArgument {
            typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
            let original = unsafeBitCast(old, to: F.self)
            let block: @convention(block) (AnyObject, Bool) -> Void = { obj, flag in note(); original(obj, sel, flag) }
            method_setImplementation(method, imp_implementationWithBlock(block))
        } else {
            typealias F = @convention(c) (AnyObject, Selector, UnsafeRawPointer?) -> Void
            let original = unsafeBitCast(old, to: F.self)
            let block: @convention(block) (AnyObject, UnsafeRawPointer?) -> Void = { obj, arg in note(); original(obj, sel, arg) }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
