import Foundation

/// Every saved chat: one file each in `Chats/`, named by the chat's ID, plus `index.json`,
/// which lists their names and dates so the chat list doesn't read every chat to draw itself.
///
/// The chat files are the record; the index is only a cache. Entries whose file changed or
/// that are missing are rebuilt from the files, and entries without a file are dropped, so a
/// damaged or deleted index loses nothing.
@MainActor
final class KapitsaChatLibrary: ObservableObject {
    struct Summary: Codable, Equatable, Identifiable {
        let id: UUID
        var customName: String?
        /// The first question's first line, shortened.
        var firstQuestion: String
        /// The first question's title, once the model has written it.
        var firstTitle: String?
        var createdAt: Date
        var updatedAt: Date
        /// The file's modification date when this entry was made, to spot changes.
        var fileDate: Date

        func name(_ style: NameStyle) -> String {
            if let customName { return customName }
            let automatic = style == .title ? firstTitle ?? firstQuestion : firstQuestion
            return automatic.isEmpty ? "New chat" : automatic
        }
    }

    /// How chats without a name of their own are named.
    enum NameStyle: String, CaseIterable, Identifiable {
        /// The short title the model writes for the first question.
        case title
        /// The first question as written.
        case original

        var id: String { rawValue }
        var label: String { self == .title ? "Short title" : "Your first question" }
    }

    static let nameStyleKey = "KapitsaLauncher.chatNameStyle"

    /// Saved chats, the most recently used first.
    @Published private(set) var summaries: [Summary] = []
    /// Chats writing a reply right now.
    @Published private(set) var streaming: Set<UUID> = []
    /// Shared by every chat, so the Overview can label requests from any of them.
    let requestLabels = KapitsaRequestLabels()
    let folder: URL
    private var controllers: [UUID: KapitsaChatController] = [:]
    private let trash: (URL) -> Void
    private let makeController: @MainActor (KapitsaChatStore, KapitsaRequestLabels) -> KapitsaChatController

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    static var standard: KapitsaChatLibrary {
        KapitsaChatLibrary(folder: KapitsaChatStore.folder.appendingPathComponent("Chats", isDirectory: true),
                           legacy: .legacy)
    }

