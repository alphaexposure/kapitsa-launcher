import Foundation

struct KapitsaConfiguration: Codable, Equatable {
    /// Blank lets Kapitsa pick the best model for this Mac.
    var model: String = ""
    var host: String = "127.0.0.1"
    var port: Int = 8000
    var modelID: String = ""
    var context: String = ""
    var slots: String = ""
    var dflash: String = "auto"
    /// Another model's DFlash2 drafter folder, by the model setting that borrows it: a fine-tune
    /// or converted GGUF has no drafter of its own, and can use the one of the model it was made
    /// from. Used instead of `dflash` while that model is chosen.
    var borrowedDrafters: [String: String] = [:]
    var memBudget: String = ""
    var prefillChunk: String = ""
    var diskCache: String = ""
    var allowSwitch: Bool = false

    init() {}

    /// Missing keys keep their defaults, so settings saved by an older launcher still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = KapitsaConfiguration()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        model = value(.model, defaults.model)
        host = value(.host, defaults.host)
        port = value(.port, defaults.port)
        modelID = value(.modelID, defaults.modelID)
        context = value(.context, defaults.context)
        slots = value(.slots, defaults.slots)
        dflash = value(.dflash, defaults.dflash)
        borrowedDrafters = value(.borrowedDrafters, defaults.borrowedDrafters)
        memBudget = value(.memBudget, defaults.memBudget)
        prefillChunk = value(.prefillChunk, defaults.prefillChunk)
        diskCache = value(.diskCache, defaults.diskCache)
        allowSwitch = value(.allowSwitch, defaults.allowSwitch)
    }

    /// A model in Kapitsa's catalog: the short name it accepts, and what the menu says about it.
    struct CatalogModel: Equatable {
        /// The short name Kapitsa accepts, such as `35b`.
        let name: String
        let label: String
        /// The name Kapitsa saves it under, which downloaded models are listed by.
        let id: String
        /// Dense, or mixture of experts with the parameters used per token.
        let architecture: String
        let precision: String
        /// The default precision's name, as a download's folder ends: `qwen3.6-35b-a3b-4bit`.
        let variant: String
        /// The download in GB, at the default precision.
        let downloadGB: Double
        /// The smallest Mac Kapitsa's documentation suggests, in GB of memory.
        let memoryGB: Int

        /// "MoE, 3B active · 4-bit · 22.1 GB · 32 GB+ Mac", and a warning on a Mac with too little memory.
        func details(physicalMemoryGB: Int) -> String {
            var text = "\(architecture) · \(precision) · \(downloadGB.formatted(.number.precision(.fractionLength(1)))) GB · \(memoryGB) GB+ Mac"
            if memoryGB > physicalMemoryGB { text += " · too big for this Mac" }
            return text
        }
    }

    /// Kapitsa 0.2's catalog: names, architectures and download sizes from `kapitsa --help`;
    /// the smallest Mac for each from its documentation.
    static let catalogModels: [CatalogModel] = [
        .init(name: "4b", label: "Qwen3.5 4B", id: "qwen3.5-4b", architecture: "Dense", precision: "4-bit", variant: "4bit", downloadGB: 4.6, memoryGB: 16),
        .init(name: "9b", label: "Qwen3.5 9B", id: "qwen3.5-9b", architecture: "Dense", precision: "4-bit", variant: "4bit", downloadGB: 9.1, memoryGB: 16),
        .init(name: "27b", label: "Qwen3.8 27B", id: "qwen3.8-27b", architecture: "Dense", precision: "4-bit", variant: "4bit", downloadGB: 20.2, memoryGB: 32),
        .init(name: "35b", label: "Qwen3.6 35B-A3B", id: "qwen3.6-35b-a3b", architecture: "MoE, 3B active", precision: "4-bit", variant: "4bit", downloadGB: 22.1, memoryGB: 32),
        .init(name: "flash", label: "Qwen3.8 Flash Next 180B-A7B", id: "qwen3.8-flash-next", architecture: "MoE, 7B active", precision: "4-bit", variant: "4bit", downloadGB: 105.9, memoryGB: 128),
        .init(name: "dory", label: "Nemotron Dory 1.0 4B", id: "nemotron-labs-dory1.0-4b", architecture: "Looped dense", precision: "NVFP4", variant: "nvfp4", downloadGB: 3.2, memoryGB: 16),
        .init(name: "nano-4b", label: "Nemotron 3 Nano 4B", id: "nemotron-3-nano-4b", architecture: "Hybrid Mamba-2", precision: "FP8", variant: "fp8", downloadGB: 5.3, memoryGB: 16),
        .init(name: "nano-9b", label: "Nemotron Nano 9B v2", id: "nemotron-nano-9b-v2", architecture: "Hybrid Mamba-2", precision: "NVFP4", variant: "nvfp4", downloadGB: 7.8, memoryGB: 16),
        .init(name: "lightning", label: "Nemotron 3.5 Lightning 30B-A3B", id: "nemotron-3.5-lightning", architecture: "MoE, 3B active", precision: "NVFP4", variant: "nvfp4", downloadGB: 22.9, memoryGB: 32),
        .init(name: "bolt", label: "Nemotron 3.5 Bolt 74B-A9B", id: "nemotron-3.5-bolt", architecture: "MoE, 9B active", precision: "2-bit experts", variant: "24gb", downloadGB: 25.1, memoryGB: 32),
        .init(name: "super", label: "Nemotron 3.5 Super-VL 120B-A12B", id: "nemotron-3.5-super-vl", architecture: "MoE, 12B active", precision: "NVFP4", variant: "nvfp4", downloadGB: 76.4, memoryGB: 96),
        .init(name: "flint", label: "Recursive Flint 40B-A2.5B", id: "flint", architecture: "MoE, 2.5B active", precision: "4-bit", variant: "4bit", downloadGB: 22.6, memoryGB: 32),
    ]

    /// The catalog model a downloaded one is, from its saved name such as `qwen3.8-27b:4bit`.
    static func catalogModel(forDownloaded name: String) -> CatalogModel? {
        let id = name.split(separator: ":").first.map(String.init) ?? name
        return catalogModels.first { $0.id == id }
    }

    /// What pressing Start will do for `model` before it can load, when that's more than loading:
    /// a download, or a GGUF's one-time conversion. Nil when it's already on this Mac.
    static func preparationNote(for model: String, installed: [String],
                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, !installed.contains(model) else { return nil }
        let path = (model as NSString).expandingTildeInPath
        if model.hasPrefix("/") || model.hasPrefix("~") || model.hasPrefix(".") {
            guard fileExists(path) else { return "Nothing is at that path on this Mac." }
            return model.lowercased().hasSuffix(".gguf")
                ? "Kapitsa converts this GGUF into a model folder once, the first time you press Start; that takes a few minutes."
                : nil
        }
        let parts = model.split(separator: ":", maxSplits: 1).map(String.init)
        if let catalog = catalogModels.first(where: { $0.name == parts[0] }) {
            let variant = parts.count > 1 ? parts[1] : nil
            let have = installed.contains { name in
                guard catalogModel(forDownloaded: name)?.name == catalog.name else { return false }
                return variant.map { name.hasSuffix(":" + $0) } ?? true
            }
            if have { return nil }
            let size = variant == nil ? "about \(catalog.downloadGB.formatted(.number.precision(.fractionLength(1)))) GB" : "this precision"
            return "Not downloaded yet: \(size) downloads when you press Start, then the model loads. The Overview shows the progress."
        }
        if model.contains("/") {
            return "Downloads from Hugging Face when you press Start, unless Kapitsa already has it; the Overview shows the progress. Kapitsa runs Qwen3.5-family models (Qwen3.5, 3.6, 3.8) in MLX format or as a .gguf file."
        }
        return nil
    }

    /// This Mac's memory in GB, as Apple counts it (32 for a 32 GB Mac).
    static var physicalMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }

    /// What `--dflash` is given for the chosen model: auto, none, or a borrowed drafter's folder.
    var drafter: String {
        model.isEmpty ? dflash : borrowedDrafters[model] ?? dflash
    }

    /// Whether the server only listens on this Mac. Hosts are IPv4 (the port check binds IPv4).
    var isLocalHost: Bool { ["127.0.0.1", "localhost"].contains(host) }

    var validationError: String? {
        // Values become separate arguments, never shell text; a leading hyphen would read as an option.
        // A path may hold spaces (`/Volumes/My Drive/…`), being one argument; a name can't.
        let isPath = model.hasPrefix("/") || model.hasPrefix("~") || model.hasPrefix(".")
        if model.hasPrefix("-") || model.contains(where: { isPath ? $0.isNewline : $0.isWhitespace }) {
            return isPath ? "The model's path cannot contain a line break." : "Model cannot contain whitespace or start with a hyphen."
        }
        if modelID.contains(where: { $0.isWhitespace }) || modelID.hasPrefix("-") {
            return "API model name cannot contain whitespace or start with a hyphen."
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a host." }
        if host.hasPrefix("-") || host.contains(where: { $0.isWhitespace }) { return "Enter a valid host." }
        if !(1...65535).contains(port) { return "Port must be between 1 and 65535." }
        if !context.isEmpty,
           context.range(of: #"^([1-9][0-9]*[kKmM]?|max)$"#, options: .regularExpression) == nil {
            return "Context must be a token count such as 32768, 128k or 1m, or max."
        }
        if !slots.isEmpty, Int(slots).map({ (1...64).contains($0) }) != true {
            return "Slots must be a number from 1 to 64."
        }
        if !["auto", "none"].contains(dflash) { return "Drafter must be auto or none." }
        if borrowedDrafters.values.contains(where: { !$0.hasPrefix("/") || $0.contains(where: \.isNewline) }) {
            return "A borrowed drafter must be a folder's full path."
        }
        if !memBudget.isEmpty, Double(memBudget).map({ $0 > 0 && $0 < 4096 }) != true {
            return "Memory budget must be a number of GB, such as 24."
        }
        if !prefillChunk.isEmpty, Int(prefillChunk).map({ (16...65_536).contains($0) }) != true {
            return "Prefill chunk must be a number of tokens, such as 1024."
        }
        if !diskCache.isEmpty,
           diskCache.range(of: #"^(0|auto|[1-9][0-9]*[GgMmTt]?)$"#, options: .regularExpression) == nil {
            return "SSD prefix cache must be auto, 0, or a size such as 16G."
        }
        return nil
    }
}

final class KapitsaSettingsStore {
    private let defaults: UserDefaults
    private let configurationKey = "KapitsaLauncher.configuration"
    private let executablePathKey = "KapitsaLauncher.executablePath"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadConfiguration() -> KapitsaConfiguration {
        guard let data = defaults.data(forKey: configurationKey),
              let configuration = try? JSONDecoder().decode(KapitsaConfiguration.self, from: data)
        else { return KapitsaConfiguration() }
        return configuration
    }

    func saveConfiguration(_ configuration: KapitsaConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: configurationKey)
    }

    func loadExecutablePath() -> String? { defaults.string(forKey: executablePathKey) }
    func saveExecutablePath(_ path: String) { defaults.set(path, forKey: executablePathKey) }
}
