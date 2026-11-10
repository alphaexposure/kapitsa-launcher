import Foundation

/// Builds an explicit argument array for Kapitsa. API keys are never arguments: Kapitsa reads
/// KAPITSA_API_KEY from its environment instead.
enum KapitsaServeArguments {
    /// - Parameter installed: downloaded models by Kapitsa's name (`qwen3.6-35b-a3b:4bit`), so a
    ///   catalog model named without its precision starts the download already here.
    static func serveArguments(_ configuration: KapitsaConfiguration, installed: [String] = []) -> [String] {
        var arguments = ["serve"]
        if !configuration.model.isEmpty { arguments += ["--model", modelArgument(configuration.model, installed: installed)] }
        arguments += ["--host", configuration.host, "--port", String(configuration.port)]
        if !configuration.modelID.isEmpty { arguments += ["--model-id", configuration.modelID] }
        if !configuration.context.isEmpty { arguments += ["--context", configuration.context] }
        if !configuration.slots.isEmpty { arguments += ["--slots", configuration.slots] }
        if configuration.drafter != "auto" { arguments += ["--dflash", configuration.drafter] }
        if !configuration.memBudget.isEmpty { arguments += ["--mem-budget", configuration.memBudget] }
        if !configuration.prefillChunk.isEmpty { arguments += ["--prefill-chunk", configuration.prefillChunk] }
        if !configuration.diskCache.isEmpty { arguments += ["--disk-cache", configuration.diskCache] }
        if configuration.allowSwitch { arguments.append("--allow-switch") }
        return arguments
    }

    /// A catalog model named without its precision (`35b`), with the precision of a download
    /// already on this Mac: the default one if it's here, else another. Kapitsa itself picks
    /// the largest precision that fits the context, so at a large context `35b` would download
    /// a smaller one beside the one already here. Anything else is passed as it is.
    static func modelArgument(_ model: String, installed: [String]) -> String {
        guard !model.contains(":"),
              let catalog = KapitsaConfiguration.catalogModels.first(where: { $0.name == model || $0.id == model })
        else { return model }
        let downloaded = installed.filter { KapitsaConfiguration.catalogModel(forDownloaded: $0)?.id == catalog.id && $0.contains(":") }
        let standard = catalog.id + ":" + catalog.variant
        if downloaded.contains(standard) { return standard }
        return downloaded.first ?? model
    }
}
