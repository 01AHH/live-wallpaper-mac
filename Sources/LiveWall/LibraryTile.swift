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

/// A library tile in the style of Apple's media apps: clean 16:9 artwork with
/// the title beneath it. At rest it's completely still — hover lifts and tilts
/// it toward the cursor and starts a live preview; the playing wallpaper wears
/// the brand ring.
struct VideoTile: View {
    let url: URL
    let isSelected: Bool
    /// This wallpaper's playback speed; previews match it, and a non-default
    /// speed is shown beside the title.
    var speed: Double = 1
    /// Position in the grid, used to stagger the first screenful's entrance.
    var index: Int = 0
    var onSelect: () -> Void = {}

    @State private var image: NSImage?
    @State private var hover: UnitPoint?
    @State private var showPreview = false
    @State private var appeared = false
    @State private var pressed = false

    private let shape = RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
    private var isHovering: Bool { hover != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card
            title
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            // Only the first screenful animates in. Tiles revealed by
            // scrolling simply appear — animating them is what made
            // scrolling feel heavy.
            guard index < 16 else { appeared = true; return }
            withAnimation(Brand.spring.delay(Double(index) * 0.03)) { appeared = true }
        }
        .task(id: url) { image = await ThumbnailCache.image(for: url) }
        .help(url.wallpaperName)
    }

    private var card: some View {
        ZStack {
            artwork
            SpecularHighlight(point: hover)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.08), lineWidth: 1) }
        .padding(isSelected ? 4 : 0)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Brand.Radius.tile + 4, style: .continuous)
                    .strokeBorder(Brand.accent, lineWidth: 2.5)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if isSelected { playingBadge.padding(14) }
        }
        // Shadow only while lifted; dozens of resting blurred shadows are
        // expensive to composite during a scroll.
        .shadow(color: .black.opacity(isHovering ? 0.4 : 0), radius: 20, y: 12)
        .scaleEffect(pressed ? 0.97 : isHovering ? 1.03 : 1)
        .tilt(toward: hover, maxAngle: 5)
        .zIndex(isHovering ? 1 : 0)
        .animation(Brand.spring, value: isHovering)
        .animation(Brand.spring, value: isSelected)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
        .contentShape(shape)
        .trackHover($hover)
        .onTapGesture {
            pressed = true
            onSelect()
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                pressed = false
            }
        }
        // Wait a beat before spinning up a player, so sweeping the mouse
        // across the grid doesn't start a dozen decoders.
        .task(id: isHovering) {
            if isHovering {
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { withAnimation(.easeIn(duration: 0.3)) { showPreview = true } }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { showPreview = false }
            }
        }
    }

    private var artwork: some View {
        // Color.clear fixes the size; an aspect-fill image laid out directly
        // would push the tile past its 16:9 frame.
        Color.clear.overlay {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Rectangle().fill(.white.opacity(0.06))
            }
            if showPreview {
                LoopingVideoView(url: url, rate: speed).transition(.opacity)
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.3), value: image != nil)
    }

    private var title: some View {
        HStack(spacing: 6) {
            Text(url.wallpaperName)
                .foregroundStyle(isSelected ? Brand.accent : .primary)
                .lineLimit(1)
            if speed != 1 {
                Spacer(minLength: 0)
                Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(Brand.Font.tileTitle)
        .padding(.horizontal, 2)
    }

    private var playingBadge: some View {
        Label("Playing", systemImage: "waveform")
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !isHovering)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Brand.accent, in: .capsule)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}
