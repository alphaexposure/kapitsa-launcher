import Foundation

/// Downloaded Kapitsa models and how much space they and Kapitsa's caches use.
/// Read-only: the launcher never moves or deletes Kapitsa data.
struct KapitsaModelStorage: Equatable {
    struct Model: Equatable, Identifiable {
        /// The name Kapitsa accepts, e.g. `qwen3.8-27b:4bit`.
        let id: String
        let folder: URL
        let bytes: Int64
        /// Whether the speculative-decoding drafter was downloaded with the model.
        let hasDrafter: Bool
    }

    let models: [Model]
    /// Conversations Kapitsa keeps on the SSD for instant follow-ups, also across restarts.
    let prefixCacheBytes: Int64

    /// Kapitsa's data folder: `KAPITSA_HOME` when set, else `~/.cache/kapitsa`.
    static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["KAPITSA_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/kapitsa", isDirectory: true)
    }

    static var modelsDirectory: URL { home().appendingPathComponent("models", isDirectory: true) }
    static var prefixCacheDirectory: URL { home().appendingPathComponent("prefix-cache", isDirectory: true) }

    /// Kapitsa names each catalog model's folder `<model>-<variant>`, which it accepts as
    /// `<model>:<variant>`, and a Hugging Face repo's `<org>--<name>`, accepted as `<org>/<name>`.
    /// Any other folder, such as a converted GGUF (`qwen3.8-27b-ud-q4_k_m`), goes by its name.
    static func modelName(folderName: String) -> String {
        if let separator = folderName.range(of: "--") { return folderName.replacingCharacters(in: separator, with: "/") }
        guard let hyphen = folderName.lastIndex(of: "-"),
              KapitsaConfiguration.catalogModels.contains(where: { $0.id == String(folderName[..<hyphen]) })
        else { return folderName }
        return folderName[..<hyphen] + ":" + folderName[folderName.index(after: hyphen)...]
    }

    static func installedModels(in root: URL = modelsDirectory) -> [String] {
        folders(in: root).map { modelName(folderName: $0.lastPathComponent) }.sorted()
    }

    static func scan(modelsRoot: URL = modelsDirectory,
                     prefixCache: URL = prefixCacheDirectory) -> KapitsaModelStorage {
        let models = folders(in: modelsRoot).map { folder in
            Model(id: modelName(folderName: folder.lastPathComponent), folder: folder,
                  bytes: size(of: folder),
                  hasDrafter: FileManager.default.fileExists(atPath: folder.appendingPathComponent("dflash2").path))
        }.sorted { $0.id < $1.id }
        return KapitsaModelStorage(models: models, prefixCacheBytes: size(of: prefixCache))
    }

    private static func folders(in root: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Bytes of every regular file under `root`, counting each real file once.
    static func size(of root: URL) -> Int64 {
        var total: Int64 = 0
        var seen = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return 0 }
        for case let url as URL in enumerator {
            let real = url.resolvingSymlinksInPath()
            guard let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, seen.insert(real.path).inserted else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