    /// - Parameter legacy: the single chat of earlier versions, copied in as the first chat
    ///   when the `Chats` folder doesn't exist yet. The original file is left as it is.
    /// - Parameter trash: removes a deleted chat's file; the Trash, so it can be recovered.
    init(folder: URL, legacy: KapitsaChatStore? = nil,
         trash: @escaping (URL) -> Void = { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         makeController: @escaping @MainActor (KapitsaChatStore, KapitsaRequestLabels) -> KapitsaChatController = {
             KapitsaChatController(store: $0, requestLabels: $1)
         }) {
        self.folder = folder
        self.makeController = makeController
        self.trash = trash
        if let legacy { moveIn(legacy) }
        refresh()
    }

    func url(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    /// The chat with this ID, loaded once and kept, so a reply keeps streaming into its chat
    /// while another is shown. An ID with no file is a new, empty chat.
    func controller(for id: UUID) -> KapitsaChatController {
        if let controller = controllers[id] { return controller }
        let controller = makeController(KapitsaChatStore(url: url(for: id)), requestLabels)
        controller.onSave = { [weak self] document in self?.update(id, from: document) }
        controller.onStreamingChange = { [weak self] isStreaming in
            if isStreaming { self?.streaming.insert(id) } else { self?.streaming.remove(id) }
        }
        controllers[id] = controller
        return controller
    }

    /// Chats whose messages mention `query`, with a line around the first mention. Saved chats
    /// are read off the main thread; open chats use what's on screen, which may not be saved yet.
    func search(_ query: String) async -> [UUID: KapitsaChatFind.Hit] {
        let open = controllers.mapValues(\.messages)
        let files = summaries.filter { open[$0.id] == nil }.map { ($0.id, url(for: $0.id)) }
        return await Task.detached(priority: .userInitiated) {
            var hits: [UUID: KapitsaChatFind.Hit] = [:]
            for (id, messages) in open { hits[id] = KapitsaChatFind.hit(for: query, in: messages) }
            for (id, url) in files where !Task.isCancelled {
                hits[id] = KapitsaChatFind.hit(for: query, in: KapitsaChatStore(url: url).load())
            }
            return hits
        }.value
    }

    func rename(_ id: UUID, to name: String?) {
        controller(for: id).rename(name)
    }

    /// Stops the chat if it's writing a reply and moves its file to the Trash.
    func delete(_ id: UUID) {
        if let controller = controllers.removeValue(forKey: id) {
            controller.stop()
            controller.stopFindingTopics()
            controller.onSave = nil
            controller.onStreamingChange = nil
            streaming.remove(id)
        }
        trash(url(for: id))
        summaries.removeAll { $0.id == id }
        saveIndex()
    }

    struct Group {
        let title: String
        var chats: [Summary]
    }

    /// Chats by when they were last used: Today, Yesterday, Previous 7 days, Previous 30 days,
    /// then each earlier month. Expects the most recent first.
    static func groups(_ summaries: [Summary], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        func title(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            switch days {
            case ..<1: return "Today"
            case 1: return "Yesterday"
            case 2...7: return "Previous 7 days"
            case 8...30: return "Previous 30 days"
            default:
                let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
                return date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
            }
        }
        var groups: [Group] = []
        for summary in summaries {
            let name = title(summary.updatedAt)
            if groups.last?.title == name { groups[groups.count - 1].chats.append(summary) }
            else { groups.append(Group(title: name, chats: [summary])) }
        }
        return groups
    }

    // MARK: - Index

    /// Brings the index up to date with the chat files.
    func refresh() {
        let cached = Dictionary(loadIndex().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var summaries: [Summary] = []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let date = Self.modificationDate(of: file)
            if let entry = cached[id], entry.fileDate == date {
                summaries.append(entry)
            } else if let entry = Self.summary(id: id, document: KapitsaChatStore(url: file).loadDocument(), fileDate: date) {
                summaries.append(entry)
            }
        }
        self.summaries = Self.sorted(summaries)
        if self.summaries != Self.sorted(Array(cached.values)) { saveIndex() }
    }

    private func update(_ id: UUID, from document: KapitsaChatStore.Document) {
        let entry = Self.summary(id: id, document: document, fileDate: Self.modificationDate(of: url(for: id)))
        summaries.removeAll { $0.id == id }
        if let entry { summaries.append(entry) }
        summaries = Self.sorted(summaries)
        saveIndex()
    }

    private func loadIndex() -> [Summary] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([Summary].self, from: data)) ?? []
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(summaries).write(to: indexURL, options: .atomic)
    }

    /// Nil for a chat with no messages, which isn't listed.
    static func summary(id: UUID, document: KapitsaChatStore.Document, fileDate: Date) -> Summary? {
        guard let first = document.messages.first else { return nil }
        let questionIndex = document.messages.firstIndex { $0.role == .user }
        let question = questionIndex.map { KapitsaChatOutline.question(for: document.messages[$0]) } ?? ""
        // The title is kept on the reply to the first question.
        let reply = questionIndex.flatMap { index in document.messages.dropFirst(index + 1).first { $0.role == .assistant } }
        let title = reply?.title.flatMap { $0.isEmpty ? nil : $0 }
        let created = document.createdAt ?? first.sentAt ?? fileDate
        return Summary(id: id, customName: document.customName, firstQuestion: question, firstTitle: title,
                       createdAt: created, updatedAt: document.updatedAt ?? document.messages.last?.sentAt ?? created,
                       fileDate: fileDate)
    }

    private static func sorted(_ summaries: [Summary]) -> [Summary] {
        summaries.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Copies the single chat of earlier versions in as the first chat, once: only while the
    /// `Chats` folder doesn't exist, so deleting every chat later doesn't bring it back.
    private func moveIn(_ legacy: KapitsaChatStore) {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = legacy.loadDocument()
        guard !document.messages.isEmpty else { return }
        document.createdAt = document.createdAt ?? document.messages.first?.sentAt
        document.updatedAt = document.updatedAt ?? document.messages.last?.sentAt
        KapitsaChatStore(url: url(for: UUID())).save(document)
    }
}
