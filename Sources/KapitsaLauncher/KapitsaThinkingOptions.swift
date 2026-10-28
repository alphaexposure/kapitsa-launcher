import Foundation

/// The thinking choices a model offers, read from its chat template, which every model folder
/// carries, so models people bring themselves get the right buttons too. Kapitsa doesn't report
/// them. Four kinds:
/// - `enable_thinking` alone (Qwen3.5 and 3.6, Nemotron Lightning and Nano): Off and On.
/// - `reasoning_effort` with a list of levels (Qwen3.8 27B and Flash Next): Off and those levels.
///   The level goes in a system message at the start of the prompt, so changing it mid-chat
///   makes the next reply read the whole chat again instead of reusing Kapitsa's cache.
/// - `medium_effort` (Nemotron Bolt, Super-VL, Dory): Off, Shorter and Full. Kapitsa turns the
///   `low` and `medium` efforts into it, a note on the latest question.
/// - None of these (Flint): no buttons; the model decides.
/// A template that can't be found or read gets Off and On.
struct KapitsaThinkingOptions: Equatable {
    enum Kind: Equatable { case onOff, effort, shorterFull, none }

    let kind: Kind
    /// The buttons, in order; empty when the model can't be told.
    let levels: [KapitsaThinkingLevel]
    /// The level the model uses when not told otherwise.
    let defaultLevel: KapitsaThinkingLevel
    /// Whether the level sits at the start of the prompt, so changing it mid-chat makes the
    /// next reply read the whole conversation again.
    let changeRereadsChat: Bool
    /// The levels that put text at the start of the prompt (the 27B's Low and Extra high);
    /// the others (Off, Medium) leave it the same as each other.
    var levelsWithStartText: Set<KapitsaThinkingLevel> = []

    /// Whether going from `old` to `new` changes the start of the prompt.
    func changesPromptStart(from old: KapitsaThinkingLevel, to new: KapitsaThinkingLevel) -> Bool {
        guard changeRereadsChat, old != new else { return false }
        let start = { (level: KapitsaThinkingLevel) in self.levelsWithStartText.contains(level) ? level : nil }
        return start(old) != start(new)
    }

    static let onOff = KapitsaThinkingOptions(kind: .onOff, levels: [.off, .on], defaultLevel: .on, changeRereadsChat: false)

    /// The button's name: Nemotron's full reasoning is "Full" beside "Shorter".
    func label(_ level: KapitsaThinkingLevel) -> String {
        kind == .shorterFull && level == .on ? "Full" : level.label
    }

    /// `level` when the model offers it, else its default.
    func valid(_ level: KapitsaThinkingLevel?) -> KapitsaThinkingLevel {
        guard let level, levels.contains(level) else { return defaultLevel }
        return level
    }

    init(kind: Kind, levels: [KapitsaThinkingLevel], defaultLevel: KapitsaThinkingLevel, changeRereadsChat: Bool,
         levelsWithStartText: Set<KapitsaThinkingLevel> = []) {
        self.kind = kind
        self.levels = levels
        self.defaultLevel = defaultLevel
        self.changeRereadsChat = changeRereadsChat
        self.levelsWithStartText = levelsWithStartText
    }

    init(template: String) {
        if template.contains("reasoning_effort"), let effort = Self.effortLevels(in: template) {
            self.init(kind: .effort, levels: [.off] + effort.levels, defaultLevel: effort.default, changeRereadsChat: true,
                      levelsWithStartText: Self.levelsWithText(in: template, among: effort.levels))
        } else if template.contains("medium_effort") {
            self.init(kind: .shorterFull, levels: [.off, .shorter, .on], defaultLevel: .on, changeRereadsChat: false)
        } else if template.contains("enable_thinking") {
            // Some think only when asked (the Qwen3.5 2B: "enable_thinking is defined and
            // enable_thinking is true"); their default is Off.
            self = Self.thinksOnlyWhenAsked(template)
                ? KapitsaThinkingOptions(kind: .onOff, levels: [.off, .on], defaultLevel: .off, changeRereadsChat: false)
                : .onOff
        } else {
            self.init(kind: .none, levels: [], defaultLevel: .on, changeRereadsChat: false)
        }
    }

