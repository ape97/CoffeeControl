// Generates the app icon (1024 px) in the style of the macOS 26 icons:
// a gradient squircle (top → bottom) with a soft highlight and shadow, and a white SF Symbol with a shadow in front.
// Usage: swift scripts/icon.swift <output.png> <sf-symbol> <top-hex> <bottom-hex>
// A custom motif instead of an SF Symbol? Replace the "Motif" section.
import AppKit

let args = CommandLine.arguments
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
func hex(_ s: String) -> (Double, Double, Double) {
    let v = UInt32(s.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
    return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
}
let top = hex(args[3]), bottom = hex(args[4])
let mid = ((top.0 + bottom.0) / 2, (top.1 + bottom.1) / 2, (top.2 + bottom.2) / 2)

/// Superellipse like the Apple icon shape (continuous corners).
func squircle(_ rect: CGRect, n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func linear(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(body)

// Shadow below the shape
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.35))
cg.addPath(shape)
cg.setFillColor(color(bottom.0, bottom.1, bottom.2))
cg.fillPath()
cg.restoreGState()

// Base gradient, highlight at the top left, depth at the bottom right
cg.saveGState()
cg.addPath(shape)
cg.clip()
linear([color(top.0, top.1, top.2), color(mid.0, mid.1, mid.2), color(bottom.0 * 0.7, bottom.1 * 0.7, bottom.2 * 0.7)],
       CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100), locations: [0, 0.5, 1])
let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.32), color(1, 1, 1, 0)] as CFArray, locations: nil)!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 860), startRadius: 0, endCenter: CGPoint(x: 330, y: 860), endRadius: 560, options: [])
let shade = CGGradient(colorsSpace: space, colors: [color(0, 0.05, 0.15, 0.35), color(0, 0.05, 0.15, 0)] as CFArray, locations: nil)!
cg.drawRadialGradient(shade, startCenter: CGPoint(x: 820, y: 140), startRadius: 0, endCenter: CGPoint(x: 820, y: 140), endRadius: 520, options: [])

// Motif: white SF Symbol, at most 480 px, centered, with a soft shadow
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
guard let symbol = NSImage(systemSymbolName: args[2], accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
    FileHandle.standardError.write("SF Symbol not found: \(args[2])\n".data(using: .utf8)!)
    exit(1)
}
let scale = min(480 / symbol.size.width, 480 / symbol.size.height)
let w = symbol.size.width * scale, h = symbol.size.height * scale
let white = NSImage(size: symbol.size, flipped: false) { rect in
    symbol.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceIn)
    return true
}
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0, 0.08, 0.2, 0.35))
white.draw(in: NSRect(x: 512 - w / 2, y: 512 - h / 2, width: w, height: h))
cg.restoreGState()
cg.restoreGState()

// Glass edge: light rim at the top, dark at the bottom
cg.saveGState()
cg.addPath(shape)
cg.setLineWidth(6)
cg.replacePathWithStrokedPath()
cg.clip()
linear([color(1, 1, 1, 0.55), color(1, 1, 1, 0.08), color(0, 0, 0, 0.15)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100),
       locations: [0, 0.5, 1])
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
