import SwiftUI

/// A row of choices with the chosen one filled in the theme's indigo. macOS draws its own
/// segmented control in the system blue while the window is active, whatever the app's tint.
struct KapitsaSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    /// Each choice's width; nil shares the width offered between them.
    var segmentWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let isSelected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.callout)
                        .lineLimit(1)
                        .frame(width: segmentWidth)
                        .frame(maxWidth: segmentWidth == nil ? .infinity : nil)
                        .padding(.horizontal, segmentWidth == nil ? 8 : 0).padding(.vertical, 3)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(isSelected ? KapitsaTheme.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                // A divider between two unchosen neighbours, as macOS draws them.
                if index < options.count - 1 {
                    Rectangle().fill(KapitsaTheme.border).frame(width: 1, height: 12)
                        .opacity(isSelected || options[index + 1] == selection ? 0 : 1)
                }
            }
        }
        .padding(2)
        .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(KapitsaTheme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// The model to run, chosen from a menu: downloaded models, then Kapitsa's catalog. While
/// Kapitsa runs, a change asks first, then restarts it with the new model; the Settings page
/// has the rest (another model by name or folder, context, slots).
struct ModelSwitcher: View {
    @ObservedObject var controller: KapitsaProcessController
    /// A reply is being written, so switching now would cut it off.
    var isBusy = false
    /// The Overview's large name, or the Chat toolbar's small one.
    var isLarge = false
    @State private var installed: [String] = []
    @State private var known: [String] = []
    @State private var pending: String?
    /// Why a model chosen in Finder can't be used.
    @State private var chooseProblem: String?
    /// Switch without asking; turned back on in App settings.
    @AppStorage("KapitsaLauncher.skipModelSwitchConfirmation") private var skipConfirmation = false

    /// The model running, else the one chosen, in full: shown on hover.
    private var fullName: String {
        // The loaded model's name outlives a stop, and a restart's old one lingers until the new
        // model loads, so it's shown only while that model runs; otherwise, the one chosen.
        if controller.state.isRunning, !controller.isStopping, let model = controller.engine.model { return model }
        return Self.name(of: controller.configuration.model)
    }

    /// The model running now, else the one chosen. An app connected to Kapitsa can load another
    /// model (Kapitsa's `--allow-switch`), so the running one can differ from the one chosen:
    /// the menu ticks the running one, and choosing the chosen one again switches back to it.
    private var currentModel: String {
        let chosen = controller.configuration.model
        guard controller.state.isRunning, !controller.isStopping, let running = controller.engine.model else { return chosen }
        // Kapitsa names a catalog model without its precision (`qwen3.6-35b-a3b`), so the one
        // chosen, which has it, stands for it while it's the same model.
        if let name = KapitsaThinkingChoice.modelName(forSetting: running),
           name == KapitsaThinkingChoice.modelName(forSetting: chosen) { return chosen }
        return running
    }

    /// What the menu's button says: a short name, so a long folder path doesn't stretch the page.
    private var shownName: String { Self.shortName(of: fullName) }

    /// A folder's or repo's last part (`Qwen3.5-9B-MLX-4bit`), a catalog model's name, or the name.
    static func shortName(of model: String) -> String {
        if let catalog = KapitsaConfiguration.catalogModels.first(where: { $0.name == model }) { return catalog.label }
        if model.contains("/") {
            return model.split(separator: "/").last.map(String.init) ?? model
        }
        return model
    }

    static func name(of model: String) -> String {
        if model.isEmpty { return "Best model for this Mac" }
        return KapitsaConfiguration.catalogModels.first { $0.name == model }?.label ?? model
    }

    var body: some View {
        Menu {
            choice("", title: "Best model for this Mac")
            let entries = ModelMenu.entries(installed: installed, known: known, current: currentModel)
            if !entries.onThisMac.isEmpty {
                Section("On this Mac") {
                    ForEach(entries.onThisMac, id: \.model) { choice($0.model, title: $0.title) }
                }
            }
            Button("Choose a Model on This Mac…", action: chooseInFinder)
            if !entries.catalog.isEmpty {
                Section("Download from the catalog") {
                    ForEach(entries.catalog, id: \.model) { choice($0.model, title: $0.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(shownName).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: isLarge ? 460 : 220, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: isLarge ? 11 : 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(isLarge ? .system(size: 18, weight: .semibold) : .caption)
            .foregroundStyle(isLarge ? Color.primary : Color.secondary)
            .padding(.horizontal, isLarge ? 0 : 8).padding(.vertical, isLarge ? 0 : 2)
            .overlay {
                if !isLarge { Capsule().stroke(KapitsaTheme.border, lineWidth: 1) }
            }
            .contentShape(Rectangle())
            // One element for VoiceOver, not the name and the chevron apart.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Model: \(shownName)")
        }
        // A plain button keeps the label as drawn; the borderless menu style redraws it small, in the tint.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy || controller.isStopping)
        .help(fullName + "\n" + (isBusy ? "Wait for the reply to finish before switching models"
              : controller.state.isRunning ? "Switch models: Kapitsa restarts and loads the one you choose"
              : "Choose the model Kapitsa starts with"))
        .accessibilityLabel("Model: \(shownName)")
        .onAppear {
            installed = KapitsaModelStorage.installedModels()
            known = KapitsaKnownModels.all()
        }
        .alert("Kapitsa can't run this model", isPresented: Binding(get: { chooseProblem != nil }, set: { if !$0 { chooseProblem = nil } })) {
            Button("OK") { chooseProblem = nil }
        } message: {
            Text(chooseProblem ?? "")
        }
        .confirmationDialog("Switch to \(Self.name(of: pending ?? ""))?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Restart with It") {
                guard let model = pending else { return }
                pending = nil
                switchTo(model)
            }
            .dialogSuppressionToggle("Don't ask again", isSuppressed: $skipConfirmation)
        } message: {
            Text("Kapitsa stops and loads the new model, which takes from several seconds to a minute; a model not downloaded yet is downloaded first. Its first reply reads your chat again, and its context may be smaller, so a long chat may come nearer the limit.")
        }
    }

    /// A model folder or .gguf from Finder, checked first, then chosen as from the menu.
    private func chooseInFinder() {
        guard let chosen = KapitsaModelFinder.choose() else { return }
        let url: URL
        switch KapitsaModelFinder.resolve(chosen) {
        case .success(let found): url = found
        case .failure(.problem(let text)): chooseProblem = text; return
        }
        if case .problem(let text) = KapitsaModelFinder.check(url) {
            chooseProblem = text
            return
        }
        select(url.path)
    }

    private func select(_ model: String) {
        guard !ModelMenu.isSame(model, currentModel) else { return }
        if !controller.state.isRunning { controller.configuration.model = model }
        else if skipConfirmation { switchTo(model) }
        else { pending = model }
    }

    private func switchTo(_ model: String) {
        controller.configuration.model = model
        controller.restart()
    }

    private func choice(_ model: String, title: String) -> some View {
        Button { select(model) } label: {
            if ModelMenu.isSame(model, currentModel) { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// The models the model menus and Settings offer, each once: those on this Mac (Kapitsa's
/// downloads, then models used by folder or name), and the catalog's others to download.
enum ModelMenu {
    struct Entry: Equatable {
        /// What `--model` is given: a catalog name for its standard download (`35b`), else the
        /// download's, repo's, folder's or file's name.
        let model: String
        let title: String
    }

    static func entries(installed: [String], known: [String], current: String,
                        physicalMemoryGB: Int = KapitsaConfiguration.physicalMemoryGB) -> (onThisMac: [Entry], catalog: [Entry]) {
        var onThisMac: [Entry] = []
        var downloadedCatalog = Set<String>()
        for name in installed {
            if let catalog = KapitsaConfiguration.catalogModel(forDownloaded: name) {
                downloadedCatalog.insert(catalog.name)
                let variant = name.split(separator: ":").dropFirst().first.map(String.init) ?? catalog.variant
                let isStandard = variant == catalog.variant
                onThisMac.append(Entry(model: isStandard ? catalog.name : name,
                                       title: "\(catalog.label) — \(catalog.architecture) · \(isStandard ? catalog.precision : variant)"))
            } else {
                onThisMac.append(Entry(model: name, title: title(ofOther: name)))
            }
        }
        for model in known + [current] where !model.isEmpty && !onThisMac.contains(where: { isSame($0.model, model) })
            && !KapitsaConfiguration.catalogModels.contains(where: { $0.name == model.split(separator: ":").first.map(String.init) })
            && !installed.contains(importedName(of: model) ?? "") {
            onThisMac.append(Entry(model: model, title: title(ofOther: model)))
        }
        let catalog = KapitsaConfiguration.catalogModels.filter { !downloadedCatalog.contains($0.name) }.map {
            Entry(model: $0.name, title: "\($0.label) (\($0.name)) — \($0.details(physicalMemoryGB: physicalMemoryGB))")
        }
        return (onThisMac, catalog)
    }

    /// The name Kapitsa gives a .gguf file it converts into its own models folder:
    /// `Huihui-Qwen3.8-27B-abliterated.Q4_K_M.gguf` becomes `huihui-qwen3.8-27b-abliterated.q4_k_m`.
    /// Once converted, the menu lists the converted model alone, not the file as well.
    static func importedName(of model: String) -> String? {
        guard KapitsaKnownModels.isPath(model), model.lowercased().hasSuffix(".gguf") else { return nil }
        let file = (model as NSString).lastPathComponent
        return String(file.dropLast(".gguf".count)).lowercased()
    }

    /// "Qwen3.5-2B-MLX-4bit · lmstudio-community" for a repo, the folder and where it is for a path.
    static func title(ofOther model: String) -> String {
        if KapitsaKnownModels.isPath(model) { return KapitsaKnownModels.title(model) }
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] + " · " + parts[0] : model
    }

    /// Whether two settings run the same model: `35b` and `qwen3.6-35b-a3b:4bit`, or the same name.
    static func isSame(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let left = KapitsaThinkingChoice.modelName(forSetting: a), let right = KapitsaThinkingChoice.modelName(forSetting: b)
        else { return false }
        return left == right && variant(of: a) == variant(of: b)
    }

    /// A setting's precision, the catalog's default when it names none.
    private static func variant(of setting: String) -> String? {
        let parts = setting.split(separator: ":").map(String.init)
        if parts.count > 1 { return parts[1] }
        return KapitsaConfiguration.catalogModels.first { $0.name == setting || $0.id == setting }?.variant
    }
}
