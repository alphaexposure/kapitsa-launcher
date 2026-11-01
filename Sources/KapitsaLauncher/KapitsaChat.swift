import Foundation

/// How much the model reasons before it answers. Kapitsa takes this per request; which levels
/// a model offers depends on its chat template (`KapitsaThinkingOptions`). Replies keep the
/// level they were written with.
enum KapitsaThinkingLevel: String, CaseIterable, Codable, Identifiable {
    case off, on, low, medium, high, xhigh
    /// Nemotron's shorter reasoning, which Kapitsa asks for as the medium effort.
    case shorter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .shorter: return "Shorter"
        }
    }

    /// The request fields that select this level. On leaves the effort to the template.
    var requestFields: [String: Any] {
        switch self {
        case .off: return ["chat_template_kwargs": ["enable_thinking": false]]
        case .on: return ["chat_template_kwargs": ["enable_thinking": true]]
        case .shorter: return ["chat_template_kwargs": ["enable_thinking": true], "reasoning_effort": "medium"]
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
        /// About how many tokens the messages before this reply held when it was sent, so
        /// turns deleted since can be taken off its prompt count.
        var historyTokens: Int?

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
    /// The model that wrote a reply, as Kapitsa named it.
    var model: String?
    var sentAt: Date?
    var stats: Stats?
    var errorMessage: String?
    var wasStopped = false
    /// For a question: whether its reply's headings are folded away in the outline.
    var outlineCollapsed: Bool?
    /// For a reply: the broad subjects it covers, for the topic index. Nil until found.
    var topics: [String]?
    /// For a reply: the specific places it discusses, found with its topics.
    var places: [String]?
    /// For a reply: a few words naming what the question before it asked, found with its topics,
    /// for the outline. Empty when the model gave none.
    var title: String?
    /// For a question: the other versions of the conversation from this question on, made by
    /// editing it or regenerating its reply. Each starts with that version's question.
    var otherVersions: [[KapitsaChatMessage]]?
    /// For a question with other versions: where the shown one sits among them all, from 0.
    var versionIndex: Int?
    /// For a reply: side questions about it, each with its own replies. Never sent to the
    /// model with the main conversation.
    var tangents: [KapitsaTangent]?

    var versionCount: Int { (otherVersions?.count ?? 0) + 1 }

    /// A reply with text whose topics or title haven't been found yet.
    var needsTopics: Bool {
        role == .assistant && (topics == nil || title == nil) && !text.isEmpty && errorMessage == nil
    }
}

/// Versions of a conversation from one question on. Only the shown version is in the chat's
/// messages, and so in what the model reads, the outline, topics and exports; the others wait
/// on that question until shown again.
enum KapitsaChatVersions {
    /// Every version from `messages[index]` on, in order, the shown one included.
    static func all(_ messages: [KapitsaChatMessage], at index: Int) -> [[KapitsaChatMessage]] {
        var shown = Array(messages[index...])
        let others = shown[0].otherVersions ?? []
        let position = min(shown[0].versionIndex ?? others.count, others.count)
        shown[0].otherVersions = nil
        shown[0].versionIndex = nil
        var all = others
        all.insert(shown, at: position)
        return all
    }

    /// `prefix`, then version `index` of `versions`, which holds the others.
    static func showing(_ index: Int, of versions: [[KapitsaChatMessage]],
                        after prefix: ArraySlice<KapitsaChatMessage>) -> [KapitsaChatMessage] {
        var shown = versions[index]
        let others = versions.enumerated().filter { $0.offset != index }.map(\.element)
        shown[0].otherVersions = others.isEmpty ? nil : others
        shown[0].versionIndex = others.isEmpty ? nil : index
        return Array(prefix) + shown
    }

    /// The messages and those of every hidden version, at any depth.
    static func everything(_ messages: [KapitsaChatMessage]) -> [KapitsaChatMessage] {
        messages + messages.flatMap { ($0.otherVersions ?? []).flatMap(everything) }
    }
}

/// A chat that carries on from another that grew too long for the model's context: the
/// earlier chat, its name then, and a summary of it, which the model reads before the new
/// conversation.
struct KapitsaChatContinuation: Codable, Equatable {
    let chatID: UUID
    let name: String
    let summary: String
    /// Started from a side question rather than because the chat grew long: the summary
    /// covers the earlier chat up to the reply the side question was about.
    var isBranch: Bool?

    static let instructions = "This conversation continues an earlier one that grew too long to send in full. "
        + "Here is a summary of it; treat it as what was said before, and carry on from it."
    static let branchInstructions = "This conversation branches off an earlier one, from a side question. "
        + "Here is a summary of the earlier conversation up to that point; treat it as what was said before."

    /// What the model reads first: the instructions, then the summary.
    var systemPrompt: String {
        (isBranch == true ? Self.branchInstructions : Self.instructions) + "\n\n" + summary
    }
}

/// A side question about a reply: a short thread of its own under that reply. The model reads
/// the conversation up to the reply, then the thread; the main conversation never includes it.
struct KapitsaTangent: Codable, Equatable, Identifiable {
    var id = UUID()
    var messages: [KapitsaChatMessage] = []
    var isCollapsed: Bool?
    /// The new chat this side question was continued in.
    var continuedIn: UUID?

    /// Marks the first question as a side question, in what's sent only, so the model answers
    /// it on its own rather than as the next step of the conversation.
    static let marker = "(A side question about your last reply.)"
}

/// The side question's reply being written, kept apart from the chat controller so only the
/// side question's thread redraws as it arrives.
@MainActor
final class KapitsaTangentStream: ObservableObject {
    @Published private(set) var reply: KapitsaChatMessage?
    private(set) var tangentID: UUID?

    func start(_ reply: KapitsaChatMessage, in tangentID: UUID) {
        self.tangentID = tangentID
        self.reply = reply
    }

    func append(_ batch: KapitsaChatController.Batch) {
        reply?.reasoning += batch.reasoning
        reply?.text += batch.content
    }

    func end() {
        reply = nil
        tangentID = nil
    }
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
    /// - Parameter continuing: the earlier chat this one continues; its summary is sent first.
    static func body(history: [KapitsaChatMessage], thinking: KapitsaThinkingLevel, model: String,
                     continuing continuation: KapitsaChatContinuation? = nil) -> [String: Any] {
        var messages: [[String: Any]] = continuation.map { [["role": "system", "content": $0.systemPrompt]] } ?? []
        messages += history.filter { !$0.text.isEmpty || !$0.attachments.isEmpty }.map { message in
            ["role": message.role.rawValue, "content": content(for: message)]
        }
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages,
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

    /// The launcher's folder in Application Support, or `KAPITSA_LAUNCHER_HOME` when set, so a
    /// second copy can keep separate chats, such as fresh ones for screenshots.
    static var folder: URL { folder() }

    static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["KAPITSA_LAUNCHER_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KapitsaLauncher", isDirectory: true)
    }

    /// The single chat earlier versions kept, before the chat list. Moved into the list once
    /// and then left in place, unchanged, as a backup.
    static var legacy: KapitsaChatStore { KapitsaChatStore(url: folder.appendingPathComponent("chat.json")) }

    /// What the file holds: the messages, which theme each topic belongs to (themes belong to
    /// the whole chat rather than to one message), and the chat's name and dates.
    struct Document: Codable, Equatable {
        var messages: [KapitsaChatMessage] = []
        /// Topic key (see `KapitsaChatTopics.key`) to theme name.
        var topicThemes: [String: String] = [:]
        /// A name the person gave the chat; nil keeps the automatic one.
        var customName: String?
        var createdAt: Date?
        /// When the conversation last changed; folding the outline doesn't count.
        var updatedAt: Date?
        /// For a chat that continues another: which one, and the summary the model starts from.
        var continuesFrom: KapitsaChatContinuation?
        /// For a chat that was continued: the new chat.
        var continuedIn: UUID?
        /// The chat's takeaways; nil until they're made.
        var review: KapitsaChatReview?
    }

    func load() -> [KapitsaChatMessage] { loadDocument().messages }

    /// Reads the file, including the plain list of messages that earlier versions saved.
    func loadDocument() -> Document {
        Self.waitForWrites()
        guard let data = try? Data(contentsOf: url) else { return Document() }
        if let document = try? JSONDecoder().decode(Document.self, from: data) { return document }
        if let messages = try? JSONDecoder().decode([KapitsaChatMessage].self, from: data) { return Document(messages: messages) }
        // Written by a newer launcher, or damaged: the chat opens empty, and its next save would
        // replace the file, so a copy is kept first.
        keepUnreadableCopy()
        return Document()
    }

    /// Where an unreadable chat file is copied: beside it, as `<id>.json.unreadable`, which the
    /// chat list doesn't read.
    var unreadableCopyURL: URL { url.appendingPathExtension("unreadable") }

    private func keepUnreadableCopy() {
        guard !FileManager.default.fileExists(atPath: unreadableCopyURL.path) else { return }
        try? FileManager.default.copyItem(at: url, to: unreadableCopyURL)
    }

    func save(_ messages: [KapitsaChatMessage], topicThemes: [String: String] = [:]) {
        save(Document(messages: messages, topicThemes: topicThemes))
    }

    /// Chats are written one at a time, in order, off the main thread: a long chat with images
    /// is megabytes of JSON, written again for every fold or edit.
    private static let writeQueue = DispatchQueue(label: "KapitsaLauncher.chatWrites", qos: .utility)

    /// Waits for the writes already asked for: before a chat file is read, deleted or listed,
    /// and before the app quits.
    static func waitForWrites() { writeQueue.sync {} }

    /// Writes the chat in the background, then tells `done`, on the main thread, why it
    /// couldn't, or nil once it's saved.
    func save(_ document: Document, done: (@MainActor (String?) -> Void)? = nil) {
        let url = self.url
        Self.writeQueue.async {
            var problem: String?
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(document).write(to: url, options: .atomic)
            } catch {
                problem = "This chat couldn't be saved, so it won't be here after Kapitsa Launcher quits: \(error.localizedDescription)"
            }
            if let done { Task { @MainActor in done(problem) } }
        }
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// The conversation on the Chat page, streamed from the server this launcher started.
///
/// The stream is read and timed off the main thread, and the screen gets the new text in
/// batches about ten times a second. Drawing every token on a fast model left the window
/// far behind the server, and the speeds it showed measured the window, not the model.
@MainActor
final class KapitsaChatController: ObservableObject {
    typealias LineStreamer = (URLRequest) async throws -> AsyncThrowingStream<String, Error>

    /// Text that arrived since the screen was last updated.
    struct Batch: Equatable {
        var reasoning = ""
        var content = ""
        var isEmpty: Bool { reasoning.isEmpty && content.isEmpty }
    }

    /// How a reply's stream ended.
    struct Outcome: Equatable {
        var stats = KapitsaChatMessage.Stats()
        var errorMessage: String?
        var wasStopped = false
    }

    /// Finished messages. They don't change while a reply streams, so the page doesn't redraw them.
    @Published private(set) var messages: [KapitsaChatMessage]
    /// The reply being written, kept apart from `messages` until it finishes.
    @Published private(set) var liveReply: KapitsaChatMessage? {
        didSet { if (oldValue == nil) != (liveReply == nil) { onStreamingChange?(isStreaming) } }
    }
    /// The text to send. Not published: the message box keeps what's being typed and hands
    /// it over on send, so a keystroke doesn't redraw the whole Chat page.
    var draft = ""
    @Published var pendingAttachments: [KapitsaChatAttachment] = []
    @Published var attachmentError: String?
    /// Why the chat's last save failed; nil once a save works.
    @Published private(set) var saveError: String?
    /// Which theme each topic belongs to, by topic key, for the whole chat.
    @Published private(set) var topicThemes: [String: String]
    /// Finding topics for earlier replies: how many are done out of how many.
    @Published private(set) var topicProgress: TopicProgress?
    @Published var thinking: KapitsaThinkingLevel {
        didSet { defaults.set(thinking.rawValue, forKey: Self.thinkingKey) }
    }

    nonisolated static let screenUpdateInterval: Duration = .milliseconds(100)
    private static let thinkingKey = "KapitsaLauncher.chatThinking"
    private let defaults: UserDefaults
    private let store: KapitsaChatStore?
    private let streamLines: LineStreamer
    private let now: () -> Date
    private let send: KapitsaChatSummary.Send
    /// The launcher's own requests, so the Overview can say which one it shows; shared by
    /// every chat.
    let requestLabels: KapitsaRequestLabels
    private(set) var customName: String?
    /// The earlier chat this one continues, with its summary.
    @Published private(set) var continuesFrom: KapitsaChatContinuation?
    /// The new chat this one was continued in.
    @Published private(set) var continuedIn: UUID?
    private var createdAt: Date?
    private var updatedAt: Date?
    /// Called after each save, so the chat list can follow names and dates.
    var onSave: ((KapitsaChatStore.Document) -> Void)?
    /// Called when a reply or a side question's reply starts or stops being written, with
    /// whether either still is.
    var onStreamingChange: ((Bool) -> Void)?
    private var task: Task<Void, Never>?
    private var topicTask: Task<Void, Never>?
    private var tangentTask: Task<Void, Never>?
    /// The side question's reply being written, if any.
    let tangentStream = KapitsaTangentStream()
    @Published private(set) var isTangentStreaming = false {
        didSet { if oldValue != isTangentStreaming { onStreamingChange?(isStreaming) } }
    }
    /// The chat's takeaways, which the Review view shows.
    @Published private(set) var review: KapitsaChatReview
    /// Whether the model is writing takeaways.
    @Published private(set) var reviewWork: ReviewWork?
    @Published var reviewError: String?
    private var reviewTask: Task<Void, Never>?

    enum ReviewWork: Equatable { case takeaways }

    struct TopicProgress: Equatable {
        var done: Int
        let total: Int
    }

    init(store: KapitsaChatStore? = nil, defaults: UserDefaults = .standard,
         send: @escaping KapitsaChatSummary.Send = KapitsaChatSummary.urlSessionSend,
         streamLines: @escaping LineStreamer = KapitsaChatController.urlSessionLines,
         now: @escaping () -> Date = Date.init, requestLabels: KapitsaRequestLabels? = nil) {
        self.store = store
        self.requestLabels = requestLabels ?? KapitsaRequestLabels()
        self.defaults = defaults
        self.streamLines = streamLines
        self.send = send
        self.now = now
        let document = store?.loadDocument() ?? .init()
        self.messages = document.messages
        self.topicThemes = document.topicThemes
        self.customName = document.customName
        self.continuesFrom = document.continuesFrom
        self.continuedIn = document.continuedIn
        self.createdAt = document.createdAt
        self.review = document.review ?? KapitsaChatReview()
        // A file from before chats kept dates: its last message is when it was last used.
        self.updatedAt = document.updatedAt ?? document.messages.last?.sentAt
        self.thinking = defaults.string(forKey: Self.thinkingKey).flatMap(KapitsaThinkingLevel.init) ?? .xhigh
    }

    /// The reply being written, if any.
    var streamingID: UUID? { liveReply?.id }
    /// A reply or a side question's reply is being written. Kapitsa writes one at a time.
    var isStreaming: Bool { liveReply != nil || isTangentStreaming }

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
                                      attachments: pendingAttachments, sentAt: now())
        draft = ""
        pendingAttachments = []
        attachmentError = nil
        messages.append(user)
        startReply(connection: connection)
    }

    /// Sends a question again as a new version of the conversation from that question on:
    /// edited, or unchanged to regenerate its reply. The earlier versions are kept on it.
    func resend(_ questionID: UUID, text: String, connection: KapitsaChatConnection) {
        guard !isStreaming, let index = messages.firstIndex(where: { $0.id == questionID && $0.role == .user }) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = messages[index].attachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        var versions = KapitsaChatVersions.all(messages, at: index)
        versions.append([KapitsaChatMessage(role: .user, text: text, attachments: attachments, sentAt: now())])
        messages = KapitsaChatVersions.showing(versions.count - 1, of: versions, after: messages[..<index])
        startReply(connection: connection)
    }

    /// Shows another version of the conversation from this question on.
    func showVersion(_ version: Int, of questionID: UUID) {
        guard !isStreaming, let index = messages.firstIndex(where: { $0.id == questionID }) else { return }
        let versions = KapitsaChatVersions.all(messages, at: index)
        guard versions.indices.contains(version) else { return }
        messages = KapitsaChatVersions.showing(version, of: versions, after: messages[..<index])
        save(touch: false)
    }

    /// Streams a reply to the messages so far.
    private func startReply(connection: KapitsaChatConnection) {
        let reply = KapitsaChatMessage(role: .assistant, text: "", thinking: thinking, model: connection.model, sentAt: now())
        liveReply = reply

        let request: URLRequest
        do {
            request = try KapitsaChatRequest.urlRequest(
                connection: connection,
                body: KapitsaChatRequest.body(history: messages, thinking: thinking, model: connection.model,
                                              continuing: continuesFrom))
        } catch {
            finish(replyID: reply.id, outcome: Outcome(errorMessage: error.localizedDescription), connection: connection)
            return
        }
        let streamLines = self.streamLines, now = self.now
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await Self.consume(request: request, streamLines: streamLines, now: now) { batch in
                self?.apply(batch, replyID: reply.id)
            }
            await self?.finish(replyID: reply.id, outcome: outcome, connection: connection)
        }
    }

    func stop() {
        task?.cancel()
        tangentTask?.cancel()
    }

    // MARK: Side questions

    /// Asks a side question about a reply: a new thread under it, or a follow-up in `tangentID`.
    func askTangent(about replyID: UUID, in tangentID: UUID? = nil, text: String, connection: KapitsaChatConnection) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !text.isEmpty,
              let replyIndex = messages.firstIndex(where: { $0.id == replyID && $0.role == .assistant }) else { return }
        var tangents = messages[replyIndex].tangents ?? []
        let index: Int
        if let tangentID {
            guard let found = tangents.firstIndex(where: { $0.id == tangentID }), tangents[found].continuedIn == nil else { return }
            index = found
        } else {
            tangents.append(KapitsaTangent())
            index = tangents.count - 1
        }
        tangents[index].messages.append(KapitsaChatMessage(role: .user, text: text, sentAt: now()))
        tangents[index].isCollapsed = nil
        messages[replyIndex].tangents = tangents
        save()
        startTangentReply(replyID: replyID, tangentID: tangents[index].id, connection: connection)
    }

    /// What a side question sends: the conversation up to its reply, then the thread, the
    /// first question marked as a side question.
    static func tangentHistory(_ messages: [KapitsaChatMessage], replyID: UUID, tangent: KapitsaTangent) -> [KapitsaChatMessage] {
        guard let replyIndex = messages.firstIndex(where: { $0.id == replyID }) else { return [] }
        var thread = tangent.messages
        if let first = thread.indices.first { thread[first].text = KapitsaTangent.marker + "\n\n" + thread[first].text }
        return Array(messages[...replyIndex]) + thread
    }

    private func startTangentReply(replyID: UUID, tangentID: UUID, connection: KapitsaChatConnection) {
        guard let tangent = tangent(tangentID, on: replyID) else { return }
        let reply = KapitsaChatMessage(role: .assistant, text: "", thinking: thinking, model: connection.model, sentAt: now())
        tangentStream.start(reply, in: tangentID)
        isTangentStreaming = true
        let request: URLRequest
        do {
            request = try KapitsaChatRequest.urlRequest(
                connection: connection,
                body: KapitsaChatRequest.body(history: Self.tangentHistory(messages, replyID: replyID, tangent: tangent),
                                              thinking: thinking, model: connection.model, continuing: continuesFrom))
        } catch {
            finishTangent(replyID: replyID, outcome: Outcome(errorMessage: error.localizedDescription))
            return
        }
        let streamLines = self.streamLines, now = self.now
        tangentTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await Self.consume(request: request, streamLines: streamLines, now: now) { batch in
                self?.tangentStream.append(batch)
            }
            await self?.finishTangent(replyID: replyID, outcome: outcome)
        }
    }

    private func finishTangent(replyID: UUID, outcome: Outcome) {
        guard var reply = tangentStream.reply, let tangentID = tangentStream.tangentID else { return }
        reply.stats = outcome.stats
        reply.errorMessage = outcome.errorMessage
        reply.wasStopped = outcome.wasStopped
        requestLabels.record(.sideQuestion, promptTokens: outcome.stats.promptTokens, outputTokens: outcome.stats.outputTokens)
        tangentStream.end()
        tangentTask = nil
        isTangentStreaming = false
        updateTangent(tangentID, on: replyID) { $0.messages.append(reply) }
        save()
    }

    private func tangent(_ id: UUID, on replyID: UUID) -> KapitsaTangent? {
        messages.first { $0.id == replyID }?.tangents?.first { $0.id == id }
    }

    private func updateTangent(_ id: UUID, on replyID: UUID, _ change: (inout KapitsaTangent) -> Void) {
        guard let replyIndex = messages.firstIndex(where: { $0.id == replyID }),
              let index = messages[replyIndex].tangents?.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[replyIndex].tangents![index])
    }

    func setTangentCollapsed(_ id: UUID, on replyID: UUID, _ collapsed: Bool) {
        updateTangent(id, on: replyID) { $0.isCollapsed = collapsed ? true : nil }
        save(touch: false)
    }

    /// Folds or opens every side question in the chat.
    func setAllTangentsCollapsed(_ collapsed: Bool) {
        for index in messages.indices where messages[index].tangents != nil {
            for tangent in messages[index].tangents!.indices {
                messages[index].tangents![tangent].isCollapsed = collapsed ? true : nil
            }
        }
        save(touch: false)
    }

    func deleteTangent(_ id: UUID, on replyID: UUID) {
        guard !(isTangentStreaming && tangentStream.tangentID == id),
              let replyIndex = messages.firstIndex(where: { $0.id == replyID }) else { return }
        messages[replyIndex].tangents?.removeAll { $0.id == id }
        if messages[replyIndex].tangents?.isEmpty == true { messages[replyIndex].tangents = nil }
        save()
    }

    /// Notes the new chat a side question was continued in.
    func markTangentContinued(_ id: UUID, on replyID: UUID, in chatID: UUID) {
        updateTangent(id, on: replyID) {
            $0.continuedIn = chatID
            $0.isCollapsed = true
        }
        save(touch: false)
    }

    /// Makes this new, empty chat a branch of another: it starts from a summary of the other
    /// chat up to a reply, and the side question's thread becomes its first messages.
    func startBranch(_ continuation: KapitsaChatContinuation, messages thread: [KapitsaChatMessage]) {
        guard messages.isEmpty else { return }
        continuesFrom = continuation
        // New IDs: the thread now lives in two chats.
        messages = thread.map { message in
            var copy = message
            copy.id = UUID()
            return copy
        }
        save()
    }

    /// Writes the chat. A new chat has no file until its first message. `touch` marks the
    /// conversation as changed, which orders the chat list.
    private func save(touch: Bool = true) {
        // A continuation is kept from the start, so its summary isn't lost before the first message.
        guard let store, !(messages.isEmpty && continuesFrom == nil && createdAt == nil && !store.exists) else { return }
        if createdAt == nil { createdAt = messages.first?.sentAt ?? now() }
        if touch || updatedAt == nil { updatedAt = now() }
        let document = KapitsaChatStore.Document(messages: messages, topicThemes: topicThemes, customName: customName,
                                                 createdAt: createdAt, updatedAt: updatedAt,
                                                 continuesFrom: continuesFrom, continuedIn: continuedIn,
                                                 review: review.isEmpty ? nil : review)
        store.save(document) { [weak self] problem in
            if self?.saveError != problem { self?.saveError = problem }
        }
        onSave?(document)
    }

    /// Makes this new, empty chat carry on from another, starting from its summary.
    func startContinuation(_ continuation: KapitsaChatContinuation) {
        guard messages.isEmpty else { return }
        continuesFrom = continuation
        save()
    }

    /// Notes the new chat this one was continued in.
    func markContinued(in chatID: UUID) {
        continuedIn = chatID
        save(touch: false)
    }

    /// Forgets links to new chats that no longer exist, such as one moved to the Trash, so this
    /// chat, or its side question, offers to continue again. Saved only when something changed.
    func forgetMissingChats(_ exists: (UUID) -> Bool) {
        var changed = false
        if let id = continuedIn, !exists(id) {
            continuedIn = nil
            changed = true
        }
        for index in messages.indices {
            guard let tangents = messages[index].tangents,
                  tangents.contains(where: { $0.continuedIn.map { !exists($0) } ?? false }) else { continue }
            for tangent in tangents.indices where messages[index].tangents![tangent].continuedIn.map({ !exists($0) }) ?? false {
                messages[index].tangents![tangent].continuedIn = nil
            }
            changed = true
        }
        if changed { save(touch: false) }
    }

    /// Names the chat; nil or blank goes back to the automatic name.
    func rename(_ name: String?) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        customName = name?.isEmpty == false ? name : nil
        save(touch: false)
    }

    /// Removes a reply and the question before it, from the screen, the saved file and the
    /// history later messages send to the model.
    func deleteTurn(endingWith replyID: UUID) {
        let turn = Set(KapitsaChatExport.turn(endingWith: replyID, in: messages).map(\.id))
        guard !turn.isEmpty else { return }
        messages.removeAll { turn.contains($0.id) }
        save()
    }

    /// Folds or unfolds questions' headings in the outline, and saves the choice.
    func setOutlineCollapsed(_ collapsed: Bool, questions: Set<UUID>) {
        for index in messages.indices where questions.contains(messages[index].id) {
            messages[index].outlineCollapsed = collapsed ? true : nil
        }
        save(touch: false)
    }

    /// How many replies have no topics yet.
    var repliesNeedingTopics: Int { messages.filter(\.needsTopics).count }

    /// Finds topics for every reply that has none, one at a time.
    func findMissingTopics(connection: KapitsaChatConnection, regroup: Bool = false) {
        let replies = messages.filter(\.needsTopics).map(\.id)
        guard !replies.isEmpty, topicTask == nil else { return }
        topicProgress = TopicProgress(done: 0, total: replies.count)
        topicTask = Task {
            for id in replies {
                if Task.isCancelled { break }
                await findTopics(replyID: id, connection: connection)
                topicProgress?.done += 1
            }
            if !Task.isCancelled { await groupTopics(connection: connection, regroup: regroup) }
            topicProgress = nil
            topicTask = nil
        }
    }

    /// Puts topics into themes, in one request. Topics that have a theme keep it, and new ones
    /// join the existing themes where they fit, so the index doesn't reshuffle after every
    /// reply; with `regroup`, every topic is grouped afresh. A failure leaves new topics under
    /// Other until the next try.
    func groupTopics(connection: KapitsaChatConnection, regroup: Bool = false) async {
        var seen = Set<String>()
        let topics = messages.flatMap { $0.topics ?? [] }.filter { seen.insert(KapitsaChatTopics.key($0)).inserted }
        let ungrouped = regroup ? topics : topics.filter { topicThemes[KapitsaChatTopics.key($0)] == nil }
        let existing = regroup ? [] : Array(Set(topicThemes.values)).sorted()
        guard !ungrouped.isEmpty,
              let themes = try? await KapitsaChatTopics.themes(for: ungrouped, existingThemes: existing, connection: connection,
                                                               send: requestLabels.labelling(send, as: .themes)) else { return }
        if regroup { topicThemes = [:] }
        topicThemes.merge(themes) { _, new in new }
        // Themes of topics no longer in the chat, after deletes or a redo; hidden versions keep theirs.
        let kept = Set(KapitsaChatVersions.everything(messages).flatMap { $0.topics ?? [] }.map(KapitsaChatTopics.key))
        topicThemes = topicThemes.filter { kept.contains($0.key) }
        // Found in the background, sometimes long after the chat was last used.
        save(touch: false)
    }

    /// Forgets every reply's places and topics and the chat's themes, then finds them all again.
    func redoAllTopics(connection: KapitsaChatConnection) {
        stopFindingTopics()
        for index in messages.indices where messages[index].role == .assistant {
            messages[index].topics = nil
            messages[index].places = nil
            messages[index].title = nil
        }
        topicThemes = [:]
        save()
        findMissingTopics(connection: connection, regroup: true)
    }

    func stopFindingTopics() {
        topicTask?.cancel()
        topicTask = nil
        topicProgress = nil
    }

    /// Asks the model for one reply's title, places and topics and saves them. A reply that
    /// already has topics, from before titles, keeps them and only gains a title. A failure
    /// leaves them unset, so they can be found later; the chat itself is unaffected.
    func findTopics(replyID: UUID, connection: KapitsaChatConnection) async {
        guard let index = messages.firstIndex(where: { $0.id == replyID }), messages[index].needsTopics else { return }
        let question = index > 0 && messages[index - 1].role == .user ? messages[index - 1] : nil
        let existing = KapitsaChatTopics.existing(in: messages, excluding: replyID)
        guard let found = try? await KapitsaChatTopics.find(question: question, reply: messages[index],
                                                            existing: existing, connection: connection,
                                                            send: requestLabels.labelling(send, as: .topics)),
              let current = messages.firstIndex(where: { $0.id == replyID }) else { return }
        messages[current].title = found.title
        if messages[current].topics == nil {
            messages[current].topics = found.topics
            messages[current].places = found.places
        }
        save(touch: false)
    }

    func clear() {
        stop()
        stopFindingTopics()
        task = nil
        liveReply = nil
        messages = []
        topicThemes = [:]
        stopReviewWork()
        review = KapitsaChatReview()
        save()
    }

    // MARK: Review

    /// Asks for takeaways. `update` adds ones for the questions asked since, alongside the
    /// existing ones; otherwise they're written afresh, keeping pinned ones and the person's own.
    func writeTakeaways(connection: KapitsaChatConnection, contextTokens: Int?, update: Bool) {
        guard reviewTask == nil, !messages.isEmpty else { return }
        let messages = messages
        let questions = update ? Set(review.newQuestions(in: messages)) : nil
        if let questions, questions.isEmpty { return }
        let kept = review.takeaways.filter(\.isKept)
        let existing = (update ? review.takeaways : kept).map(\.text)
        reviewError = nil
        reviewWork = .takeaways
        reviewTask = Task {
            defer { reviewTask = nil; reviewWork = nil }
            do {
                let written = try await KapitsaChatReview.writeTakeaways(
                    from: messages, questions: questions, existing: existing, connection: connection,
                    contextTokens: contextTokens, send: requestLabels.labelling(send, as: .takeaways))
                guard !Task.isCancelled else { return }
                review.takeaways = (update ? review.takeaways : kept) + written
                review.coveredQuestions = messages.filter { $0.role == .user }.map(\.id)
                save(touch: false)
            } catch {
                guard !Task.isCancelled else { return }
                reviewError = "Kapitsa couldn't write the takeaways: \(error.localizedDescription)"
            }
        }
    }

    func stopReviewWork() {
        reviewTask?.cancel()
        reviewTask = nil
        reviewWork = nil
    }

    /// Adds a takeaway of the person's own; blank text adds nothing.
    func addTakeaway(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        review.takeaways.append(.init(text: text, isOwn: true))
        save(touch: false)
    }

    /// Changes a takeaway's text; blank text deletes it.
    func editTakeaway(_ id: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = review.takeaways.firstIndex(where: { $0.id == id }) else { return }
        if text.isEmpty { review.takeaways.remove(at: index) } else { review.takeaways[index].text = text }
        save(touch: false)
    }

    func setTakeawayPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = review.takeaways.firstIndex(where: { $0.id == id }) else { return }
        review.takeaways[index].pinned = pinned ? true : nil
        save(touch: false)
    }

    func deleteTakeaway(_ id: UUID) {
        review.takeaways.removeAll { $0.id == id }
        save(touch: false)
    }

    private func apply(_ batch: Batch, replyID: UUID) {
        guard liveReply?.id == replyID else { return }
        liveReply?.reasoning += batch.reasoning
        liveReply?.text += batch.content
    }

    private func finish(replyID: UUID, outcome: Outcome, connection: KapitsaChatConnection) {
        guard var reply = liveReply, reply.id == replyID else { return }
        reply.stats = outcome.stats
        reply.stats?.historyTokens = messages.reduce(0) { $0 + KapitsaChatSummary.estimatedTokens($1.text) }
        reply.errorMessage = outcome.errorMessage
        reply.wasStopped = outcome.wasStopped
        requestLabels.record(.chatReply, promptTokens: outcome.stats.promptTokens, outputTokens: outcome.stats.outputTokens)
        messages.append(reply)
        liveReply = nil
        task = nil
        save()
        // Short requests with thinking off, in the background, for the topic index: this reply's
        // places and topics, then themes for any new topics.
        if reply.needsTopics {
            Task {
                await findTopics(replyID: replyID, connection: connection)
                await groupTopics(connection: connection)
            }
        }
    }

    /// Reads the stream off the main thread, timing tokens as they arrive, and hands the text
    /// to `apply` at most every `screenUpdateInterval`, plus once at the end.
    nonisolated static func consume(request: URLRequest, streamLines: LineStreamer, now: () -> Date,
                                    apply: @escaping @MainActor (Batch) -> Void) async -> Outcome {
        var outcome = Outcome()
        var pending = Batch()
        var firstReasoning: Date?
        var firstContent: Date?
        var lastUpdate = ContinuousClock.now

        do {
            lines: for try await line in try await streamLines(request) {
                if Task.isCancelled { break }
                for event in KapitsaChatEvent.parse(line: line) ?? [] {
                    switch event {
                    case .reasoning(let text):
                        if firstReasoning == nil { firstReasoning = now() }
                        pending.reasoning += text
                    case .content(let text):
                        if firstContent == nil { firstContent = now() }
                        pending.content += text
                    case .usage(let prompt, let output):
                        outcome.stats.promptTokens = prompt
                        outcome.stats.outputTokens = output
                    case .failure(let message):
                        outcome.errorMessage = message
                        break lines
                    case .done:
                        break lines
                    }
                }
                if !pending.isEmpty && ContinuousClock.now - lastUpdate >= screenUpdateInterval {
                    let batch = pending
                    pending = Batch()
                    lastUpdate = .now
                    await apply(batch)
                }
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            outcome.errorMessage = error.localizedDescription
        }
        if !pending.isEmpty { await apply(pending) }
        // A cancelled stream may end quietly instead of throwing.
        outcome.wasStopped = Task.isCancelled

        let finished = now()
        if let firstReasoning { outcome.stats.thinkingSeconds = (firstContent ?? finished).timeIntervalSince(firstReasoning) }
        if let first = firstReasoning ?? firstContent { outcome.stats.generationSeconds = finished.timeIntervalSince(first) }
        return outcome
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
