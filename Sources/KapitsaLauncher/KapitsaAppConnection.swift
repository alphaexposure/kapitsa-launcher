import Foundation

/// What another app needs to use Kapitsa's server: its addresses, the model's name in the API,
/// and settings to paste. The API key itself is never part of it: the settings hold a
/// placeholder, and the key is copied on its own.
struct KapitsaAppConnection: Equatable {
    /// `http://127.0.0.1:8000`, which Anthropic-style apps such as Claude Code are given.
    let baseURL: String
    /// The model's name in the API.
    let model: String
    /// Whether the server asks apps for its API key.
    let needsAPIKey: Bool

    /// `http://127.0.0.1:8000/v1`, which OpenAI-style apps such as Qwen Code are given.
    var openAIBaseURL: String { baseURL + "/v1" }

    /// What the settings put where the key goes: a reminder to paste it, or any text when the
    /// server has no key, since most apps refuse an empty one.
    var keyPlaceholder: String { needsAPIKey ? "PASTE-YOUR-API-KEY" : "kapitsa" }

    enum Style: String, CaseIterable, Identifiable {
        case anthropic, openAI
        var id: String { rawValue }
        var title: String { self == .anthropic ? "Anthropic-style (Claude Code)" : "OpenAI-style (Qwen Code, Codex, Cline)" }
    }

    /// The environment variables an app of this style reads, in order.
    func environment(_ style: Style) -> [(name: String, value: String)] {
        switch style {
        case .anthropic:
            // Claude Code also asks for its Haiku, Sonnet and Opus models by name; naming the
            // model for each keeps those requests from naming a model Kapitsa doesn't have.
            return [("ANTHROPIC_BASE_URL", baseURL), ("ANTHROPIC_AUTH_TOKEN", keyPlaceholder),
                    ("ANTHROPIC_MODEL", model), ("ANTHROPIC_DEFAULT_OPUS_MODEL", model),
                    ("ANTHROPIC_DEFAULT_SONNET_MODEL", model), ("ANTHROPIC_DEFAULT_HAIKU_MODEL", model)]
        case .openAI:
            return [("OPENAI_BASE_URL", openAIBaseURL), ("OPENAI_API_KEY", keyPlaceholder), ("OPENAI_MODEL", model)]
        }
    }

    /// `export NAME="value"` lines for a terminal or a shell profile.
    func shellText(_ style: Style) -> String {
        environment(style).map { "export \($0.name)=\"\($0.value)\"" }.joined(separator: "\n")
    }

    /// A JSON object, as the `env` of Claude Code's settings.json takes.
    func jsonText(_ style: Style) -> String {
        let lines = environment(style).map { "  \"\($0.name)\": \"\($0.value)\"" }
        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }

    /// - Parameters:
    ///   - host: the address Kapitsa listens on; 0.0.0.0 is reached on this Mac at 127.0.0.1.
    ///   - engineModel: the model Kapitsa says it loaded, nil before it's ready. It names a
    ///     catalog model without its precision (`qwen3.6-35b-a3b`).
    ///   - configured: the Model setting the server was started with.
    ///   - installed: downloaded models by Kapitsa's name (`qwen3.6-35b-a3b:4bit`).
    init(host: String, port: Int, modelID: String, engineModel: String?, configured: String,
         installed: [String], needsAPIKey: Bool) {
        let reachable = host == "0.0.0.0" ? "127.0.0.1" : host
        baseURL = "http://\(reachable):\(port)"
        model = Self.apiName(modelID: modelID, engineModel: engineModel, configured: configured, installed: installed)
        self.needsAPIKey = needsAPIKey
    }

    /// The name that always reaches this model: a catalog model's full name with its precision
    /// (`qwen3.6-35b-a3b:4bit`), which never makes Kapitsa load another precision when apps may
    /// switch models; a converted GGUF's folder name; otherwise the name Kapitsa reports.
    static func apiName(modelID: String, engineModel: String?, configured: String, installed: [String]) -> String {
        if !modelID.isEmpty { return modelID }
        let configured = configured.trimmingCharacters(in: .whitespaces)
        let configuredName = ModelMenu.importedName(of: configured)
            ?? KapitsaServeArguments.modelArgument(configured, installed: installed)
        guard let engineModel, !engineModel.isEmpty else {
            return configuredName.isEmpty ? "kapitsa" : configuredName
        }
        guard !engineModel.contains(":"),
              let catalog = KapitsaConfiguration.catalogModels.first(where: { $0.id == engineModel })
        else { return engineModel }
        // The configured precision when the loaded model is the configured one, else the one downloaded.
        if KapitsaConfiguration.catalogModel(forDownloaded: configuredName)?.id == catalog.id, configuredName.contains(":") {
            return configuredName
        }
        let downloaded = KapitsaServeArguments.modelArgument(catalog.name, installed: installed)
        return downloaded.contains(":") ? downloaded : catalog.id + ":" + catalog.variant
    }
}
