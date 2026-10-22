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

    /// Short names Kapitsa 0.2 accepts for its catalog models (`kapitsa --help`).
    static let catalogModels: [(name: String, label: String)] = [
        ("4b", "Qwen3.5 4B"),
        ("9b", "Qwen3.5 9B"),
        ("27b", "Qwen3.8 27B (dense)"),
        ("35b", "Qwen3.6 35B-A3B (MoE)"),
        ("flash", "Qwen3.8 Flash Next"),
        ("dory", "Nemotron Dory 4B"),
        ("nano-4b", "Nemotron 3 Nano 4B"),
        ("nano-9b", "Nemotron Nano 9B v2"),
        ("lightning", "Nemotron 3.5 Lightning"),
        ("bolt", "Nemotron 3.5 Bolt"),
        ("super", "Nemotron 3.5 Super-VL"),
        ("flint", "Flint"),
    ]

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
