import XCTest
@testable import KapitsaLauncher

final class KapitsaRequestMetricsTests: XCTestCase {
    private let line = "[kapitsa] chat: prompt 626 (cached 593) in 811 ms (+1.9 ms template/tokenize; last chunk: "
        + "encoded by 2.8 ms, GPU start +138.5 ms, GPU 669.7 ms, wake +0.2 ms), 885 tokens in 41304 ms "
        + "(21.4 tok/s), stop, 3.51 tok/cycle"

    func testParsesKapitsaRequestLine() throws {
        let request = try XCTUnwrap(KapitsaRequestMetrics(logLine: line, finishedAt: "17:14:02"))
        XCTAssertEqual(request.finishedAt, "17:14:02")
        XCTAssertEqual(request.promptTokens, 626)
        XCTAssertEqual(request.cachedTokens, 593)
        XCTAssertEqual(request.prefilledTokens, 33)
        XCTAssertEqual(request.prefillMilliseconds, 811)
        XCTAssertEqual(request.outputTokens, 885)
        XCTAssertEqual(request.decodeMilliseconds, 41304)
        XCTAssertEqual(request.decodeTokensPerSecond, 21.4)
        XCTAssertEqual(request.stopReason, "stop")
        XCTAssertEqual(request.tokensPerCycle, 3.51)
        XCTAssertEqual(request.totalSeconds, 42.115, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(request.prefillTokensPerSecond), 33 / 0.811, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(request.endToEndTokensPerSecond), 885 / 42.115, accuracy: 0.001)
    }

    func testParsesLineWithoutSpeculativeDecoding() throws {
        let plain = "chat: prompt 57 (cached 0) in 1034 ms (+24.9 ms template/tokenize), 35 tokens in 1321 ms (25.7 tok/s), length"
        let request = try XCTUnwrap(KapitsaRequestMetrics(logLine: plain, finishedAt: "x"))
        XCTAssertEqual(request.stopReason, "length")
        XCTAssertNil(request.tokensPerCycle)
    }

    func testIgnoresOtherLines() {
        for other in ["[kapitsa] history: prefilled 13 tokens of the rendered reply (from 51) in 351 ms",
                      "[kapitsa] KFlash: 18 cycles, 8.00 rows per cycle", ""] {
            XCTAssertNil(KapitsaRequestMetrics(logLine: other, finishedAt: "x"), other)
        }
    }

    func testSessionTotalsAddRequests() throws {
        var totals = KapitsaSessionTotals()
        XCTAssertNil(totals.decodeTokensPerSecond)
        XCTAssertNil(totals.cacheHitRate)
        totals.add(try XCTUnwrap(KapitsaRequestMetrics(logLine: line, finishedAt: "a")))
        totals.add(KapitsaRequestMetrics(finishedAt: "b", promptTokens: 100, cachedTokens: 0, prefillMilliseconds: 189,
                                         outputTokens: 115, decodeMilliseconds: 8696, decodeTokensPerSecond: nil))
        XCTAssertEqual(totals.requests, 2)
        XCTAssertEqual(totals.prefilledTokens, 133)
        XCTAssertEqual(totals.outputTokens, 1000)
        XCTAssertEqual(try XCTUnwrap(totals.prefillTokensPerSecond), 133, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(totals.decodeTokensPerSecond), 1000 / 50.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(totals.cacheHitRate), 593 / 726.0, accuracy: 0.0001)
    }

    func testEngineInfoFromStartupLines() {
        var engine = KapitsaEngineInfo()
        let lines = [
            "[kapitsa] GPU: Apple M1 Pro, 16 cores",
            "[kapitsa] memory: 21.09 GB allocated (model, buffers, 4 slots' state), budget 25.7 GB (recommended working set 26.8 GB): KV room 4.64 GB = 66591 tokens (68 KB per token), one conversation up to 32768 of 32768 tokens",
            "[kapitsa] engine ready: qwen3.8-27b, context 32768, 4 slots, KFlash speculative decoding (DFlash2 lattice, tree verify), images on",
            "[kapitsa] listening on http://127.0.0.1:8001",
        ]
        for line in lines { XCTAssertTrue(engine.apply(logLine: line), line) }
        XCTAssertFalse(engine.apply(logLine: "[kapitsa] tokenizer: 248044 tokens"))
        XCTAssertEqual(engine.gpu, "Apple M1 Pro, 16-core GPU")
        XCTAssertEqual(engine.allocatedGB, 21.09)
        XCTAssertEqual(engine.budgetGB, 25.7)
        XCTAssertEqual(engine.recommendedGB, 26.8)
        XCTAssertEqual(engine.kvRoomGB, 4.64)
        XCTAssertEqual(engine.kvTokens, 66591)
        XCTAssertEqual(engine.model, "qwen3.8-27b")
        XCTAssertEqual(engine.contextTokens, 32768)
        XCTAssertEqual(engine.slots, 4)
        XCTAssertEqual(engine.decoding, "KFlash speculative decoding (DFlash2 lattice, tree verify), images on")
        XCTAssertEqual(engine.address, "http://127.0.0.1:8001")
    }
}
