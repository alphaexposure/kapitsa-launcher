import Foundation
import XCTest
@testable import KapitsaLauncher

@MainActor
final class KapitsaRequestLabelsTests: XCTestCase {
    private func request(prompt: Int, output: Int) -> KapitsaRequestMetrics {
        KapitsaRequestMetrics(finishedAt: "12:00:00", promptTokens: prompt, cachedTokens: 0, prefillMilliseconds: 100,
                              outputTokens: output, decodeMilliseconds: 100, decodeTokensPerSecond: 10)
    }

    func testRequestsAreMatchedByTheirTokenCounts() {
        let labels = KapitsaRequestLabels()
        labels.record(.chatReply, promptTokens: 900, outputTokens: 40)
        labels.record(.topics, promptTokens: 1_200, outputTokens: 40)
        labels.record(.themes, promptTokens: nil, outputTokens: 12)
        labels.record(.summary, promptTokens: 5, outputTokens: nil)
        XCTAssertEqual(labels.kind(of: request(prompt: 900, output: 40)), .chatReply)
        XCTAssertEqual(labels.kind(of: request(prompt: 1_200, output: 40)), .topics)
        XCTAssertEqual(labels.kind(of: request(prompt: 300, output: 12)), .themes, "a reply without a prompt count")
        XCTAssertNil(labels.kind(of: request(prompt: 900, output: 41)), "sent by something else")
    }

    func testLabellingRecordsTheUsageOfEachReply() async throws {
        let labels = KapitsaRequestLabels()
        let send = labels.labelling({ _ in
            try JSONSerialization.data(withJSONObject: ["usage": ["prompt_tokens": 700, "completion_tokens": 9]])
        }, as: .topics)
        _ = try await send(URLRequest(url: URL(string: "http://127.0.0.1:8000/")!))
        XCTAssertEqual(labels.labels, [.init(kind: .topics, promptTokens: 700, outputTokens: 9)])
    }
}
