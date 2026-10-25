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
        .init(name: "4b", label: "Qwen3.5 4B", id: "qwen3.5-4b", architecture: "Dense", precision: "4-bit", downloadGB: 4.6, memoryGB: 16),
        .init(name: "9b", label: "Qwen3.5 9B", id: "qwen3.5-9b", architecture: "Dense", precision: "4-bit", downloadGB: 9.1, memoryGB: 16),
        .init(name: "27b", label: "Qwen3.8 27B", id: "qwen3.8-27b", architecture: "Dense", precision: "4-bit", downloadGB: 20.2, memoryGB: 32),
        .init(name: "35b", label: "Qwen3.6 35B-A3B", id: "qwen3.6-35b-a3b", architecture: "MoE, 3B active", precision: "4-bit", downloadGB: 22.1, memoryGB: 32),
        .init(name: "flash", label: "Qwen3.8 Flash Next 180B-A7B", id: "qwen3.8-flash-next", architecture: "MoE, 7B active", precision: "4-bit", downloadGB: 105.9, memoryGB: 128),
        .init(name: "dory", label: "Nemotron Dory 1.0 4B", id: "nemotron-labs-dory1.0-4b", architecture: "Looped dense", precision: "NVFP4", downloadGB: 3.2, memoryGB: 16),
        .init(name: "nano-4b", label: "Nemotron 3 Nano 4B", id: "nemotron-3-nano-4b", architecture: "Hybrid Mamba-2", precision: "FP8", downloadGB: 5.3, memoryGB: 16),
        .init(name: "nano-9b", label: "Nemotron Nano 9B v2", id: "nemotron-nano-9b-v2", architecture: "Hybrid Mamba-2", precision: "NVFP4", downloadGB: 7.8, memoryGB: 16),
        .init(name: "lightning", label: "Nemotron 3.5 Lightning 30B-A3B", id: "nemotron-3.5-lightning", architecture: "MoE, 3B active", precision: "NVFP4", downloadGB: 22.9, memoryGB: 32),
        .init(name: "bolt", label: "Nemotron 3.5 Bolt 74B-A9B", id: "nemotron-3.5-bolt", architecture: "MoE, 9B active", precision: "2-bit experts", downloadGB: 25.1, memoryGB: 32),
        .init(name: "super", label: "Nemotron 3.5 Super-VL 120B-A12B", id: "nemotron-3.5-super-vl", architecture: "MoE, 12B active", precision: "NVFP4", downloadGB: 76.4, memoryGB: 96),
        .init(name: "flint", label: "Recursive Flint 40B-A2.5B", id: "flint", architecture: "MoE, 2.5B active", precision: "4-bit", downloadGB: 22.6, memoryGB: 32),
    ]

    /// The catalog model a downloaded one is, from its saved name such as `qwen3.8-27b:4bit`.
    static func catalogModel(forDownloaded name: String) -> CatalogModel? {
        let id = name.split(separator: ":").first.map(String.init) ?? name
        return catalogModels.first { $0.id == id }
    }

    /// This Mac's memory in GB, as Apple counts it (32 for a 32 GB Mac).
    static var physicalMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }

    /// Whether the server only listens on this Mac.
    var isLocalHost: Bool { ["127.0.0.1", "localhost", "::1"].contains(host) }

    var validationError: String? {
        // Values become separate arguments, never shell text; a leading hyphen would read as an option.
        if model.contains(where: { $0.isWhitespace }) || model.hasPrefix("-") {
            return "Model cannot contain whitespace or start with a hyphen."
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
