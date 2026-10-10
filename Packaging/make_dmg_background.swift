// Draws the background of the installer window that opens with the .dmg:
// a title, an arrow from the app to Applications (Finder places the two
// icons on top, at the positions release.sh passes to create-dmg), and the
// three install steps — including the one-time "Open Anyway", which is where
// people get stuck with an unsigned app.
//
//   swift Packaging/make_dmg_background.swift <out.png> <out@2x.png>
import AppKit
import CoreImage

let size = NSSize(width: 660, height: 440)
// Icon centres, in points from the top-left — keep in sync with release.sh.
let appCentre = NSPoint(x: 170, y: 175)
let applicationsCentre = NSPoint(x: 490, y: 175)

let ink = NSColor(srgbRed: 0.10, green: 0.07, blue: 0.02, alpha: 1)
let muted = NSColor(white: 1, alpha: 0.6)
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

/// The website hero's glow (`.glow-bands` in web/public/landing.css, and
/// `GlowBands` in the app's welcome): soft amber bands lying diagonally
/// across black, fading out towards the edges.
func glowBands(_ bounds: NSRect, scale: CGFloat) -> CGImage? {
    let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    let period = max(bounds.width, bounds.height) * 0.26
    let reach = hypot(bounds.width, bounds.height)
    let colors = [
        NSColor.clear, accent.withAlphaComponent(0.85),
        NSColor(srgbRed: 1.0, green: 0.77, blue: 0.43, alpha: 0.95),
        NSColor(srgbRed: 0.84, green: 0.36, blue: 0.12, alpha: 0.8), NSColor.clear,
    ].map(\.cgColor) as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                              locations: [0, 0.25, 0.44, 0.66, 1])!
    ctx.translateBy(x: bounds.width / 2, y: bounds.height / 2)
    ctx.rotate(by: -.pi / 4)
    var x = -reach / 2 - period * 0.4
    while x < reach / 2 + period {
        let band = CGRect(x: x + period * 0.233, y: -reach / 2, width: period * 0.533, height: reach)
        ctx.saveGState()
        ctx.clip(to: band)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: band.minX, y: 0), end: CGPoint(x: band.maxX, y: 0), options: [])
        ctx.restoreGState()
        x += period
    }
    guard let sharp = ctx.makeImage() else { return nil }
    // Blur, then fade towards the edges with a radial mask.
    let image = CIImage(cgImage: sharp).clampedToExtent()
        .applyingGaussianBlur(sigma: Double(period * 0.09 * scale))
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let mask = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": CIVector(x: CGFloat(width) * 0.5, y: CGFloat(height) * 0.6),
        "inputRadius0": CGFloat(width) * 0.08, "inputRadius1": CGFloat(width) * 0.42,
        "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
        "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
    ])!.outputImage!.cropped(to: image.extent)
    let faded = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
        kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
        kCIInputMaskImageKey: mask,
    ])
    return CIContext().createCGImage(faded, from: faded.extent)
}

func drawing(scale: CGFloat) -> NSImage {
    NSImage(size: size, flipped: true) { bounds in
        // Black stage with the amber glow behind the two icons.
        NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1).setFill()
        bounds.fill()
        if let glow = glowBands(bounds, scale: scale) {
            NSImage(cgImage: glow, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver,
                                                           fraction: 0.85, respectFlipped: true, hints: nil)
        }

        // Title.
        text("Install LiveWall", size: 22, weight: .bold, color: .white)
            .draw(in: NSRect(x: 0, y: 26, width: bounds.width, height: 30))
        text("Drag LiveWall into your Applications folder", size: 13, weight: .regular, color: muted)
            .draw(in: NSRect(x: 0, y: 58, width: bounds.width, height: 20))

        // Finder draws the icon names in dark text on a picture background,
        // even in Dark Mode, so each name sits on a light plate.
        for centre in [appCentre, applicationsCentre] {
            let plate = NSRect(x: centre.x - 58, y: centre.y + 61, width: 116, height: 22)
            NSColor(white: 1, alpha: 0.88).setFill()
            NSBezierPath(roundedRect: plate, xRadius: 11, yRadius: 11).fill()
        }

        // Arrow from the app to Applications: a line of light that fades in
        // from the app and ends in a crisp arrowhead at the folder.
        let lineY = appCentre.y
        let lineStart = appCentre.x + 70, tip = applicationsCentre.x - 76
        let line = NSBezierPath(roundedRect: NSRect(x: lineStart, y: lineY - 1.25, width: tip - lineStart - 1, height: 2.5),
                                xRadius: 1.25, yRadius: 1.25)
        NSGradient(colorsAndLocations: (accent.withAlphaComponent(0), 0), (accent, 0.45), (NSColor.white, 1))!
            .draw(in: line, angle: 0)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accent.withAlphaComponent(0.8)
        glow.shadowBlurRadius = 10
        glow.set()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: tip - 11, y: lineY - 10))
        head.line(to: NSPoint(x: tip, y: lineY))
        head.line(to: NSPoint(x: tip - 11, y: lineY + 10))
        head.lineWidth = 2.5
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        NSColor.white.setStroke()
        head.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Steps card: dark glass.
        let card = NSRect(x: 28, y: 292, width: bounds.width - 56, height: 120)
        NSColor(white: 0.08, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16).fill()
        NSColor(white: 1, alpha: 0.1).setStroke()
        let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        outline.lineWidth = 1
        outline.stroke()

        let steps: [(String, String)] = [
            ("Drag to Applications", "Drop LiveWall on the folder above."),
            ("Open LiveWall", "Find it in Applications. A short welcome sets it up."),
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
            text(step.0, size: 13, weight: .semibold, color: .white)
                .draw(in: NSRect(x: x + 6, y: card.minY + 50, width: column - 12, height: 18))
            text(step.1, size: 11, weight: .regular, color: muted)
                .draw(in: NSRect(x: x + 6, y: card.minY + 70, width: column - 12, height: 34))
        }
        return true
    }
}

func write(scale: CGFloat, to path: String) {
    let image = drawing(scale: scale)
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
write(scale: 1, to: args[1])
write(scale: 2, to: args[2])
