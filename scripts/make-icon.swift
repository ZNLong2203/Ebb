// Draws the 1024px app icon: an ebb tide pulling back over sand, uncovering a few
// "files" left on the beach. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

let dropShadow = NSShadow()
dropShadow.shadowColor = color(0x000000, 0.35)
dropShadow.shadowBlurRadius = 30
dropShadow.shadowOffset = NSSize(width: 0, height: -14)
NSGraphicsContext.saveGraphicsState()
dropShadow.set()
color(0x000000).setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
squircle.addClip()

// Sand fills the whole tile; the sea is drawn over its top part.
NSGradient(colors: [color(0xF8DDB0), color(0xEDBE84)])!.draw(in: body, angle: -90)

/// A wavy shoreline across the tile, `y` from the bottom of the body.
func shoreline(_ y: CGFloat, amplitude: CGFloat, phase: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: body.minX, y: body.maxY))
    path.line(to: NSPoint(x: body.minX, y: body.minY + y))
    let steps = 48
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = body.minX + t * body.width
        let wave = sin(t * .pi * 2.2 + phase) * amplitude + sin(t * .pi * 5.1 + phase * 1.7) * amplitude * 0.35
        path.line(to: NSPoint(x: x, y: body.minY + y + wave))
    }
    path.line(to: NSPoint(x: body.maxX, y: body.maxY))
    path.close()
    return path
}

// Wet sand left behind as the water pulls back.
color(0xD9A86E, 0.55).setFill()
shoreline(340, amplitude: 26, phase: 0.6).fill()

// The sea, deep at the top and turquoise near the shore.
let sea = shoreline(400, amplitude: 30, phase: 0.2)
NSGraphicsContext.saveGraphicsState()
sea.addClip()
NSGradient(colors: [color(0x0B2E6B), color(0x0F5FA8), color(0x1FB3C8), color(0x6FE0D8)],
           atLocations: [0, 0.4, 0.8, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
// Soft swells.
for (i, y) in [760, 640, 540].enumerated() {
    let swell = NSBezierPath()
    swell.lineWidth = 14
    swell.lineCapStyle = .round
    let width = body.width * (0.42 - CGFloat(i) * 0.06)
    let startX = body.minX + 120 + CGFloat(i) * 150
    swell.move(to: NSPoint(x: startX, y: CGFloat(y)))
    swell.curve(to: NSPoint(x: startX + width, y: CGFloat(y)),
                controlPoint1: NSPoint(x: startX + width * 0.3, y: CGFloat(y) + 26),
                controlPoint2: NSPoint(x: startX + width * 0.7, y: CGFloat(y) + 26))
    color(0xFFFFFF, 0.22).setStroke()
    swell.stroke()
}
NSGraphicsContext.restoreGraphicsState()

// Foam along the waterline.
let foam = NSBezierPath()
let steps = 64
for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps)
    let x = body.minX + t * body.width
    let y = body.minY + 400 + sin(t * .pi * 2.2 + 0.2) * 30 + sin(t * .pi * 5.1 + 0.34) * 10.5
    if i == 0 { foam.move(to: NSPoint(x: x, y: y)) } else { foam.line(to: NSPoint(x: x, y: y)) }
}
foam.lineWidth = 26
foam.lineCapStyle = .round
foam.lineJoinStyle = .round
color(0xFFFFFF, 0.95).setStroke()
foam.stroke()

// Files uncovered on the beach: rounded "documents" with a folded corner.
func document(at origin: NSPoint, size: CGFloat, tint: NSColor, angle: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: origin.x, yBy: origin.y)
    transform.rotate(byDegrees: angle)
    transform.concat()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x7A4A1C, 0.35)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    let rect = NSRect(x: -size * 0.4, y: -size / 2, width: size * 0.8, height: size)
    let page = NSBezierPath(roundedRect: rect, xRadius: size * 0.1, yRadius: size * 0.1)
    color(0xFFFFFF).setFill()
    page.fill()
    NSShadow().set()
    let band = NSBezierPath(roundedRect: NSRect(x: rect.minX + size * 0.12, y: rect.maxY - size * 0.34,
                                                width: rect.width - size * 0.24, height: size * 0.14),
                            xRadius: size * 0.05, yRadius: size * 0.05)
    tint.setFill()
    band.fill()
    for line in 0..<2 {
        let bar = NSRect(x: rect.minX + size * 0.12, y: rect.minY + size * (0.18 + CGFloat(line) * 0.16),
                         width: (rect.width - size * 0.24) * (line == 0 ? 0.7 : 1), height: size * 0.07)
        color(0xD7DCE3).setFill()
        NSBezierPath(roundedRect: bar, xRadius: size * 0.035, yRadius: size * 0.035).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}
document(at: NSPoint(x: 330, y: 250), size: 150, tint: color(0x1FB3C8), angle: 12)
document(at: NSPoint(x: 540, y: 205), size: 118, tint: color(0xF2785C), angle: -8)
document(at: NSPoint(x: 720, y: 262), size: 96, tint: color(0x7C6CF0), angle: 18)

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
