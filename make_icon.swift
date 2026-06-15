import AppKit

let size: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let cg = gctx.cgContext

// Rounded-square icon shape (macOS "squircle"-ish radius).
let margin = size * 0.065
let rect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius = (size - 2 * margin) * 0.2237
cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
cg.clip()

// Sky: warm gold at top fading to deep amber.
let space = CGColorSpaceCreateDeviceRGB()
let sky = CGGradient(colorsSpace: space, colors: [
    NSColor(srgbRed: 0.99, green: 0.85, blue: 0.46, alpha: 1).cgColor,
    NSColor(srgbRed: 0.93, green: 0.58, blue: 0.20, alpha: 1).cgColor
] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(sky, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Sun with a soft glow.
let sunC = CGPoint(x: size * 0.5, y: size * 0.60)
let sunR = size * 0.135
cg.setFillColor(NSColor(srgbRed: 1, green: 0.98, blue: 0.88, alpha: 0.35).cgColor)
cg.fillEllipse(in: CGRect(x: sunC.x - sunR * 1.6, y: sunC.y - sunR * 1.6, width: sunR * 3.2, height: sunR * 3.2))
cg.setFillColor(NSColor(srgbRed: 1, green: 0.98, blue: 0.90, alpha: 1).cgColor)
cg.fillEllipse(in: CGRect(x: sunC.x - sunR, y: sunC.y - sunR, width: sunR * 2, height: sunR * 2))

// Rolling field: two overlapping curved hills.
func hill(crest: CGFloat, color: NSColor) {
    cg.setFillColor(color.cgColor)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: margin, y: margin))
    p.addLine(to: CGPoint(x: margin, y: crest))
    p.addCurve(to: CGPoint(x: size - margin, y: crest),
               control1: CGPoint(x: size * 0.32, y: crest + size * 0.11),
               control2: CGPoint(x: size * 0.70, y: crest - size * 0.11))
    p.addLine(to: CGPoint(x: size - margin, y: margin))
    p.closeSubpath()
    cg.addPath(p)
    cg.fillPath()
}
hill(crest: size * 0.40, color: NSColor(srgbRed: 0.82, green: 0.47, blue: 0.15, alpha: 1))
hill(crest: size * 0.29, color: NSColor(srgbRed: 0.60, green: 0.33, blue: 0.10, alpha: 1))

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: "icon_1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
