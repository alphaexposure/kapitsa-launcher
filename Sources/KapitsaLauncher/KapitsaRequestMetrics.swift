import Foundation

/// Matches one regular expression against a log line and returns its capture groups.
private func captures(_ pattern: NSRegularExpression, in line: String) -> [String]? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = pattern.firstMatch(in: line, range: range) else { return nil }
    return (1..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
    }
}

private func regex(_ pattern: String) -> NSRegularExpression {
    // The patterns are fixed literals, so a failure here is a programming error.
    try! NSRegularExpression(pattern: pattern)
}

/// One finished request, parsed from the line Kapitsa prints when it answers, e.g.
/// `[kapitsa] chat: prompt 56 (cached 0) in 2052 ms (+34.8 ms template/tokenize; …),
/// 66 tokens in 2947 ms (22.1 tok/s), stop, 3.61 tok/cycle`.
struct KapitsaRequestMetrics: Equatable {
    /// Kapitsa's request lines carry no time, so the launcher records when it read the line.
    let finishedAt: String
    let promptTokens: Int
    let cachedTokens: Int
    /// Prompt processing time, as Kapitsa measured it.
    let prefillMilliseconds: Double
    let outputTokens: Int
    /// Time spent generating the output tokens, after the prompt was processed.
    let decodeMilliseconds: Double
    let decodeTokensPerSecond: Double?
    /// Why generation ended, e.g. `stop` or `length`.
    let stopReason: String?
    /// Tokens accepted per speculative decoding cycle, when Kapitsa reports it.
    let tokensPerCycle: Double?

    init(finishedAt: String, promptTokens: Int, cachedTokens: Int, prefillMilliseconds: Double,
         outputTokens: Int, decodeMilliseconds: Double, decodeTokensPerSecond: Double?,
         stopReason: String? = nil, tokensPerCycle: Double? = nil) {
        self.finishedAt = finishedAt
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.prefillMilliseconds = prefillMilliseconds
        self.outputTokens = outputTokens
        self.decodeMilliseconds = decodeMilliseconds
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.stopReason = stopReason
        self.tokensPerCycle = tokensPerCycle
    }

    private static let pattern = regex(
        #"chat: prompt (\d+) \(cached (\d+)\) in ([\d.]+) ms .*?, (\d+) tokens in ([\d.]+) ms \(([\d.]+) tok/s\)(?:, ([A-Za-z_]+))?(?:.*?, ([\d.]+) tok/cycle)?"#)

    /// Returns nil for any line that is not a finished request.
    init?(logLine: some StringProtocol, finishedAt: String) {
        guard let groups = captures(Self.pattern, in: String(logLine)),
              let prompt = Int(groups[0]), let cached = Int(groups[1]),
              let prefill = Double(groups[2]), let output = Int(groups[3]),
              let decode = Double(groups[4]) else { return nil }
        self.init(finishedAt: finishedAt, promptTokens: prompt, cachedTokens: cached,
                  prefillMilliseconds: prefill, outputTokens: output, decodeMilliseconds: decode,
                  decodeTokensPerSecond: Double(groups[5]),
                  stopReason: groups[6].isEmpty ? nil : groups[6],
                  tokensPerCycle: Double(groups[7]))
    }

    /// Prompt tokens Kapitsa actually had to process; cached tokens are reused.
    var prefilledTokens: Int { max(0, promptTokens - cachedTokens) }

    var prefillSeconds: Double { prefillMilliseconds / 1000 }
    var decodeSeconds: Double { decodeMilliseconds / 1000 }
    var totalSeconds: Double { prefillSeconds + decodeSeconds }

    var prefillTokensPerSecond: Double? {
        guard prefillSeconds > 0, prefilledTokens > 0 else { return nil }
        return Double(prefilledTokens) / prefillSeconds
    }

    var endToEndTokensPerSecond: Double? {
        guard totalSeconds > 0 else { return nil }
        return Double(outputTokens) / totalSeconds
    }
}

/// Every request this server session has finished, added up.
struct KapitsaSessionTotals: Equatable {
    var requests = 0
    var promptTokens = 0
    var prefilledTokens = 0
    var cachedTokens = 0
    var outputTokens = 0
    var prefillSeconds = 0.0
    var decodeSeconds = 0.0

    mutating func add(_ request: KapitsaRequestMetrics) {
        requests += 1
        promptTokens += request.promptTokens
        prefilledTokens += request.prefilledTokens
        cachedTokens += request.cachedTokens
        outputTokens += request.outputTokens
        prefillSeconds += request.prefillSeconds
        decodeSeconds += request.decodeSeconds
    }

    var prefillTokensPerSecond: Double? {
        prefillSeconds > 0 && prefilledTokens > 0 ? Double(prefilledTokens) / prefillSeconds : nil
    }

    var decodeTokensPerSecond: Double? {
        decodeSeconds > 0 && outputTokens > 0 ? Double(outputTokens) / decodeSeconds : nil
    }

    /// The share of prompt tokens served from Kapitsa's prefix cache.
    var cacheHitRate: Double? {
        promptTokens > 0 ? Double(cachedTokens) / Double(promptTokens) : nil
    }
}

/// What Kapitsa reports about the loaded engine while it starts. It has no status endpoint
/// beyond `/health`, so these values come from its startup lines.
struct KapitsaEngineInfo: Equatable {
    var model: String?
    var contextTokens: Int?
    var slots: Int?
    /// How Kapitsa decodes, e.g. `KFlash speculative decoding (DFlash2 lattice, tree verify), images on`.
    var decoding: String?
    var gpu: String?
    var allocatedGB: Double?
    var budgetGB: Double?
    var recommendedGB: Double?
    var kvRoomGB: Double?
    var kvTokens: Int?
    var address: String?

    private static let ready = regex(#"engine ready: (.+?), context (\d+), (\d+) slots?(?:, (.+))?$"#)
    private static let memory = regex(
        #"memory: ([\d.]+) GB allocated .*?budget ([\d.]+) GB \(recommended working set ([\d.]+) GB\): KV room ([\d.]+) GB = (\d+) tokens"#)
    private static let gpuLine = regex(#"GPU: (.+?), (\d+) cores"#)
    private static let listening = regex(#"listening on (https?://\S+)"#)

    /// Updates the values a startup line reports. Returns whether the line was recognised.
    @discardableResult
    mutating func apply(logLine: some StringProtocol) -> Bool {
        let line = String(logLine).trimmingCharacters(in: .whitespacesAndNewlines)
        if let groups = captures(Self.ready, in: line) {
            model = groups[0]
            contextTokens = Int(groups[1])
            slots = Int(groups[2])
            decoding = groups[3].isEmpty ? nil : groups[3]
        } else if let groups = captures(Self.memory, in: line) {
            allocatedGB = Double(groups[0])
            budgetGB = Double(groups[1])
            recommendedGB = Double(groups[2])
            kvRoomGB = Double(groups[3])
            kvTokens = Int(groups[4])
        } else if let groups = captures(Self.gpuLine, in: line) {
            gpu = "\(groups[0]), \(groups[1])-core GPU"
        } else if let groups = captures(Self.listening, in: line) {
            address = groups[0]
        } else {
            return false
        }
        return true
    }
}
