import SwiftUI
import AVFoundation

extension URL {
    /// "abandoned-train-station.mp4" → "Abandoned train station"
    var wallpaperName: String {
        let raw = deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

/// A stable colour per tag name, so a tag looks the same everywhere and
/// across launches (String.hashValue is randomised per process).
enum TagPalette {
    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .mint, .cyan, .red]

    static func color(for tag: String) -> Color {
        let sum = tag.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 31 }
        return colors[abs(sum) % colors.count]
    }
}

/// A small coloured capsule naming a tag.
struct TagChip: View {
    let tag: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(TagPalette.color(for: tag)).frame(width: 6, height: 6)
            Text(tag)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Thumbnails are expensive to generate, so keep them for the app's lifetime
/// instead of regenerating every time a filter or search changes the grid.
@MainActor
enum ThumbnailCache {
    private static var images: [URL: NSImage] = [:]

    static func image(for url: URL) async -> NSImage? {
        if let cached = images[url] { return cached }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        guard let cg = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else {
            return nil
        }
        let image = NSImage(cgImage: cg, size: .zero)
        images[url] = image
        return image
    }
}

/// A single library tile: a 16:9 thumbnail that leans toward the cursor in
/// 3D with a moving highlight, comes alive with a looping preview on hover,
/// ripples where you click, and wears an orbiting neon border while playing.
struct VideoTile: View {
    let url: URL
    let isSelected: Bool
    var tags: [String] = []
    /// Position in the grid, used to stagger the entrance animation.
    var index: Int = 0
    var onSelect: () -> Void = {}

    @State private var image: NSImage?
    @State private var hover: UnitPoint?
    @State private var showPreview = false
    @State private var appeared = false
    @State private var ripples: [Ripple] = []

    private struct Ripple: Identifiable {
        let id = UUID()
        let center: CGPoint
    }

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    private var isHovering: Bool { hover != nil }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork
            scrim
            caption
            SpecularHighlight(point: hover)
            rippleLayer
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay {
            if isSelected {
                GlowBorder(shape: shape).transition(.opacity)
            } else {
                shape.strokeBorder(.white.opacity(isHovering ? 0.25 : 0.08), lineWidth: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelected { playingBadge.padding(10) }
        }
        .shadow(color: .black.opacity(isHovering ? 0.45 : 0.18),
                radius: isHovering ? 24 : 8, y: isHovering ? 16 : 4)
        .scaleEffect(isHovering ? 1.04 : 1)
        .tilt(toward: hover, maxAngle: 7)
        .zIndex(isHovering ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHovering)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isSelected)
        .contentShape(shape)
        .trackHover($hover)
        .gesture(SpatialTapGesture().onEnded { value in
            let ripple = Ripple(center: value.location)
            ripples.append(ripple)
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                ripples.removeAll { $0.id == ripple.id }
            }
            onSelect()
        })
        // Staggered entrance: rise, sharpen and fade in.
        .opacity(appeared ? 1 : 0)
        .blur(radius: appeared ? 0 : 10)
        .offset(y: appeared ? 0 : 40)
        .onAppear {
            let delay = index < 15 ? Double(index) * 0.04 : 0
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(delay)) { appeared = true }
        }
        // Wait a beat before spinning up a player, so sweeping the mouse
        // across the grid doesn't start a dozen decoders.
        .task(id: isHovering) {
            if isHovering {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { withAnimation(.easeIn(duration: 0.3)) { showPreview = true } }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { showPreview = false }
            }
        }
        .task(id: url) { image = await ThumbnailCache.image(for: url) }
        .help(url.lastPathComponent)
    }

    private var artwork: some View {
        Color.clear.overlay {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Shimmer()
            }
            if showPreview {
                LoopingVideoView(url: url).transition(.opacity)
            }
        }
        .clipped()
        // Slow zoom on hover, like a film still pushing in.
        .scaleEffect(isHovering ? 1.08 : 1)
        .animation(.easeOut(duration: 1.2), value: isHovering)
        .animation(.easeOut(duration: 0.4), value: image != nil)
    }

    private var scrim: some View {
        LinearGradient(colors: [.clear, .black.opacity(0.75)],
                       startPoint: .center, endPoint: .bottom)
            .allowsHitTesting(false)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(3), id: \.self) { TagChip(tag: $0) }
                    if tags.count > 3 {
                        Text("+\(tags.count - 3)").font(.caption2.weight(.medium))
                    }
                }
                .environment(\.colorScheme, .dark)
            }
            Text(url.wallpaperName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(12)
        .offset(y: isHovering ? -2 : 0)
    }

    private var rippleLayer: some View {
        ZStack {
            ForEach(ripples) { ripple in
                RippleRing().position(ripple.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var playingBadge: some View {
        Label("Playing", systemImage: "waveform")
            .symbolEffect(.variableColor.iterative, options: .repeating)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(.accentColor.opacity(0.5)), in: .capsule)
            .environment(\.colorScheme, .dark)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

/// One expanding, fading ring from a click point.
private struct RippleRing: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(expanded ? 0 : 0.35))
            Circle().strokeBorder(.white.opacity(expanded ? 0 : 0.8), lineWidth: 2)
        }
        .frame(width: 40, height: 40)
        .scaleEffect(expanded ? 14 : 0.2)
        .blendMode(.plusLighter)
        .onAppear { withAnimation(.easeOut(duration: 0.85)) { expanded = true } }
    }
}
