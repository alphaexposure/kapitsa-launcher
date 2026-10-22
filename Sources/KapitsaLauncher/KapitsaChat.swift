import Foundation

/// How much the model reasons before it answers. Kapitsa takes this per request: Qwen templates
/// read `enable_thinking`, and the Qwen3.8 27B also reads `reasoning_effort`.
enum KapitsaThinkingLevel: String, CaseIterable, Codable, Identifiable {
    case off, low, medium, xhigh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .xhigh: return "Extra high"
        }
    }

    /// The request fields that select this level.
    var requestFields: [String: Any] {
        switch self {
        case .off: return ["chat_template_kwargs": ["enable_thinking": false]]
        default: return ["chat_template_kwargs": ["enable_thinking": true], "reasoning_effort": rawValue]
        }
    }
}

/// A file added to a message: an image Kapitsa reads itself, or a document's extracted text.
struct KapitsaChatAttachment: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case image, document }

    var id = UUID()
    let name: String
    let kind: Kind
    /// JPEG or PNG bytes, for images.
    var imageData: Data?
    var imageMIMEType: String?
    /// Extracted text, for documents.
    var text: String?
    /// Whether the document was longer than the launcher sends.
    var truncated = false
}

struct KapitsaChatMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, assistant }

    struct Stats: Codable, Equatable {
        var outputTokens: Int?
        var promptTokens: Int?
        /// Time from the first reasoning token to the first answer token.
        var thinkingSeconds: Double?
        var generationSeconds: Double?

        var tokensPerSecond: Double? {
            guard let outputTokens, let generationSeconds, generationSeconds > 0 else { return nil }
            return Double(outputTokens) / generationSeconds
        }
    }

    var id = UUID()
    let role: Role
    var text: String
    var reasoning = ""
    var attachments: [KapitsaChatAttachment] = []
    var thinking: KapitsaThinkingLevel?
    var stats: Stats?
    var errorMessage: String?
    var wasStopped = false
}

/// Where the chat sends requests: the server this launcher started.
struct KapitsaChatConnection: Equatable {
    let baseURL: URL
    let apiKey: String?
    let model: String

    var completionsURL: URL { baseURL.appendingPathComponent("v1/chat/completions") }
}

enum KapitsaChatRequest {
    /// Documents go in front of the typed text, each wrapped in a tag with its name.
    static func promptText(for message: KapitsaChatMessage) -> String {
        let documents = message.attachments.filter { $0.kind == .document }.map { document in
            let note = document.truncated ? " truncated=\"true\"" : ""
            return "<document name=\"\(document.name)\"\(note)>\n\(document.text ?? "")\n</document>"
        }
        return (documents + [message.text]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func content(for message: KapitsaChatMessage) -> Any {
        let images = message.attachments.filter { $0.kind == .image && $0.imageData != nil }
        let text = promptText(for: message)
        guard message.role == .user, !images.isEmpty else { return text }
        var parts: [[String: Any]] = images.map { image in
            let mime = image.imageMIMEType ?? "image/jpeg"
            return ["type": "image_url",
                    "image_url": ["url": "data:\(mime);base64,\(image.imageData!.base64EncodedString())"]]
        }
        if !text.isEmpty { parts.append(["type": "text", "text": text]) }
        return parts
    }

    /// The JSON body for a streamed chat completion. Earlier reasoning is not sent back.
    static func body(history: [KapitsaChatMessage], thinking: KapitsaThinkingLevel, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": history.filter { !$0.text.isEmpty || !$0.attachments.isEmpty }.map { message in
                ["role": message.role.rawValue, "content": content(for: message)]
            },
        ]
        body.merge(thinking.requestFields) { _, new in new }
        return body
    }

    static func urlRequest(connection: KapitsaChatConnection, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: connection.completionsURL)
        request.httpMethod = "POST"
        // Long thinking can pause the stream, so allow a generous gap between chunks.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = connection.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// One server-sent event from a streamed chat completion.
enum KapitsaChatEvent: Equatable {
    case reasoning(String)
    case content(String)
    case usage(promptTokens: Int?, outputTokens: Int?)
    case failure(String)
    case done

    /// Reads one `data:` line. Other lines (comments, blank keep-alives) give nil.
    static func parse(line: String) -> [KapitsaChatEvent]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [.done] }
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = object["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? "\(error)"
            return [.failure(message)]
        }
        var events: [KapitsaChatEvent] = []
        if let choice = (object["choices"] as? [[String: Any]])?.first,
           let delta = choice["delta"] as? [String: Any] {
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { events.append(.reasoning(reasoning)) }
            if let content = delta["content"] as? String, !content.isEmpty { events.append(.content(content)) }
        }
        if let usage = object["usage"] as? [String: Any] {
            events.append(.usage(promptTokens: usage["prompt_tokens"] as? Int,
                                 outputTokens: usage["completion_tokens"] as? Int))
        }
        return events
    }
}

enum KapitsaChatError: LocalizedError {
    case httpStatus(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return body.isEmpty ? "Kapitsa answered HTTP \(code)." : "Kapitsa answered HTTP \(code): \(body)"
        case .invalidResponse: return "Kapitsa sent an invalid response."
        }
    }
}

