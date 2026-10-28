import AppKit
import SwiftUI

/// Model, connection and server options, the downloaded models list, and the API key.
struct SettingsPage: View {
    @ObservedObject var controller: KapitsaProcessController
    @State private var installedModels: [String] = []
    @State private var modelStorage: KapitsaModelStorage?
    @State private var useCustomModel = false
    /// What checking a model chosen in Finder found.
    @State private var modelCheck: KapitsaModelFinder.Check?
    @State private var keyDraft = ""

    private static let customTag = "__custom__"

    /// Every name the picker offers: the automatic choice, downloaded models, then the catalog.
    private var pickerNames: Set<String> {
        Set([""] + installedModels + KapitsaKnownModels.all() + KapitsaConfiguration.catalogModels.map(\.name))
    }

    private var showsCustomModel: Bool {
        useCustomModel || !pickerNames.contains(controller.configuration.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MissingKapitsaNotice(controller: controller)
            if controller.state.isRunning {
                Notice("Stop Kapitsa to edit server settings. Changes apply on the next start.", symbol: "lock")
            }
            Panel("Model & connection", symbol: "cpu") {
                HStack {
                    SettingLabel("Executable", helpText: "The installed kapitsa program this launcher starts. Choose a different executable if automatic discovery found the wrong one.")
                    Text(controller.executable?.path ?? "Not found")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseKapitsaExecutable(for: controller) }
                        .disabled(controller.state.isRunning)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SettingLabel("Model", defaultValue: "Best model for this Mac",
                                     helpText: "Choose a downloaded model or one from Kapitsa's catalog. A model that isn't downloaded yet is downloaded the first time you start it, which can be many gigabytes. Other model… takes a Hugging Face repo, a model folder or a .gguf file.")
                        Picker("Model", selection: Binding(
                            get: { showsCustomModel ? Self.customTag : controller.configuration.model },
                            set: { value in
                                useCustomModel = value == Self.customTag
                                if !useCustomModel { controller.configuration.model = value }
                            }
                        )) {
                            Text("Best model for this Mac").tag("")
                            if !installedModels.isEmpty {
                                Section("Downloaded") {
                                    // The precision downloaded may not be the catalog's default, so no size here.
                                    ForEach(installedModels, id: \.self) { name in
                                        let model = KapitsaConfiguration.catalogModel(forDownloaded: name)
                                        Text(model.map { "\(name) — \($0.label), \($0.architecture)" } ?? name).tag(name)
                                    }
                                }
                            }
                            let others = ModelSwitcher.otherModels(known: KapitsaKnownModels.all(), current: "", installed: installedModels)
                            if !others.isEmpty {
                                Section("Your models") {
                                    ForEach(others, id: \.self) { Text(KapitsaKnownModels.title($0)).tag($0) }
                                }
                            }
                            Section("Kapitsa catalog") {
                                ForEach(KapitsaConfiguration.catalogModels, id: \.name) { model in
                                    Text("\(model.label) (\(model.name)) — \(model.details(physicalMemoryGB: KapitsaConfiguration.physicalMemoryGB))")
                                        .tag(model.name)
                                }
                            }
                            Text("Other model…").tag(Self.customTag)
                        }
                        .labelsHidden().frame(width: 300)
                        .accessibilityLabel("Model")
                        .disabled(controller.state.isRunning)
                    }
                    if showsCustomModel {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            field("Model", text: $controller.configuration.model,
                                  prompt: "org/name, folder or .gguf", defaultValue: "Best model for this Mac",
                                  helpText: "A catalog name such as 27b or 35b:8bit, a Hugging Face repo of a Qwen3.5-family model in MLX format (org/name[@revision]), a model folder, or a .gguf file, which Kapitsa converts once. Choose… picks a folder or file in Finder.")
                            Button("Choose…", action: chooseModel)
                                .disabled(controller.state.isRunning)
                                .help("Pick a model folder (such as one of LM Studio's) or a .gguf file on this Mac")
                        }
                    }
                    if let check = modelCheck {
                        switch check {
                        case .ok: EmptyView()
                        case .note(let text):
                            Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        case .problem(let text):
                            Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let note = KapitsaConfiguration.preparationNote(for: controller.configuration.model, installed: installedModels) {
                        Label(note, systemImage: "arrow.down.circle")
                            .font(.callout).foregroundStyle(KapitsaTheme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text(installedModels.isEmpty ? "No downloaded models found." : "\(String(installedModels.count)) downloaded \(installedModels.count == 1 ? "model" : "models")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { refreshModels() }
                    }
                    installedModelsList
                }
                .onAppear { refreshModels() }
                field("Host", text: $controller.configuration.host,
                      prompt: "127.0.0.1", defaultValue: "127.0.0.1",
                      helpText: "The network address Kapitsa listens on. 127.0.0.1 allows connections from this Mac only; 0.0.0.0 serves your network.")
                HStack {
                    SettingLabel("Port", defaultValue: "8000",
                                 helpText: "The network port for Kapitsa's API and browser chat page. Use a port that is not already in use.")
                    TextField("", value: $controller.configuration.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .accessibilityLabel("Port")
                        .disabled(controller.state.isRunning)
                }
                field("API model name", text: $controller.configuration.modelID,
                      prompt: "e.g. qwen", defaultValue: "The model's name",
                      helpText: "The model's name in the API, which chat apps see in /v1/models.")
            }

            Panel("Server settings", symbol: "slider.horizontal.3") {
                field("Context per conversation", text: $controller.configuration.context,
                      prompt: "e.g. 128k or max", defaultValue: "128K, less when memory is tight",
                      helpText: "Tokens one conversation can hold: a number, k or m of them (128k, 1m), or max for the model's limit. Blank lets Kapitsa choose for this Mac's memory.")
                field("Slots", text: $controller.configuration.slots,
                      prompt: "e.g. 2", defaultValue: "Up to 4, as memory allows",
                      helpText: "Requests that run at once, each keeping its conversation ready for instant follow-ups. More requests wait for a free slot. Fewer slots leave more memory for context.")
                HStack {
                    SettingLabel("Speculative drafter", defaultValue: "Automatic",
                                 helpText: "Automatic uses the DFlash2 drafter downloaded with the model, which usually speeds up generation. Off decodes with the model's own MTP head and uses less memory.")
                    Picker("", selection: $controller.configuration.dflash) {
                        Text("Automatic").tag("auto")
                        Text("Off").tag("none")
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .accessibilityLabel("Speculative drafter")
                    .disabled(controller.state.isRunning)
                }
                field("Memory budget (GB)", text: $controller.configuration.memBudget,
                      prompt: "e.g. 24", defaultValue: "A little under what macOS recommends",
                      helpText: "GPU memory Kapitsa may hold. Blank uses a little less than the working set macOS recommends for this GPU; kapitsa doctor shows it.")
                field("Prefill chunk (tokens)", text: $controller.configuration.prefillChunk,
                      prompt: "e.g. 1024", defaultValue: "2048, 1024 when memory is short",
                      helpText: "Prompt tokens processed per pass. Smaller chunks use less memory.")
                field("SSD prefix cache", text: $controller.configuration.diskCache,
                      prompt: "auto, 0 or e.g. 16G", defaultValue: "auto (up to 32 GiB)",
                      helpText: "Conversations kept on the SSD for instant follow-ups, also across restarts. auto uses a quarter of the free space beyond 10 GiB, at most 32 GiB; a size such as 16G caps it; 0 turns it off.")
                HStack {
                    SettingLabel("Allow model switching", defaultValue: "Off",
                                 helpText: "Lets a request that names another model, or POST /v1/models/switch, load it. That may download gigabytes. On a network address this needs an API key.")
                    Toggle("", isOn: $controller.configuration.allowSwitch)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Allow model switching")
                        .disabled(controller.state.isRunning)
                }
            }

            Panel("API access", symbol: "lock.shield") {
                Text(controller.hasAPIKey ? "Saved in Keychain" : "No API key saved")
                    .foregroundStyle(.secondary)
                HStack {
                    SettingLabel("New API key", helpText: "Optional key saved in macOS Keychain. API clients must send it as a Bearer token or x-api-key header, and the chat page asks for it once. The saved key is never shown here.")
                    SecureField("", text: $keyDraft, prompt: Text("Enter a key"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 230)
                        .accessibilityLabel("New API key")
                        .disabled(controller.state.isRunning)
                        .onSubmit(saveKey)
                }
                HStack {
                    Button("Save key", action: saveKey)
                        .disabled(keyDraft.isEmpty || controller.state.isRunning)
                    Button("Remove key") { controller.removeAPIKey() }
                        .disabled(!controller.hasAPIKey || controller.state.isRunning)
                }
                // Kapitsa reads the key only when it starts, so changes wait until it's stopped.
                if controller.state.isRunning {
                    Notice("Stop Kapitsa to change the API key. The key is applied when Kapitsa starts.", symbol: "lock")
                }
                if let error = controller.keyErrorMessage { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private func refreshModels() {
        installedModels = KapitsaModelStorage.installedModels()
        Task {
            let storage = await Task.detached(priority: .utility) { KapitsaModelStorage.scan() }.value
            modelStorage = storage
        }
    }

    /// A model folder or .gguf from Finder: used when Kapitsa can run it, explained when not.
    private func chooseModel() {
        guard let url = KapitsaModelFinder.choose() else { return }
        let check = KapitsaModelFinder.check(url)
        modelCheck = check
        if case .problem = check { return }
        useCustomModel = true
        controller.configuration.model = url.path
    }

    /// Each downloaded model's size, with a button that opens its folder.
    @ViewBuilder
    private var installedModelsList: some View {
        if let storage = modelStorage, !storage.models.isEmpty || storage.prefixCacheBytes > 0 {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(storage.models) { model in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.id).font(.callout).textSelection(.enabled)
                            Text(model.hasDrafter ? "Weights and DFlash2 drafter" : "Weights")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(formattedFileSize(model.bytes)).font(.callout.weight(.medium)).monospacedDigit()
                        Button("Show files") { revealInFinder(model.folder) }
                            .help(model.folder.path)
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SSD prefix cache").font(.callout)
                        Text("Conversations Kapitsa keeps for instant follow-ups. It manages the size itself.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(formattedFileSize(storage.prefixCacheBytes)).font(.callout.weight(.medium)).monospacedDigit()
                    Button("Show files") { revealInFinder(KapitsaModelStorage.prefixCacheDirectory) }
                        .disabled(storage.prefixCacheBytes == 0)
                }
                .padding(.vertical, 9)
            }
            .padding(.horizontal, 14)
            .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func formattedFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func revealInFinder(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func saveKey() {
        guard !keyDraft.isEmpty, !controller.state.isRunning else { return }
        controller.saveAPIKey(keyDraft)
        if controller.keyErrorMessage == nil { keyDraft = "" }
    }

    private var isLocked: Bool { controller.state.isRunning }

    private func field(_ title: String, text: Binding<String>, prompt: String,
                       defaultValue: String, helpText: String) -> some View {
        SettingField(title, text: text, prompt: prompt, defaultValue: defaultValue,
                     helpText: helpText, isLocked: isLocked)
    }
}
