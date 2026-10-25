import Foundation

/// What the launcher itself asked Kapitsa, remembered by the token counts each reply reported,
/// so the Overview can tell a chat reply from the background requests for the topic index and
/// from an export summary. Kapitsa's request lines don't say who sent a request; the counts
/// they print are the same ones its replies report.
@MainActor
final class KapitsaRequestLabels: ObservableObject {
    enum Kind: Equatable {
        case chatReply, topics, themes, summary, takeaways, quiz, quizCheck

        var title: String {
            switch self {
            case .chatReply: return "Chat reply"
            case .topics: return "Places and topics for a reply · background"
            case .themes: return "Grouping topics into themes · background"
            case .summary: return "Export summary"
            case .takeaways: return "Takeaways for a chat"
            case .quiz: return "Quiz questions"
            case .quizCheck: return "Checking a quiz answer"
            }
        }
    }

    struct Label: Equatable {
        let kind: Kind
        let promptTokens: Int?
        let outputTokens: Int
    }

    /// The most recent first.
    @Published private(set) var labels: [Label] = []
    static let limit = 100

    func record(_ kind: Kind, promptTokens: Int?, outputTokens: Int?) {
        guard let outputTokens else { return }
        labels.insert(Label(kind: kind, promptTokens: promptTokens, outputTokens: outputTokens), at: 0)
        if labels.count > Self.limit { labels.removeLast() }
    }

    /// The launcher's own request with the same counts, the most recent one if several match;
    /// nil for a request something else sent, such as Kapitsa's web page or another app.
    func kind(of request: KapitsaRequestMetrics) -> Kind? {
        let candidates = labels.filter { $0.outputTokens == request.outputTokens }
        return (candidates.first { $0.promptTokens == request.promptTokens } ?? candidates.first)?.kind
    }

    /// `send`, recording each reply's usage as `kind`.
    func labelling(_ send: @escaping KapitsaChatSummary.Send, as kind: Kind) -> KapitsaChatSummary.Send {
        { [weak self] request in
            let data = try await send(request)
            let usage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["usage"] as? [String: Any]
            let prompt = usage?["prompt_tokens"] as? Int, output = usage?["completion_tokens"] as? Int
            await self?.record(kind, promptTokens: prompt, outputTokens: output)
            return data
        }
    }
}
