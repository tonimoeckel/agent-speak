// Erzeugt das App-Icon als .iconset: swift scripts/make-icon.swift <ziel.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.16, green: 0.17, blue: 0.24, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))!.draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    path.lineWidth = max(1, s * 0.006)
    path.stroke()
    // Schallwellen-Balken
    let heights: [CGFloat] = [0.22, 0.42, 0.62, 0.42, 0.22]
    let barW = rect.width * 0.085, gap = rect.width * 0.06
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    let accent = NSColor(red: 0.45, green: 0.62, blue: 1.0, alpha: 1)
    for (i, h) in heights.enumerated() {
        let bh = rect.height * h
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh),
                               xRadius: barW / 2, yRadius: barW / 2)
        (i == 2 ? accent : NSColor.white).setFill()
        bar.fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
