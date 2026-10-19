// make_icon.swift: draws the icon of QuadCapture Panel and writes src/panel/AppIcon.icns.
// The icon is an original drawing (an audio interface with two knobs and a level meter). It does
// not use a logo or a trademark of Roland Corporation.
//   swift src/panel/make_icon.swift      (run it from the root of the repository)
import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024   // all values below are for a 1024 x 1024 canvas
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    // Body: the macOS icon grid (824 x 824, corner radius 185), with a soft shadow.
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.shadowBlurRadius = 28 * s
    shadow.set()
    color(0x1B1E23).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x3A3F47), ending: color(0x16181C))!.draw(in: body, angle: -90)

    // Front panel: a brushed-metal plate.
    let plate = NSBezierPath(roundedRect: r(168, 300, 688, 456), xRadius: 64 * s, yRadius: 64 * s)
    NSGradient(colors: [color(0xC9CDD3), color(0xA4A9B1), color(0x8C929B)])!.draw(in: plate, angle: -90)
    color(0xFFFFFF, 0.55).setStroke()
    plate.lineWidth = 3 * s
    plate.stroke()

    // Two knobs with a blue value ring and a pointer.
    for (cx, value) in [(CGFloat(352), CGFloat(0.62)), (CGFloat(672), CGFloat(0.38))] {
        let cy: CGFloat = 572
        let ringRadius: CGFloat = 122
        let track = NSBezierPath()
        track.appendArc(withCenter: NSPoint(x: cx * s, y: cy * s), radius: ringRadius * s, startAngle: 225, endAngle: -45, clockwise: true)
        track.lineWidth = 20 * s
        track.lineCapStyle = .round
        color(0x2A2E35, 0.35).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: cx * s, y: cy * s), radius: ringRadius * s, startAngle: 225,
                      endAngle: 225 - 270 * value, clockwise: true)
        arc.lineWidth = 20 * s
        arc.lineCapStyle = .round
        color(0x2F8CFF).setStroke()
        arc.stroke()

        let knob = NSBezierPath(ovalIn: r(cx - 92, cy - 92, 184, 184))
        NSGraphicsContext.saveGraphicsState()
        let ks = NSShadow()
        ks.shadowColor = NSColor.black.withAlphaComponent(0.45)
        ks.shadowOffset = NSSize(width: 0, height: -8 * s)
        ks.shadowBlurRadius = 14 * s
        ks.set()
        color(0x24272D).setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: color(0x4A5059), ending: color(0x1E2126))!.draw(in: knob, angle: -90)

        let angle = (225 - 270 * value) * .pi / 180
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: (cx + cos(angle) * 22) * s, y: (cy + sin(angle) * 22) * s))
        pointer.line(to: NSPoint(x: (cx + cos(angle) * 74) * s, y: (cy + sin(angle) * 74) * s))
        pointer.lineWidth = 16 * s
        pointer.lineCapStyle = .round
        NSColor.white.setStroke()
        pointer.stroke()
    }

    // Level meter: two rows of segments (green, yellow, red).
    let segments = 10
    for (row, lit) in [(0, 8), (1, 6)] {
        for i in 0..<segments {
            let x = 236 + CGFloat(i) * 56
            let y = 374 - CGFloat(row) * 42
            let seg = NSBezierPath(roundedRect: r(x, y, 44, 26), xRadius: 6 * s, yRadius: 6 * s)
            let c: UInt32 = i < 6 ? 0x34C759 : (i < 8 ? 0xFFCC00 : 0xFF3B30)
            color(c, i < lit ? 1 : 0.18).setFill()
            seg.fill()
        }
    }

    // Four input jacks below the plate ("quad").
    for i in 0..<4 {
        let cx = 302 + CGFloat(i) * 140
        let jack = NSBezierPath(ovalIn: r(cx - 34, 178, 68, 68))
        color(0x0E0F12).setFill()
        jack.fill()
        color(0x8C929B).setStroke()
        jack.lineWidth = 8 * s
        jack.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = FileManager.default.currentDirectoryPath
let iconset = NSTemporaryDirectory() + "QuadCapturePanel.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let png = drawIcon(size: CGFloat(px)).representation(using: .png, properties: [:])!
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: URL(fileURLWithPath: iconset + "/" + name))
    }
}
let preview = drawIcon(size: 1024).representation(using: .png, properties: [:])!
try preview.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "QuadCapturePanel-icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", root + "/src/panel/AppIcon.icns"]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote src/panel/AppIcon.icns (preview: \(NSTemporaryDirectory())QuadCapturePanel-icon.png)" : "iconutil failed")
