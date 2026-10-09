// Cuts a wallpaper clip out of a (local or remote) source video and writes the
// three files the gallery needs: a 4K HEVC download, a short, small H.264
// hover preview, and a JPEG poster. Audio is dropped. Remote sources are read with
// HTTP range requests, so only the requested stretch is downloaded.
//
//   swift clip.swift <source-url> <start-seconds> <duration> <out-dir> <id>
import AVFoundation
import AppKit

let args = CommandLine.arguments
guard args.count == 6, let start = Double(args[2]), let length = Double(args[3]) else {
    print("usage: clip.swift <source-url> <start-seconds> <duration> <out-dir> <id>"); exit(1)
}
let source = args[1].hasPrefix("http") ? URL(string: args[1])! : URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[4], isDirectory: true)
let id = args[5]

func export(_ asset: AVAsset, preset: String, type: AVFileType, to url: URL) async throws {
    try? FileManager.default.removeItem(at: url)
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
        throw NSError(domain: "clip", code: 1, userInfo: [NSLocalizedDescriptionKey: "preset \(preset) unavailable"])
    }
    try await session.export(to: url, as: type)
}

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "clip", code: 2) }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: length, preferredTimescale: 600))

        // Video-only composition of just the chosen stretch.
        let comp = AVMutableComposition()
        let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try vt.insertTimeRange(range, of: track, at: .zero)
        vt.preferredTransform = try await track.load(.preferredTransform)

        let full = outDir.appendingPathComponent("\(id).mp4")
        let preview = outDir.appendingPathComponent("\(id)-preview.mp4")
        let poster = outDir.appendingPathComponent("\(id).jpg")
        try await export(comp, preset: AVAssetExportPresetHEVC3840x2160, type: .mp4, to: full)
        // The hover preview is a short, small H.264 snippet (plays in every
        // browser, costs little bandwidth); the download is the full clip.
        let snippet = AVMutableComposition()
        let st = snippet.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try st.insertTimeRange(CMTimeRange(start: range.start, duration: CMTime(seconds: min(8, length), preferredTimescale: 600)),
                               of: track, at: .zero)
        st.preferredTransform = vt.preferredTransform
        try await export(snippet, preset: AVAssetExportPreset640x480, type: .mp4, to: preview)

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: full))
        gen.maximumSize = CGSize(width: 1280, height: 720)
        let cg = try await gen.image(at: CMTime(seconds: min(2, length / 2), preferredTimescale: 600)).image
        let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
        try jpeg.write(to: poster)

        let size = { (u: URL) in ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0) / 1_000_000 }
        print("\(id): full \(size(full))MB, preview \(size(preview))MB")
    } catch {
        print("\(id): FAILED \(error.localizedDescription)")
    }
    sem.signal()
}
sem.wait()
