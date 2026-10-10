import Foundation
import Sparkle

/// Automatic updates with Sparkle. The feed (SUFeedURL) and public key
/// (SUPublicEDKey) are in Info.plist; release.sh signs each .dmg and writes
/// releases/appcast.xml next to latest.json.
///
/// Updates Sparkle installs aren't quarantined, so unlike a fresh download
/// they open without the "Open Anyway" step.
@MainActor
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // A packaged app has a feed URL; `swift run` doesn't, so skip there.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: self)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // LiveWall is a menu-bar app with no Dock icon, so let Sparkle remind
    // gently (it brings its window forward when the user looks) rather than
    // popping up over whatever they're doing.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
