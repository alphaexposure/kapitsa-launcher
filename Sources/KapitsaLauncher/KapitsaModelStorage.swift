import Foundation

/// Downloaded Kapitsa models and how much space they and Kapitsa's caches use. The launcher
/// never moves or deletes models; the only data it deletes is the prefix cache, when asked.
struct KapitsaModelStorage: Equatable {
    struct Model: Equatable, Identifiable {
        /// The name Kapitsa accepts, e.g. `qwen3.8-27b:4bit`.
        let id: String
        let folder: URL
        let bytes: Int64
        /// Whether the speculative-decoding drafter was downloaded with the model.
        let hasDrafter: Bool
    }

    /// One model's part of the prefix cache: a folder Kapitsa names by a hash, with an
    /// `about.txt` naming the model, and a `lock` file Kapitsa holds while it uses the folder.
    struct PrefixCache: Equatable, Identifiable {
        var id: String { folder.lastPathComponent }
        let folder: URL
        /// The model it was made for, by Kapitsa's name; nil when `about.txt` doesn't say.
        let model: String?
        let bytes: Int64
        /// A running Kapitsa holds its lock, so it can't be cleared now.
        var inUse = false
        /// Its model's folder is gone (`kapitsa rm`, or moved), so nothing will use it again.
        var modelIsGone = false
        /// How the model wrote replies when this part was made. Kapitsa keeps a separate part
        /// for each, so one model can have two.
        var decoding: Decoding?
        /// When Kapitsa last wrote to it.
        var lastUsed: Date?
        /// Its model came with a DFlash2 drafter, so an MTP part means the drafter was left out.
        var modelHasDrafter = false
    }

    /// How a model writes replies, from the `decoding:` line of a prefix cache's `about.txt`.
    enum Decoding: Equatable {
        /// With the separate DFlash2 drafter, the faster way.
        case drafter
        /// With the model's own MTP head, when the context leaves no room for the drafter.
        case mtp
        /// Without speculative decoding.
        case plain

        init?(aboutLine line: String) {
            if line.contains("DFlash2") { self = .drafter }
            else if line.contains("MTP") { self = .mtp }
            else if line.contains("no drafter") { self = .plain }
            else { return nil }
        }
    }

    let models: [Model]
    /// Conversations Kapitsa keeps on the SSD for instant follow-ups, also across restarts.
    let prefixCaches: [PrefixCache]
    var prefixCacheBytes: Int64 { prefixCaches.reduce(0) { $0 + $1.bytes } }

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

    /// Downloaded models that have a DFlash2 drafter, by Kapitsa's name, with the drafter's folder.
    static func drafters(in root: URL = modelsDirectory) -> [(model: String, folder: URL)] {
        folders(in: root).compactMap { folder in
            let drafter = folder.appendingPathComponent("dflash2", isDirectory: true)
            guard FileManager.default.fileExists(atPath: drafter.path) else { return nil }
            return (modelName(folderName: folder.lastPathComponent), drafter)
        }.sorted { $0.model < $1.model }
    }

    static func scan(modelsRoot: URL = modelsDirectory,
                     prefixCache: URL = prefixCacheDirectory) -> KapitsaModelStorage {
        let models = folders(in: modelsRoot).map { folder in
            Model(id: modelName(folderName: folder.lastPathComponent), folder: folder,
                  bytes: size(of: folder),
                  hasDrafter: FileManager.default.fileExists(atPath: folder.appendingPathComponent("dflash2").path))
        }.sorted { $0.id < $1.id }
        let caches = folders(in: prefixCache).map { folder in
            let about = try? String(contentsOf: folder.appendingPathComponent("about.txt"), encoding: .utf8)
            let modelFolder = about.flatMap(cachedModelFolder(about:))
            return PrefixCache(folder: folder, model: modelFolder.map { modelName(folderName: $0.lastPathComponent) },
                               bytes: size(of: folder), inUse: isLocked(folder),
                               modelIsGone: modelFolder.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false,
                               decoding: about.flatMap(decoding(about:)),
                               lastUsed: lastWritten(folder),
                               modelHasDrafter: modelFolder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("dflash2").path) } ?? false)
        }.sorted { $0.bytes > $1.bytes }
        return KapitsaModelStorage(models: models, prefixCaches: caches)
    }

    /// The model folder a prefix cache folder belongs to, from the `model: <folder>` line of its `about.txt`.
    static func cachedModelFolder(in folder: URL) -> URL? {
        guard let about = try? String(contentsOf: folder.appendingPathComponent("about.txt"), encoding: .utf8) else { return nil }
        return cachedModelFolder(about: about)
    }

    static func cachedModelFolder(about: String) -> URL? {
        guard let line = about.split(separator: "\n").first(where: { $0.hasPrefix("model: ") }) else { return nil }
        let path = line.dropFirst("model: ".count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    static func decoding(about: String) -> Decoding? {
        about.split(separator: "\n").first(where: { $0.hasPrefix("decoding: ") }).flatMap { Decoding(aboutLine: String($0)) }
    }

    /// The newest change to the part or the folders it keeps conversations in.
    private static func lastWritten(_ folder: URL) -> Date? {
        let dates = [folder] + ["kv", "st", "e"].map { folder.appendingPathComponent($0) }
        return dates.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    /// Whether a running Kapitsa holds the part's lock. The shared lock taken to check is let
    /// go at once.
    static func isLocked(_ folder: URL) -> Bool {
        let descriptor = open(folder.appendingPathComponent("lock").path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    struct ClearResult: Equatable {
        var freedBytes: Int64 = 0
        /// Parts a running Kapitsa is using, which are kept.
        var inUse: [PrefixCache] = []
        /// Why a part couldn't be deleted.
        var problems: [String] = []
    }

    /// Deletes the prefix cache parts no Kapitsa is using; Kapitsa rebuilds them as it serves.
    /// Each part's lock is held while it's deleted, and a part whose lock a running Kapitsa
    /// holds (this app's or another one's) is kept.
    static func clearPrefixCaches(_ caches: [PrefixCache]) -> ClearResult {
        var result = ClearResult()
        for cache in caches {
            let descriptor = open(cache.folder.appendingPathComponent("lock").path, O_RDONLY)
            defer { if descriptor >= 0 { close(descriptor) } }
            if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                result.inUse.append(cache)
                continue
            }
            do {
                try FileManager.default.removeItem(at: cache.folder)
                result.freedBytes += cache.bytes
            } catch {
                result.problems.append(error.localizedDescription)
            }
        }
        return result
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
