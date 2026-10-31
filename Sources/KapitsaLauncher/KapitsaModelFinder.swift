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

    /// The model in what was chosen: the folder or .gguf itself, or the one model found inside
    /// a folder chosen higher up, such as Hugging Face's `models--org--name`, whose .gguf is
    /// three levels down. A .gguf's image or draft part (mmproj-*, mtp-*) and split files' later
    /// parts don't count as models.
    static func resolve(_ url: URL, fileManager: FileManager = .default) -> Result<URL, ResolveProblem> {
        if url.pathExtension.lowercased() == "gguf" {
            return isPart(url.lastPathComponent)
                ? .failure(.problem("\(url.lastPathComponent) is only part of a model (its image or draft part). Choose the main .gguf beside it."))
                : .success(url)
        }
        if fileManager.fileExists(atPath: url.appendingPathComponent("config.json").path) { return .success(url) }
        let found = candidates(in: url, depth: 4, fileManager: fileManager)
        switch found.count {
        case 1: return .success(found[0])
        case 0: return .failure(.problem("No model was found in \(url.lastPathComponent): no folder with a config.json, and no .gguf file. Choose a model's folder or its .gguf file."))
        default:
            let names = found.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
            return .failure(.problem("\(url.lastPathComponent) holds several models (\(names)\(found.count > 5 ? ", …" : "")). Choose the one you want inside it."))
        }
    }

    enum ResolveProblem: Error, Equatable { case problem(String) }

    /// An image projector, draft head or a split file's later part, not a model of its own.
    static func isPart(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("mmproj") || lower.hasPrefix("mtp-") { return true }
        if let range = lower.range(of: #"-(\d{5})-of-\d{5}\.gguf$"#, options: .regularExpression) {
            return !lower[range].hasPrefix("-00001-")
        }
        return false
    }

    private static func candidates(in folder: URL, depth: Int, fileManager: FileManager) -> [URL] {
        guard depth > 0, let entries = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var found: [URL] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let name = entry.lastPathComponent
            // Hugging Face keeps the real files under blobs/ by hash, linked from snapshots/.
            if name == "blobs" || name == ".git" { continue }
            if name.lowercased().hasSuffix(".gguf") {
                if !isPart(name) { found.append(entry) }
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if fileManager.fileExists(atPath: entry.appendingPathComponent("config.json").path) {
                found.append(entry)
            } else {
                found += candidates(in: entry, depth: depth - 1, fileManager: fileManager)
            }
        }
        return found
    }

    /// Asks for a model folder or .gguf file, starting in LM Studio's models when it's there.
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Model"
        panel.message = "Choose a model's folder or .gguf file, or a folder it's in. Hugging Face's downloads are in ~/.cache/huggingface/hub."
        // Hugging Face's cache and LM Studio's models are in hidden folders.
        panel.showsHiddenFiles = true
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
