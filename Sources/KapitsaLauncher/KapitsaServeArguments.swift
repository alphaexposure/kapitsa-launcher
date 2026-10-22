import Foundation

/// Builds an explicit argument array for Kapitsa. API keys are never arguments: Kapitsa reads
/// KAPITSA_API_KEY from its environment instead.
enum KapitsaServeArguments {
    static func serveArguments(_ configuration: KapitsaConfiguration) -> [String] {
        var arguments = ["serve"]
        if !configuration.model.isEmpty { arguments += ["--model", configuration.model] }
        arguments += ["--host", configuration.host, "--port", String(configuration.port)]
        if !configuration.modelID.isEmpty { arguments += ["--model-id", configuration.modelID] }
        if !configuration.context.isEmpty { arguments += ["--context", configuration.context] }
        if !configuration.slots.isEmpty { arguments += ["--slots", configuration.slots] }
        if configuration.dflash != "auto" { arguments += ["--dflash", configuration.dflash] }
        if !configuration.memBudget.isEmpty { arguments += ["--mem-budget", configuration.memBudget] }
        if !configuration.prefillChunk.isEmpty { arguments += ["--prefill-chunk", configuration.prefillChunk] }
        if !configuration.diskCache.isEmpty { arguments += ["--disk-cache", configuration.diskCache] }
        if configuration.allowSwitch { arguments.append("--allow-switch") }
        return arguments
    }
}