/// Keeps the conversation between launches, in the launcher's Application Support folder.
struct KapitsaChatStore {
    let url: URL

    static var standard: KapitsaChatStore {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KapitsaLauncher", isDirectory: true)
        return KapitsaChatStore(url: folder.appendingPathComponent("chat.json"))
    }

    func load() -> [KapitsaChatMessage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([KapitsaChatMessage].self, from: data)) ?? []
    }

    func save(_ messages: [KapitsaChatMessage]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(messages).write(to: url, options: .atomic)
        } catch {
            // The conversation still works; it just won't be there after a relaunch.
        }
    }
}

/// The conversation on the Chat page, streamed from the server this launcher started.
@MainActor
final class KapitsaChatController: ObservableObject {
    typealias LineStreamer = (URLRequest) async throws -> AsyncThrowingStream<String, Error>

    @Published private(set) var messages: [KapitsaChatMessage]
    @Published var draft = ""
    @Published var pendingAttachments: [KapitsaChatAttachment] = []
    @Published var attachmentError: String?
    @Published var thinking: KapitsaThinkingLevel {
        didSet { defaults.set(thinking.rawValue, forKey: Self.thinkingKey) }
    }
    /// The assistant message being written, if any.
    @Published private(set) var streamingID: UUID?

    private static let thinkingKey = "KapitsaLauncher.chatThinking"
    private let defaults: UserDefaults
    private let store: KapitsaChatStore?
    private let streamLines: LineStreamer
    private let now: () -> Date
    private var task: Task<Void, Never>?

    init(store: KapitsaChatStore? = .standard, defaults: UserDefaults = .standard,
         streamLines: @escaping LineStreamer = KapitsaChatController.urlSessionLines,
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.defaults = defaults
        self.streamLines = streamLines
        self.now = now
        self.messages = store?.load() ?? []
        self.thinking = defaults.string(forKey: Self.thinkingKey).flatMap(KapitsaThinkingLevel.init) ?? .xhigh
    }

    var isStreaming: Bool { streamingID != nil }

    var canSend: Bool {
        !isStreaming && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
    }

    func addAttachments(_ attachments: [KapitsaChatAttachment]) {
        pendingAttachments += attachments
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func send(to connection: KapitsaChatConnection) {
        guard canSend else { return }
        let user = KapitsaChatMessage(role: .user, text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                      attachments: pendingAttachments)
        draft = ""
        pendingAttachments = []
        attachmentError = nil
        messages.append(user)
        let history = messages
        let reply = KapitsaChatMessage(role: .assistant, text: "", thinking: thinking)
        messages.append(reply)
        streamingID = reply.id

        let body = KapitsaChatRequest.body(history: history, thinking: thinking, model: connection.model)
        task = Task { [weak self] in
            await self?.stream(body: body, connection: connection, replyID: reply.id)
        }
    }

    func stop() {
        task?.cancel()
    }

    func clear() {
        stop()
        messages = []
        streamingID = nil
        store?.save(messages)
    }

    private func stream(body: [String: Any], connection: KapitsaChatConnection, replyID: UUID) async {
        var firstReasoning: Date?
        var firstContent: Date?
        var stats = KapitsaChatMessage.Stats()
        func update(_ change: (inout KapitsaChatMessage) -> Void) {
            guard let index = messages.firstIndex(where: { $0.id == replyID }) else { return }
            change(&messages[index])
        }

        do {
            let request = try KapitsaChatRequest.urlRequest(connection: connection, body: body)
            lines: for try await line in try await streamLines(request) {
                try Task.checkCancellation()
                for event in KapitsaChatEvent.parse(line: line) ?? [] {
                    switch event {
                    case .reasoning(let text):
                        if firstReasoning == nil { firstReasoning = now() }
                        update { $0.reasoning += text }
                    case .content(let text):
                        if firstContent == nil { firstContent = now() }
                        update { $0.text += text }
                    case .usage(let prompt, let output):
                        stats.promptTokens = prompt
                        stats.outputTokens = output
                    case .failure(let message):
                        update { $0.errorMessage = message }
                        break lines
                    case .done:
                        break lines
                    }
                }
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            update { $0.errorMessage = error.localizedDescription }
        }
        // A cancelled stream may end quietly instead of throwing.
        if Task.isCancelled { update { $0.wasStopped = true } }

        let finished = now()
        if let firstReasoning { stats.thinkingSeconds = (firstContent ?? finished).timeIntervalSince(firstReasoning) }
        if let first = firstReasoning ?? firstContent { stats.generationSeconds = finished.timeIntervalSince(first) }
        update { $0.stats = stats }
        streamingID = nil
        task = nil
        store?.save(messages)
    }

    /// Streams the response's lines, failing with the server's message on an HTTP error.
    nonisolated static func urlSessionLines(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw KapitsaChatError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 300 { break }
            }
            throw KapitsaChatError.httpStatus(http.statusCode, String(body.prefix(300)))
        }
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}
