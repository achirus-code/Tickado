// Erzeugt das App-Icon: swift Scripts/make-icon.swift Resources/AppIcon.icns [preview.png]
// Motiv: Kerzen-Chart in den Ticker-Farben (#74C73D / #C04828) und eine goldene Münze.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let preview = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Tickado.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(displayP3Red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let green = color(0x74C73D)
let red = color(0xC04828)

// Zeichnet im 1024er-Raster (Inhalt 824 × 824 wie bei macOS-Icons).
func draw() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // Schatten unter der Kachel
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x151A24).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x2B3345), color(0x161B26), color(0x0C0F15)])!.draw(in: tile, angle: -90)

    // Feines Raster wie in einer Chart-Ansicht
    color(0xFFFFFF, 0.05).setStroke()
    for y in stride(from: 250.0, through: 800, by: 110) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 100, y: y))
        line.line(to: NSPoint(x: 924, y: y))
        line.lineWidth = 3
        line.stroke()
    }

    // Kerzen: (x, open, close, low, high) – überwiegend steigend, über die ganze Breite
    let candles: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (215, 250, 330, 215, 360),
        (325, 330, 290, 255, 370),
        (435, 290, 420, 265, 450),
        (545, 420, 385, 350, 455),
        (655, 385, 520, 365, 555),
        (765, 520, 640, 490, 670),
    ]
    let bodyWidth: CGFloat = 76
    for (x, open, close, low, high) in candles {
        let c = close >= open ? green : red
        c.setStroke()
        let wick = NSBezierPath()
        wick.move(to: NSPoint(x: x, y: low))
        wick.line(to: NSPoint(x: x, y: high))
        wick.lineWidth = 12
        wick.lineCapStyle = .round
        wick.stroke()

        let body = NSRect(x: x - bodyWidth / 2, y: min(open, close), width: bodyWidth, height: abs(close - open))
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 13, yRadius: 13)
        NSGradient(starting: c.blended(withFraction: 0.2, of: .white)!, ending: c)!.draw(in: bodyPath, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Goldene Münze oben links, über den ersten Kerzen
    let coin = NSRect(x: 180, y: 560, width: 250, height: 250)
    NSGraphicsContext.saveGraphicsState()
    let coinShadow = NSShadow()
    coinShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    coinShadow.shadowBlurRadius = 26
    coinShadow.shadowOffset = NSSize(width: 0, height: -12)
    coinShadow.set()
    color(0xD8901A).setFill()
    NSBezierPath(ovalIn: coin).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0xFFE38F), ending: color(0xD48A16))!.draw(in: NSBezierPath(ovalIn: coin), angle: -55)
    let face = coin.insetBy(dx: 24, dy: 24)
    NSGradient(starting: color(0xE39B20), ending: color(0xFBD066))!.draw(in: NSBezierPath(ovalIn: face), angle: -55)
    let rim = NSBezierPath(ovalIn: face)
    rim.lineWidth = 6
    color(0xB0700C, 0.7).setStroke()
    rim.stroke()

    // Eingeprägte Mini-Kurve mit Pfeilspitze
    let ink = color(0x7A4A05)
    let cx = coin.midX, cy = coin.midY
    let pts = [NSPoint(x: cx - 62, y: cy - 38), NSPoint(x: cx - 18, y: cy + 8),
               NSPoint(x: cx + 10, y: cy - 16), NSPoint(x: cx + 52, y: cy + 30)]
    let zig = NSBezierPath()
    zig.move(to: pts[0])
    pts.dropFirst().forEach { zig.line(to: $0) }
    zig.lineWidth = 20
    zig.lineCapStyle = .round
    zig.lineJoinStyle = .round
    ink.setStroke()
    zig.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: cx + 74, y: cy + 54))
    head.line(to: NSPoint(x: cx + 24, y: cy + 46))
    head.line(to: NSPoint(x: cx + 66, y: cy + 4))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 8
    ink.setFill()
    head.fill()
    head.stroke()
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try png(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
if let preview { try png(1024).write(to: preview) }

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print("Icon: \(output.path)")
