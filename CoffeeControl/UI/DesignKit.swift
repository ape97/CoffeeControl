import AppKit
import SwiftUI

// Shared building blocks of the menu bar apps (design tokens and small views).
// Keep look changes in sync across all apps so the design stays identical.

/// Tile in the style of Control Center modules.
struct Module<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(scheme == .dark ? 0.06 : 0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(scheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
            )
    }
}

/// Small round button with a symbol.
struct RoundIconButton: View {
    let symbol: String
    var size: CGFloat = 22
    var active = false
    var activeColor: Color = .accentColor
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(active ? Color.white : (hover ? Color.primary : Color.secondary))
                .frame(width: size, height: size)
                .background(active ? AnyShapeStyle(activeColor.gradient) : AnyShapeStyle(.primary.opacity(hover ? 0.12 : 0.07)), in: Circle())
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Colored round symbol (like devices in a sound mixer).
struct DeviceBadge: View {
    let symbol: String
    var size: CGFloat = 24
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: Circle())
    }
}

/// Soft edge at the bottom when the list scrolls.
struct ScrollFade: View {
    let active: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
            if active {
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
            }
        }
    }
}

/// Switch for settings. Snapshots run in an app that is never active, where AppKit draws a switch that is on in its grey
/// inactive look; there a drawn copy of the active switch covers it, so the images show the switch as it looks in the open menu.
struct SettingSwitchStyle: ToggleStyle {
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .overlay(alignment: .trailing) {
                if Runtime.isSnapshot && configuration.isOn {
                    let mini = controlSize == .mini
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: mini ? 32 : 44, height: mini ? 15 : 20)
                        .overlay(alignment: .trailing) {
                            Capsule().fill(.white).frame(width: mini ? 19 : 27, height: mini ? 11 : 16).padding(.trailing, 2)
                        }
                }
            }
    }
}

extension ToggleStyle where Self == SettingSwitchStyle {
    static var setting: SettingSwitchStyle { SettingSwitchStyle() }
}

/// Snapshot mode only: where controls sit in the rendered menu, in points from its top left. Written next to the images as
/// <base>-targets.json, so the README animations (scripts/compose.swift --scene) can point the cursor at them.
@MainActor
enum DemoTargets {
    static var frames: [String: CGRect] = [:]
    static func write(to path: String) {
        let json = frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height].map { ($0 * 10).rounded() / 10 } }
        try? JSONEncoder().encode(json).write(to: URL(fileURLWithPath: path))
    }
}

extension View {
    /// Records this view's frame for the README animations (snapshots only, see `DemoTargets`).
    func demoTarget(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if Runtime.isSnapshot { DemoTargets.frames[id] = frame }
        }
    }
}

/// Explanation under a setting or status: secondary, wraps to as many lines as it needs and is never truncated.
/// `fixedSize(vertical:)` makes the menu panel measure the full height; without it the panel cuts the text off.
struct SettingNote: View {
    let text: String
    var tint: Color? = nil
    init(_ text: String, tint: Color? = nil) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Number in a small capsule (e.g. the number of processes of an app).
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.primary.opacity(0.07), in: Capsule())
    }
}

/// Settings row: colored square with symbol + title.
struct SettingLabel: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title).font(.system(size: 12))
        }
    }
}

// MARK: Numbers

/// Whole percent (tiles, menu bar).
func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

/// Percent in lists: below 10 % with one decimal place.
func finePercent(_ v: Double) -> String {
    let p = v * 100
    return p < 9.95 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
}

func bytes(_ value: UInt64) -> String {
    let gb = Double(value) / 1_073_741_824
    if gb >= 1 { return String(format: gb >= 100 ? "%.0f GB" : "%.1f GB", gb) }
    let mb = Double(value) / 1_048_576
    return mb >= 1 ? String(format: "%.0f MB", mb) : String(format: "%.0f KB", Double(value) / 1024)
}

/// Renders a symbol once at exactly the display size (Retina 2×). App symbols (layered since macOS 26)
/// would otherwise be downscaled from large templates on every redraw of the row – ~150× more expensive in the test.
enum IconRaster {
    static func fixed(_ image: NSImage, points: CGFloat) -> NSImage {
        let px = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }
}
