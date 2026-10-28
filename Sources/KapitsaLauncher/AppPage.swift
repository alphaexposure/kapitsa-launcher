import ServiceManagement
import SwiftUI

/// Launcher preferences: appearance and launch at login.
struct AppPage: View {
    @AppStorage("KapitsaLauncher.appearance") private var appearance = "system"
    @AppStorage("KapitsaLauncher.skipModelSwitchConfirmation") private var skipModelSwitchConfirmation = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    /// Launch at login needs a real .app bundle (not `swift run`).
    private let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel("Preferences", symbol: "gearshape") {
                HStack {
                    SettingLabel("Appearance", defaultValue: "Follow macOS",
                                 helpText: "Choose a light or dark look, or follow your Mac's appearance setting.")
                    Picker("Appearance", selection: $appearance) {
                        Text("Follow macOS").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden().frame(width: 230)
                    .accessibilityLabel("Appearance")
                }
                HStack {
                    SettingLabel("Launch at login", helpText: "Opens Kapitsa Launcher when you sign in to macOS. It does not automatically start the Kapitsa server.")
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Launch at login")
                        .disabled(!isAppBundle)
                        .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                }
                HStack {
                    SettingLabel("Ask before switching models", helpText: "When you choose another model while Kapitsa runs, ask first, since it restarts Kapitsa. Turned off by \"Don't ask again\" in that question.")
                    Toggle("", isOn: Binding(get: { !skipModelSwitchConfirmation }, set: { skipModelSwitchConfirmation = !$0 }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Ask before switching models")
                }
                if !isAppBundle {
                    Text("Launch at login is available from an installed .app bundle.")
                        .foregroundStyle(.secondary)
                }
                if let loginItemError { Text(loginItemError).foregroundStyle(.red) }
            }
        }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
