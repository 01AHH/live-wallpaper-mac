import Foundation
import IOKit.ps

/// Watches the things that should make a wallpaper ease off: running on
/// battery, Low Power Mode, and the Mac getting hot. Every competitor offers
/// these; a live wallpaper that spins the fans or drains a laptop is the most
/// common complaint about them.
@MainActor
final class PowerMonitor {
    enum Condition: Equatable {
        case onBattery, lowPowerMode, hot
    }

    /// Called whenever any of the conditions change.
    var onChange: (() -> Void)?

    private(set) var isOnBattery = false
    private(set) var isLowPowerMode = false
    private(set) var isHot = false

    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()

        // Power source changes (plugging in / unplugging) arrive on the run loop.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func refresh() {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        let battery = type == kIOPMBatteryPowerKey
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        // .serious is where macOS itself starts throttling; ease off there.
        let thermal = ProcessInfo.processInfo.thermalState
        let hot = thermal == .serious || thermal == .critical

        guard battery != isOnBattery || lowPower != isLowPowerMode || hot != isHot else { return }
        isOnBattery = battery
        isLowPowerMode = lowPower
        isHot = hot
        NSLog("LiveWall: power — battery=\(battery) lowPower=\(lowPower) hot=\(hot)")
        onChange?()
    }
}
