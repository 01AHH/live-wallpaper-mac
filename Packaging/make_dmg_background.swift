// Draws the background of the installer window that opens with the .dmg:
// a title, an arrow from the app to Applications (Finder places the two
// icons on top, at the positions release.sh passes to create-dmg), and the
// three install steps — including the one-time "Open Anyway", which is where
// people get stuck with an unsigned app.
//
//   swift Packaging/make_dmg_background.swift <out.png> <out@2x.png>
import AppKit

let size = NSSize(width: 660, height: 440)
// Icon centres, in points from the top-left — keep in sync with release.sh.
let appCentre = NSPoint(x: 170, y: 175)
let applicationsCentre = NSPoint(x: 490, y: 175)

let ink = NSColor(srgbRed: 0.10, green: 0.07, blue: 0.02, alpha: 1)
let muted = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.29, alpha: 1)
let accent = NSColor(srgbRed: 0.96, green: 0.62, blue: 0.22, alpha: 1)

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          align: NSTextAlignment = .center) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ])
}

let image = NSImage(size: size, flipped: true) { bounds in
    // Warm, quiet backdrop.
    NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.98, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.99, green: 0.93, blue: 0.84, alpha: 1),
    ])!.draw(in: bounds, angle: 90)

    // Title.
    text("Install LiveWall", size: 22, weight: .bold, color: ink)
        .draw(in: NSRect(x: 0, y: 26, width: bounds.width, height: 30))
    text("Drag LiveWall into your Applications folder", size: 13, weight: .regular, color: muted)
        .draw(in: NSRect(x: 0, y: 58, width: bounds.width, height: 20))

    // Arrow from the app to Applications.
    let start = NSPoint(x: appCentre.x + 78, y: appCentre.y)
    let end = NSPoint(x: applicationsCentre.x - 78, y: applicationsCentre.y)
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: NSPoint(x: end.x - 6, y: end.y))
    shaft.lineWidth = 4
    shaft.lineCapStyle = .round
    shaft.setLineDash([2, 10], count: 2, phase: 0)
    accent.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - 14, y: end.y - 11))
    head.line(to: NSPoint(x: end.x + 2, y: end.y))
    head.line(to: NSPoint(x: end.x - 14, y: end.y + 11))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Steps card.
    let card = NSRect(x: 28, y: 292, width: bounds.width - 56, height: 120)
    NSColor.white.withAlphaComponent(0.78).setFill()
    NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16).fill()
    NSColor(srgbRed: 0.10, green: 0.07, blue: 0.02, alpha: 0.07).setStroke()
    let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
    outline.lineWidth = 1
    outline.stroke()

    let steps: [(String, String)] = [
        ("Drag to Applications", "Drop LiveWall on the folder above."),
        ("Open LiveWall", "Find it in Applications. It lives in your menu bar."),
        ("First time only", "System Settings → Privacy & Security → Open Anyway."),
    ]
    let column = (card.width - 32) / 3
    for (index, step) in steps.enumerated() {
        let x = card.minX + 16 + CGFloat(index) * column
        // Numbered badge.
        let badge = NSRect(x: x + column / 2 - 13, y: card.minY + 16, width: 26, height: 26)
        accent.setFill()
        NSBezierPath(ovalIn: badge).fill()
        text("\(index + 1)", size: 13, weight: .bold, color: ink)
            .draw(in: NSRect(x: badge.minX, y: badge.minY + 4, width: badge.width, height: 18))
        text(step.0, size: 13, weight: .semibold, color: ink)
            .draw(in: NSRect(x: x + 6, y: card.minY + 50, width: column - 12, height: 18))
        text(step.1, size: 11, weight: .regular, color: muted)
            .draw(in: NSRect(x: x + 6, y: card.minY + 70, width: column - 12, height: 34))
    }
    return true
}

func write(_ image: NSImage, scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size   // points, so the @2x image carries 144 dpi
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
write(image, scale: 1, to: args[1])
write(image, scale: 2, to: args[2])
