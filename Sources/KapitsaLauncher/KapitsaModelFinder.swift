import AppKit
import UniformTypeIdentifiers

/// Choosing a model already on this Mac in a Finder window: a model folder, such as one of
/// LM Studio's, or a .gguf file, checked before Kapitsa is asked to run it.
enum KapitsaModelFinder {
    /// The architectures Kapitsa runs (its `unsupported_model`): the Qwen3.5 family, Qwen3.8
    /// Flash Next, Nemotron-H, Dory and Flint, by `config.json`'s `model_type`.
    static let supportedTypes: Set<String> = ["qwen3_5", "qwen3_5_moe", "qwen3_5_text", "qwen3_5_moe_text",
                                              "qwen4_exp", "nemotron_h", "dory", "flint"]

    enum Check: Equatable {
        case ok
        /// Runs, with something worth knowing first.
        case note(String)
        /// Kapitsa can't run it.
        case problem(String)
    }

    /// Whether Kapitsa can run what's at `url`: a folder by its `config.json`, a .gguf by its name.
    static func check(_ url: URL) -> Check {
        if url.pathExtension.lowercased() == "gguf" {
            return .note("Kapitsa converts this GGUF into a model folder once, the first time it starts it; that takes a few minutes. It runs Qwen3.5-family GGUFs.")
        }
        let config = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: config) else {
            return .problem("\(url.lastPathComponent) isn't a model folder: it has no config.json. Choose the folder that holds the model's files, or a .gguf file.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .problem("\(url.lastPathComponent)'s config.json can't be read.")
        }
        let types = [json["model_type"] as? String, (json["text_config"] as? [String: Any])?["model_type"] as? String].compactMap { $0 }
        if types.contains(where: supportedTypes.contains) { return .ok }
        guard let type = types.first else {
            return .note("Its config.json doesn't name an architecture, so Kapitsa decides when it starts.")
        }
        return .problem("This is a \(type) model, which Kapitsa doesn't run. It runs Qwen3.5, 3.6 and 3.8 models, and its own Nemotron, Dory and Flint builds.")
    }

    /// Asks for a model folder or .gguf file, starting in LM Studio's models when it's there.
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Model"
        panel.message = "Choose a model's folder (it holds config.json and .safetensors files), or a .gguf file."
        panel.prompt = "Use Model"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "gguf") ?? .data]
        let lmStudio = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/models")
        if FileManager.default.fileExists(atPath: lmStudio.path) { panel.directoryURL = lmStudio }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
