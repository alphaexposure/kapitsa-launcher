import AppKit
import SwiftUI

private final class KapitsaAppCoordinator {
    static let shared = KapitsaAppCoordinator()
    weak var controller: KapitsaProcessController?
}

final class KapitsaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A packaged .app already gets its icon from Contents/Resources. When run unpackaged
        // (swift run), draw it from the shared mark instead of loading a resource file.
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.applicationIconImage = KapitsaMark.appIconImage()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Chats are saved in the background; finish those saves first.
        KapitsaChatStore.waitForWrites()
        guard let controller = KapitsaAppCoordinator.shared.controller else { return .terminateNow }
        let waiting = controller.stopBeforeQuit {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return waiting ? .terminateLater : .terminateNow
    }
}

@main
struct KapitsaLauncherApp: App {
    @NSApplicationDelegateAdaptor(KapitsaAppDelegate.self) private var appDelegate
    @AppStorage("KapitsaLauncher.appearance") private var appearance = "system"
    @StateObject private var controller: KapitsaProcessController
    @StateObject private var chats = KapitsaChatLibrary.standard

    /// The appearance chosen on the App page; nil follows macOS.
    private var colorScheme: ColorScheme? {
        switch appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    init() {
        let settings = KapitsaSettingsStore()
        let savedPath = settings.loadExecutablePath()
        let discovery = KapitsaExecutableDiscovery.filesystem
        let executable = savedPath.flatMap { discovery.discover(candidatePaths: [$0]) } ?? discovery.discover()
        let controller = KapitsaProcessController(
            configuration: settings.loadConfiguration(),
            executable: executable,
            settingsStore: settings
        )
        _controller = StateObject(wrappedValue: controller)
        KapitsaAppCoordinator.shared.controller = controller
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(controller: controller, chats: chats)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 1040, height: 790)
        MenuBarExtra {
            KapitsaMenuView(controller: controller)
                .preferredColorScheme(colorScheme)
        } label: {
            Image(nsImage: KapitsaMark.menuBarImage())
                .accessibilityLabel("Kapitsa Launcher")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct KapitsaMenuView: View {
    @ObservedObject var controller: KapitsaProcessController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Kapitsa Launcher")
            } icon: {
                KapitsaMarkShape().fill(KapitsaTheme.accent).frame(width: 20, height: 20)
            }
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(KapitsaTheme.accent)
            Text("Process: \(controller.isStopping ? "Stopping" : controller.state.label)")
            Text("Readiness: \(controller.isStopping ? "Shutting down" : controller.readiness.label)")
            if let pid = controller.state.processID { Text("PID: \(String(pid))") }
            HStack {
                Button("Start") { controller.start() }
                    .disabled(!controller.hasExecutable || controller.state.isRunning)
                Button("Stop") { controller.stop() }
                    .disabled(!controller.state.isRunning || controller.isStopping)
                Button("Restart") { controller.restart() }
                    .disabled(!controller.hasExecutable)
            }
            if let message = controller.shutdownMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = controller.launchErrorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Button("Open Launcher") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(22)
        .frame(width: 340)
        .background(KapitsaTheme.canvas)
        .tint(KapitsaTheme.accent)
    }
}
