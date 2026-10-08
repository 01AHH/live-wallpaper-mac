import SwiftUI

// MARK: - Ambient palette

/// Pulls a 3×3 grid of colours out of a wallpaper frame, deepened so white
/// text stays readable on top. Feeds the window's living mesh background.
enum AmbientPalette {
    static let fallback: [Color] = ([
        .indigo, .purple, .blue,
        .purple, .black, .indigo,
        .blue, .indigo, .black,
    ] as [Color]).map { $0.opacity(0.9) }

    static func colors(from image: NSImage) -> [Color] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        var pixels = [UInt8](repeating: 0, count: 3 * 3 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 3, height: 3,
                                      bitsPerComponent: 8, bytesPerRow: 12,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 3, height: 3))
            return true
        }
        guard drawn else { return fallback }

        return (0..<9).map { i in
            let ns = NSColor(srgbRed: CGFloat(pixels[i * 4]) / 255,
                             green: CGFloat(pixels[i * 4 + 1]) / 255,
                             blue: CGFloat(pixels[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(hue: h, saturation: min(s * 1.35, 1), brightness: min(max(b * 0.75, 0.12), 0.6))
        }
    }
}

/// A slowly breathing mesh gradient — the "aurora" behind the whole window.
struct AmbientBackground: View {
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            // Keep t small: Float loses sub-second precision on raw dates.
            let t = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors)
        }
        .overlay(Color.black.opacity(0.3))
    }

    private func points(_ t: Float) -> [SIMD2<Float>] {
        [
            [0, 0], [0.5 + 0.2 * sin(t * 0.31), 0], [1, 0],
            [0, 0.5 + 0.2 * sin(t * 0.27 + 1)],
            [0.5 + 0.18 * sin(t * 0.43 + 2), 0.5 + 0.18 * cos(t * 0.37)],
            [1, 0.5 + 0.2 * cos(t * 0.29 + 3)],
            [0, 1], [0.5 + 0.2 * cos(t * 0.33 + 4), 1], [1, 1],
        ]
    }
}

// MARK: - Text

/// Reveals text glyph by glyph: each one rises, sharpens out of a blur and
/// fades in, staggered left to right. Animate `progress` from 0 to 1.
struct BlurRevealRenderer: TextRenderer, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run.map { $0 } } }
        let count = Double(max(slices.count, 1))
        for (i, slice) in slices.enumerated() {
            let start = Double(i) / count * 0.55
            let p = min(max((progress - start) / 0.45, 0), 1)
            let eased = 1 - pow(1 - p, 3)
            var copy = ctx
            copy.opacity = eased
            copy.addFilter(.blur(radius: (1 - eased) * 12))
            copy.translateBy(x: 0, y: (1 - eased) * 18)
            copy.draw(slice)
        }
    }
}

// MARK: - Hover physics

/// Tracks the cursor over a view as a unit point (0…1 in each axis), or nil
/// when it's elsewhere. Drives tilt and specular highlights.
struct HoverTracker: ViewModifier {
    @Binding var point: UnitPoint?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location) where size.width > 0 && size.height > 0:
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.75)) {
                        point = UnitPoint(x: location.x / size.width, y: location.y / size.height)
                    }
                default:
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { point = nil }
                }
            }
    }
}

extension View {
    func trackHover(_ point: Binding<UnitPoint?>) -> some View {
        modifier(HoverTracker(point: point))
    }

    /// Leans the view toward the cursor in 3D, like a card on a table.
    func tilt(toward point: UnitPoint?, maxAngle: Double = 8) -> some View {
        modifier(TiltModifier(point: point, maxAngle: maxAngle))
    }
}

private struct TiltModifier: ViewModifier {
    let point: UnitPoint?
    let maxAngle: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let dx = reduceMotion ? 0 : ((point?.x ?? 0.5) - 0.5) * 2
        let dy = reduceMotion ? 0 : ((point?.y ?? 0.5) - 0.5) * 2
        content
            .rotation3DEffect(.degrees(dy * maxAngle), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(-dx * maxAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
    }
}

/// A soft light that follows the cursor across a surface. Clip it with the
/// surface's shape.
struct SpecularHighlight: View {
    let point: UnitPoint?

    var body: some View {
        GeometryReader { geo in
            RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0.06), .clear],
                           center: point ?? .center, startRadius: 0,
                           endRadius: max(geo.size.width, geo.size.height) * 0.65)
                .blendMode(.plusLighter)
                .opacity(point == nil ? 0 : 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Borders & loading

/// A neon border whose colours orbit the shape, with a bloom behind it.
struct GlowBorder<S: InsettableShape>: View {
    let shape: S
    var lineWidth: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let angle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
            let gradient = AngularGradient(
                colors: [.accentColor, .purple, .pink, .orange, .yellow, .mint, .accentColor],
                center: .center, angle: .degrees(angle))
            ZStack {
                shape.strokeBorder(gradient, lineWidth: lineWidth * 3).blur(radius: 12).opacity(0.85)
                shape.strokeBorder(gradient, lineWidth: lineWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A light sweep across a placeholder while its content loads.
struct Shimmer: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let p = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let x = -0.6 + p * 2.2
            LinearGradient(colors: [.clear, .white.opacity(0.14), .clear],
                           startPoint: UnitPoint(x: x - 0.4, y: 0.2),
                           endPoint: UnitPoint(x: x + 0.4, y: 0.8))
        }
        .background(.quaternary)
        .allowsHitTesting(false)
    }
}

// MARK: - Display preview

/// A miniature of the real monitor arrangement showing exactly how the
/// current fill mode and span setting will lay the wallpaper out.
struct DisplayPreview: View {
    let poster: NSImage?
    let mode: FillMode
    let span: Bool

    var body: some View {
        let screens = NSScreen.screens.map(\.frame)
        let union = screens.reduce(CGRect.null) { $0.union($1) }

        GeometryReader { geo in
            let standHeight: CGFloat = 10
            let avail = CGSize(width: geo.size.width, height: geo.size.height - standHeight)
            let scale = min(avail.width / union.width, avail.height / union.height)
            let origin = CGPoint(x: (avail.width - union.width * scale) / 2,
                                 y: (avail.height - union.height * scale) / 2)
            // Screen frames are y-up; flip into SwiftUI's y-down space.
            let rects = screens.map { s in
                CGRect(x: origin.x + (s.minX - union.minX) * scale,
                       y: origin.y + (union.maxY - s.maxY) * scale,
                       width: s.width * scale, height: s.height * scale)
            }
            let canvas = CGRect(origin: origin, size: CGSize(width: union.width * scale,
                                                             height: union.height * scale))

            ZStack(alignment: .topLeading) {
                ForEach(rects.indices, id: \.self) { i in
                    monitor(rect: rects[i], canvas: span ? canvas : rects[i])
                }
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: mode)
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: span)
    }

    private func monitor(rect: CGRect, canvas: CGRect) -> some View {
        let screen = rect.insetBy(dx: 3, dy: 0)
        let content = poster?.size ?? CGSize(width: 16, height: 9)
        let video = videoRect(content: content, in: canvas, mode: mode)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.black
                if let poster {
                    Image(nsImage: poster)
                        .resizable()
                        .frame(width: video.width, height: video.height)
                        .offset(x: video.minX - screen.minX, y: video.minY - screen.minY)
                }
            }
            .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.35), lineWidth: 1.5) }

            // A little monitor stand.
            Rectangle()
                .fill(.white.opacity(0.25))
                .frame(width: screen.width * 0.12, height: 8)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2))
        }
        .offset(x: screen.minX, y: screen.minY)
    }
}
