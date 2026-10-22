import Foundation

/// A summary of a chat, written by the running model for an export. Thinking is off, so it's
/// quick. The model reads the questions and replies only: reasoning is left out and attachments
/// are named. A chat too long for the model's context is summarised in sections, then combined.
struct KapitsaChatSummary: Equatable {
    let text: String
    /// The model that wrote it, as Kapitsa named it.
    let model: String

    typealias Send = @Sendable (URLRequest) async throws -> Data

    enum Failure: LocalizedError, Equatable {
        case server(String)
        case emptyReply

        var errorDescription: String? {
            switch self {
            case .server(let message): return "Kapitsa couldn't write the summary: \(message)"
            case .emptyReply: return "Kapitsa returned an empty summary."
            }
        }
    }

    static let instructions = """
    You summarise a conversation between a person and an AI assistant, for the person to keep. \
    Write Markdown in this shape: first a short paragraph saying what the conversation was about \
    and what it concluded, with no heading. Then a "### Main points" heading with bullet points of \
    the key facts, recommendations and decisions. Then, only if any remain, an "### Open questions" \
    heading with bullet points. Use only what the conversation says; add no new advice. Be concise.
    """

    static let combineInstructions = """
    These are summaries of consecutive parts of one conversation between a person and an AI \
    assistant. Combine them into a single summary in the same shape: a short opening paragraph \
    with no heading, then "### Main points", then "### Open questions" only if any remain. \
    Merge repeated points and keep it concise.
    """

    /// Roughly how many tokens of conversation fit in one request, leaving room for the reply.
    static func sectionBudget(contextTokens: Int?) -> Int {
        max(2_000, Int(Double(contextTokens ?? 32_768) * 0.6))
    }

    /// A rough token count for text: about four characters per token for English.
    static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    /// The conversation as plain text for the model: numbered questions and replies.
    static func transcript(_ messages: [KapitsaChatMessage]) -> [String] {
        var turns: [String] = []
        var question = 0
        for message in messages {
            switch message.role {
            case .user:
                question += 1
                var parts = ["Question \(question):"]
                for attachment in message.attachments {
                    parts.append("[Attached \(attachment.kind == .image ? "image" : "document"): \(attachment.name)]")
                }
                if !message.text.isEmpty { parts.append(message.text) }
                turns.append(parts.joined(separator: "\n"))
            case .assistant:
                guard !message.text.isEmpty else { continue }
                turns.append("Reply \(max(question, 1)):\n" + message.text)
            }
        }
        return turns
    }

    /// Splits the transcript into sections that each fit `budget` tokens. A single turn
    /// longer than that is cut, since the model couldn't read it whole anyway.
    static func sections(_ turns: [String], budget: Int) -> [String] {
        var sections: [String] = []
        var current: [String] = []
        var size = 0
        for turn in turns {
            var turn = turn
            if estimatedTokens(turn) > budget { turn = String(turn.prefix(budget * 4)) + "\n[…cut]" }
            let turnSize = estimatedTokens(turn)
            if size + turnSize > budget, !current.isEmpty {
                sections.append(current.joined(separator: "\n\n"))
                current = []
                size = 0
            }
            current.append(turn)
            size += turnSize
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n\n")) }
        return sections
    }

    static func requestBody(instructions: String, text: String, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "temperature": 0.3,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": text]],
        ]
        body.merge(KapitsaThinkingLevel.off.requestFields) { _, new in new }
        return body
    }

    /// The reply's text from a non-streamed chat completion.
    static func replyText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.server(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let error = json["error"] as? [String: Any] {
            throw Failure.server(error["message"] as? String ?? "unknown error")
        }
        let message = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        // Some templates still wrap a stray thought in <think> tags; keep only the answer.
        var text = (message?["content"] as? String ?? "")
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyReply }
        return text
    }

    /// Asks the model for a summary of `messages`, in sections if the chat is long.
    static func write(for messages: [KapitsaChatMessage], connection: KapitsaChatConnection,
                      contextTokens: Int?, send: Send = urlSessionSend) async throws -> KapitsaChatSummary {
        func ask(_ instructions: String, _ text: String) async throws -> String {
            var request = try KapitsaChatRequest.urlRequest(
                connection: connection,
                body: requestBody(instructions: instructions, text: text, model: connection.model))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return try replyText(from: try await send(request))
        }
        let parts = sections(transcript(messages), budget: sectionBudget(contextTokens: contextTokens))
        var summaries: [String] = []
        for part in parts {
            try Task.checkCancellation()
            summaries.append(try await ask(instructions, part))
        }
        if summaries.count > 1 {
            try Task.checkCancellation()
            let numbered = summaries.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }
            summaries = [try await ask(combineInstructions, numbered.joined(separator: "\n\n"))]
        }
        guard let text = summaries.first else { throw Failure.emptyReply }
        return KapitsaChatSummary(text: text, model: connection.model)
    }

    static let urlSessionSend: Send = { request in
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