    /// The levels a template accepts, from its check (`not in ('xhigh', 'medium', 'low')`), in
    /// rising order, and its default (`reasoning_effort|default('xhigh')`).
    static func effortLevels(in template: String) -> (levels: [KapitsaThinkingLevel], default: KapitsaThinkingLevel)? {
        guard let check = template.range(of: #"not in \(([^)]*'(?:low|medium|high|xhigh)'[^)]*)\)"#, options: .regularExpression) else { return nil }
        let named = Set(template[check].split { !$0.isLetter }.map(String.init))
        let levels = [KapitsaThinkingLevel.low, .medium, .high, .xhigh].filter { named.contains($0.rawValue) }
        guard !levels.isEmpty else { return nil }
        var fallback = levels.last!
        if let range = template.range(of: #"reasoning_effort\s*\|\s*default\(['"](\w+)['"]\)"#, options: .regularExpression),
           let name = template[range].split(whereSeparator: { "'\"".contains($0) }).dropFirst().first,
           let level = KapitsaThinkingLevel(rawValue: String(name)), levels.contains(level) {
            fallback = level
        }
        return (levels, fallback)
    }

    /// The levels the template writes something for (`resolved_reasoning_effort == 'low'`), or
    /// every level when it doesn't say.
    static func levelsWithText(in template: String, among levels: [KapitsaThinkingLevel]) -> Set<KapitsaThinkingLevel> {
        let regex = try! NSRegularExpression(pattern: #"reasoning_effort\s*==\s*['"](\w+)['"]"#)
        let named = Set(regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
            .compactMap { Range($0.range(at: 1), in: template).map { String(template[$0]) } })
        let found = Set(levels.filter { named.contains($0.rawValue) })
        return found.isEmpty ? Set(levels) : found
    }

    /// Whether the template thinks only when `enable_thinking` is set to true, rather than
    /// unless it's set to false.
    static func thinksOnlyWhenAsked(_ template: String) -> Bool {
        template.range(of: #"enable_thinking\s+is\s+defined\s+and\s+enable_thinking\s+is\s+true"#, options: .regularExpression) != nil
            && template.range(of: #"enable_thinking\s+is\s+false"#, options: .regularExpression) == nil
    }

    // MARK: Finding the template

    /// A model folder's chat template: `chat_template.jinja`, else `tokenizer_config.json`'s.
    static func template(in folder: URL) -> String? {
        if let text = try? String(contentsOf: folder.appendingPathComponent("chat_template.jinja"), encoding: .utf8) {
            return text
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let text = json["chat_template"] as? String { return text }
        // Some keep a list of named templates; the default one is first or named "default".
        let list = json["chat_template"] as? [[String: Any]] ?? []
        return (list.first { $0["name"] as? String == "default" } ?? list.first)?["template"] as? String
    }

    /// The folder of the model Kapitsa runs as `id`: the folder given to `--model` when it was
    /// one, else Kapitsa's own folder for it (`<id>-<variant>`, the variant asked for first).
    static func folder(forModel id: String, configured: String?, modelsDirectory: URL = KapitsaModelStorage.modelsDirectory) -> URL? {
        if let configured, !configured.isEmpty {
            let path = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return path
            }
        }
        // A Hugging Face repo, saved as <org>--<name>.
        if let configured, configured.contains("/"), !configured.hasPrefix("/"), !configured.hasPrefix("~") {
            let repo = modelsDirectory.appendingPathComponent(configured.split(separator: "@").first.map(String.init)!
                .replacingOccurrences(of: "/", with: "--"))
            if FileManager.default.fileExists(atPath: repo.path) { return repo }
        }
        let folders = ((try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(id + "-") || $0.lastPathComponent == id }
        let variant = configured?.split(separator: ":").dropFirst().first.map { id + "-" + $0 }
        return folders.first { $0.lastPathComponent == variant } ?? folders.sorted { $0.path < $1.path }.first
    }

    private static var cache: [String: KapitsaThinkingOptions] = [:]
    private static let cacheLock = NSLock()

    /// The options for the model Kapitsa runs as `id`, read once per model.
    static func forModel(_ id: String, configured: String? = nil) -> KapitsaThinkingOptions {
        let key = id + "|" + (configured ?? "")
        if let known = cacheLock.withLock({ cache[key] }) { return known }
        let options = folder(forModel: id, configured: configured).flatMap(template(in:)).map(KapitsaThinkingOptions.init) ?? .onOff
        cacheLock.withLock { cache[key] = options }
        return options
    }
}

/// The thinking level chosen for each model, kept in UserDefaults, and the model last run, so
/// the buttons stay right while Kapitsa is stopped.
enum KapitsaThinkingChoice {
    static let lastModelKey = "KapitsaLauncher.chatThinkingModel"

    /// "Level" since the 2B fix: choices saved before it could hold On for models that think
    /// only when asked, the old default, so each model starts again from its template's default.
    static func key(for model: String) -> String { "KapitsaLauncher.chatThinkingLevel." + model }

    static func saved(for model: String, defaults: UserDefaults = .standard) -> KapitsaThinkingLevel? {
        defaults.string(forKey: key(for: model)).flatMap(KapitsaThinkingLevel.init)
    }

    static func save(_ level: KapitsaThinkingLevel, for model: String, defaults: UserDefaults = .standard) {
        defaults.set(level.rawValue, forKey: key(for: model))
    }
}

/// Models used by name, folder or file that aren't downloaded into Kapitsa's own folder, such
/// as LM Studio's: remembered once they load, so the model menus keep offering them, and
/// forgotten when a start with one fails or its folder has gone.
enum KapitsaKnownModels {
    static let key = "KapitsaLauncher.knownModels"

    static func all(defaults: UserDefaults = .standard, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        (defaults.stringArray(forKey: key) ?? []).filter { model in
            !isPath(model) || fileExists((model as NSString).expandingTildeInPath)
        }
    }

    /// Remembers a model that loaded, unless it's one of the catalog's names.
    static func remember(_ model: String, defaults: UserDefaults = .standard) {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, !KapitsaConfiguration.catalogModels.contains(where: { $0.name == model.split(separator: ":").first.map(String.init) }),
              isPath(model) || model.contains("/") else { return }
        var list = defaults.stringArray(forKey: key) ?? []
        list.removeAll { $0 == model }
        defaults.set([model] + list, forKey: key)
    }

    static func forget(_ model: String, defaults: UserDefaults = .standard) {
        let list = (defaults.stringArray(forKey: key) ?? []).filter { $0 != model }
        defaults.set(list, forKey: key)
    }

    static func isPath(_ model: String) -> Bool { model.hasPrefix("/") || model.hasPrefix("~") }

    /// "Qwen3.5-9B-MLX-4bit · ~/.lmstudio/models/lmstudio-community" for a folder, the name otherwise.
    static func title(_ model: String) -> String {
        guard isPath(model) else { return model }
        let url = URL(fileURLWithPath: (model as NSString).expandingTildeInPath)
        let parent = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return url.lastPathComponent + " · " + parent
    }
}
