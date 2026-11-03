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
    /// The prefix cache parts the person asked to clear, waiting for them to confirm.
    @State private var pendingClear: [KapitsaModelStorage.PrefixCache]?
    @State private var isClearingCache = false
    /// What clearing the prefix cache did.
    @State private var cacheNote: String?

    private static let customTag = "__custom__"

    /// Every name the picker offers: the automatic choice, downloaded models, then the catalog.
    /// The picker's row for the model set: the same model by another name counts (`qwen3.6-35b-a3b:4bit` is `35b`'s row).
    private var pickerTag: String? {
        let entries = ModelMenu.entries(installed: installedModels, known: KapitsaKnownModels.all(), current: "")
        let model = controller.configuration.model
        if model.isEmpty { return "" }
        return (entries.onThisMac + entries.catalog).first { ModelMenu.isSame($0.model, model) }?.model
    }

    private var showsCustomModel: Bool {
        useCustomModel || pickerTag == nil
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
                            get: { showsCustomModel ? Self.customTag : pickerTag ?? "" },
                            set: { value in
                                useCustomModel = value == Self.customTag
                                if !useCustomModel { controller.configuration.model = value }
                            }
                        )) {
                            Text("Best model for this Mac").tag("")
                            let entries = ModelMenu.entries(installed: installedModels, known: KapitsaKnownModels.all(), current: "")
                            if !entries.onThisMac.isEmpty {
                                Section("On this Mac") {
                                    ForEach(entries.onThisMac, id: \.model) { Text($0.title).tag($0.model) }
                                }
                            }
                            Section("Download from the catalog") {
                                ForEach(entries.catalog, id: \.model) { Text($0.title).tag($0.model) }
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
                // Starting or stopping Kapitsa changes which cache part is in use.
                .onChange(of: controller.readiness) { _, _ in refreshModels() }
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
                      helpText: "Tokens one conversation can hold: a number, k or m of them (128k, 1m), or max for the model's limit. Blank lets Kapitsa choose for this Mac's memory: the largest context that still leaves room for the faster DFlash2 drafter. A larger one can leave the drafter out, and replies are then written more slowly.")
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
        guard let chosen = KapitsaModelFinder.choose() else { return }
        let url: URL
        switch KapitsaModelFinder.resolve(chosen) {
        case .success(let found): url = found
        case .failure(.problem(let text)): modelCheck = .problem(text); return
        }
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
                        Text("Conversations Kapitsa keeps for instant follow-ups, one part per model. It manages the size itself (the SSD prefix cache setting caps it).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let cacheNote {
                            Text(cacheNote).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(formattedFileSize(storage.prefixCacheBytes)).font(.callout.weight(.medium)).monospacedDigit()
                    Button("Show files") { revealInFinder(KapitsaModelStorage.prefixCacheDirectory) }
                        .disabled(storage.prefixCacheBytes == 0)
                    Button("Clear All…") { pendingClear = storage.prefixCaches.filter { !$0.inUse } }
                        .disabled(isClearingCache || !storage.prefixCaches.contains { !$0.inUse })
                }
                .padding(.vertical, 9)
                ForEach(storage.prefixCaches) { cache in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cache.model ?? "Unknown model").font(.caption).textSelection(.enabled)
                            if let status = Self.status(of: cache) {
                                Text(status).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 12)
                        Spacer(minLength: 8)
                        Text(formattedFileSize(cache.bytes)).font(.caption.weight(.medium)).monospacedDigit()
                        Button("Clear…") { pendingClear = [cache] }
                            .controlSize(.small)
                            .disabled(cache.inUse || isClearingCache)
                            .help(cache.inUse ? "A running Kapitsa is using it" : "Delete this model's part of the cache")
                    }
                    .padding(.bottom, 7)
                }
                .confirmationDialog(clearTitle, isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } })) {
                    Button("Clear", role: .destructive) {
                        if let caches = pendingClear { clearPrefixCache(caches) }
                        pendingClear = nil
                    }
                } message: {
                    Text("Kapitsa keeps recent conversations here so follow-ups start at once, also after a restart. It rebuilds the cache as you chat, so each chat's next reply reads the chat again first.")
                }
            }
            .padding(.horizontal, 14)
            .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// "Clear 23.6 GB for qwen3.6-35b-a3b:4bit?", or for all the parts not in use.
    private var clearTitle: String {
        let caches = pendingClear ?? []
        let size = formattedFileSize(caches.reduce(0) { $0 + $1.bytes })
        if caches.count == 1 { return "Clear \(size) for \(caches[0].model ?? "this model")?" }
        return "Clear \(size) of the SSD prefix cache?"
    }

    /// In use, or left behind by a model that's gone.
    static func status(of cache: KapitsaModelStorage.PrefixCache) -> String? {
        if cache.inUse { return "In use by a running Kapitsa" }
        if cache.modelIsGone { return "Model no longer on this Mac" }
        return nil
    }

    /// Deletes the unused prefix cache parts in the background, then says what happened.
    private func clearPrefixCache(_ caches: [KapitsaModelStorage.PrefixCache]) {
        isClearingCache = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { KapitsaModelStorage.clearPrefixCaches(caches) }.value
            var note = "Cleared \(formattedFileSize(result.freedBytes))."
            if !result.inUse.isEmpty {
                let names = result.inUse.map { $0.model ?? "a model" }.joined(separator: ", ")
                note += " Kept \(formattedFileSize(result.inUse.reduce(0) { $0 + $1.bytes })) in use by \(names)."
            }
            if let problem = result.problems.first { note += " Some couldn't be deleted: \(problem)" }
            cacheNote = note
            isClearingCache = false
            refreshModels()
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
