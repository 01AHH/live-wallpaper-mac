import SwiftUI
import ServiceManagement

/// Every preference in one place: appearance, how wallpapers play, power
/// saving, the Dynamic Island and the app itself. Opened from the menu bar
/// (⌘,) or the library's toolbar.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onCheckForUpdates: () -> Void
    let onShowWelcome: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("The welcome, the Dynamic Island and controls over video stay dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Wallpaper") {
                LabeledContent("Library folder") {
                    Button(settings.libraryFolder?.lastPathComponent ?? "Choose…", action: chooseFolder)
                }
                .help(settings.libraryFolder?.path ?? "")
                Picker("Scaling", selection: $settings.fillMode) {
                    ForEach(FillMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Span one video across every display", isOn: $settings.spanScreens)
            }

            Section("Power Saving") {
                Toggle("Pause on battery", isOn: $settings.pauseOnBattery)
                Toggle("Pause in Low Power Mode", isOn: $settings.pauseInLowPower)
                Toggle("Pause when your Mac is hot", isOn: $settings.pauseWhenHot)
            }

            Section("Dynamic Island") {
                Toggle("Show Dynamic Island", isOn: $settings.showIsland)
                ForEach(IslandSource.allCases) { source in
                    Toggle(isOn: Binding(
                        get: { settings.islandSources.contains(source) },
                        set: { on in
                            if on { settings.islandSources.insert(source) } else { settings.islandSources.remove(source) }
                        })) {
                        Label(source.label, systemImage: source.icon)
                    }
                    .disabled(!settings.showIsland)
                }
                if !ChatAppWatcher.isTrusted {
                    Button("Allow Accessibility for ChatGPT & Claude chats…") {
                        ChatAppWatcher.requestPermission()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                LabeledContent("Updates") {
                    Button("Check Now", action: onCheckForUpdates)
                }
                LabeledContent("Welcome") {
                    Button("Show Again", action: onShowWelcome)
                }
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
            }
        }
        .formStyle(.grouped)
        .tint(Brand.accent)
        .frame(width: 500)
        .frame(minHeight: 480)
        // Launch at login can also change in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LiveWall: launch at login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryFolder = url
        }
    }
}
