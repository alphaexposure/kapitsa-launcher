import AppKit
import SwiftUI

/// The addresses, model name and API key other apps use, and their settings to copy.
struct ConnectAppPanel: View {
    @ObservedObject var controller: KapitsaProcessController
    @State private var installed: [String] = []
    @AppStorage("KapitsaLauncher.connectAppStyle") private var style = KapitsaAppConnection.Style.anthropic.rawValue
    @AppStorage("KapitsaLauncher.connectAppShowsSettings") private var showsSettings = false
    @State private var keyCopied = false
    @State private var keyResetTask: Task<Void, Never>?

    private var connection: KapitsaAppConnection { controller.appConnection(installed: installed) }
    private var chosenStyle: KapitsaAppConnection.Style { .init(rawValue: style) ?? .anthropic }

    var body: some View {
        Panel("Connect an app", symbol: "link") {
            Text("Other apps, such as Claude Code, Qwen Code or Cline, can use Kapitsa as their model. Give them these values.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                row("Address for Anthropic-style apps", value: connection.baseURL,
                    help: "Claude Code and other apps that use Anthropic's Messages API take the address without /v1.")
                row("Address for OpenAI-style apps", value: connection.openAIBaseURL,
                    help: "Qwen Code, Codex, Cline, Open WebUI and other apps that use OpenAI's API take the address ending in /v1.")
                row("Model name", value: connection.model,
                    help: "The model's full name in the API, with its precision. With Allow model switching on, a name Kapitsa doesn't know is refused, and a short name such as 35b may load another precision; this name always reaches this model. With it off, Kapitsa ignores the name apps send.")
                keyRow
            }
            DisclosureGroup(isExpanded: $showsSettings) {
                settings.padding(.top, 10)
            } label: {
                Text("Settings to paste into an app").font(.callout)
            }
        }
        .onAppear { installed = KapitsaModelStorage.installedModels() }
        .onChange(of: controller.readiness) { _, _ in installed = KapitsaModelStorage.installedModels() }
    }

    private func row(_ title: String, value: String, help: String) -> some View {
        HStack(spacing: 8) {
            SettingLabel(title, helpText: help)
            Spacer(minLength: 12)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            copyButton(value, help: "Copy \(title.lowercased()) to the clipboard", label: "Copy \(title.lowercased())")
        }
    }

    private var keyRow: some View {
        HStack(spacing: 8) {
            SettingLabel("API key", helpText: "The key apps send as a Bearer token or x-api-key header. It is kept in Keychain and never shown; Copy puts it on the clipboard. Set or remove it in Settings.")
            Spacer(minLength: 12)
            Text(connection.needsAPIKey ? "Saved in Keychain" : "None: apps may send any text")
                .font(.callout).foregroundStyle(.secondary)
            if connection.needsAPIKey {
                Button {
                    guard let key = controller.apiKeyForApps() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    keyCopied = true
                    keyResetTask?.cancel()
                    keyResetTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        keyCopied = false
                    }
                } label: { copyIcon(keyCopied) }
                .buttonStyle(.plain)
                .help("Copy the API key to the clipboard")
                .accessibilityLabel("Copy API key")
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $style) {
                ForEach(KapitsaAppConnection.Style.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(connection.shellText(chosenStyle))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                CopyButton(text: connection.shellText(chosenStyle), help: "Copy export lines to paste into a Terminal window; apps started from that window use Kapitsa") { copied in
                    Label(copied ? "Copied" : "Copy for a terminal", systemImage: copied ? "checkmark" : "terminal")
                }
                CopyButton(text: connection.jsonText(chosenStyle), help: "Copy as JSON, for the env section of an app's settings file") { copied in
                    Label(copied ? "Copied" : "Copy as JSON", systemImage: copied ? "checkmark" : "curlybraces")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.self) { Text($0) }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notes: [String] {
        let terminal = "Copy for a terminal: paste the lines into a Terminal window, then start the app from that same window, for example by typing claude. Only that window uses Kapitsa; other windows, and apps opened from the Dock, are unchanged, and closing the window forgets the settings. Putting the lines in your shell profile (~/.zshrc) would instead send every session to Kapitsa, including when it isn't running."
        let key = connection.needsAPIKey
            ? "Replace PASTE-YOUR-API-KEY with your key. The copied settings never include it, so they're safe to keep in a file others may see."
            : "Kapitsa has no API key, so the key here can be any text; most apps refuse an empty one."
        switch chosenStyle {
        case .anthropic:
            return [
                "Copy as JSON: for Claude Code, put it in the env section of ~/.claude/settings.json, or of a project's .claude/settings.json to use Kapitsa in that project only.",
                terminal,
                "Claude Code asks for an Opus, a Sonnet or a Haiku model depending on the task, so each is set to this model. To use several local models, give each its own: for example a larger model for Opus and a smaller, faster one for Haiku. That needs Allow model switching in Settings. Kapitsa keeps one model loaded at a time, so each change of model reloads it, which takes about 20 seconds or more.",
                key,
            ]
        case .openAI:
            return [
                "Copy as JSON: for an app whose settings file takes environment variables as JSON.",
                terminal,
                "Qwen Code and Codex read these variables. Apps with a settings screen, such as Cline or Open WebUI, take the same address, key and model there.",
                key,
            ]
        }
    }

    private func copyButton(_ text: String, help: String, label: String) -> some View {
        CopyButton(text: text, help: help) { copied in copyIcon(copied) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func copyIcon(_ copied: Bool) -> some View {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .frame(width: 26, height: 26)
            .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}
