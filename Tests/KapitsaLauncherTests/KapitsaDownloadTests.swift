import XCTest
@testable import KapitsaLauncher

final class KapitsaDownloadTests: XCTestCase {
    func testFollowsADownloadFromItsLogLines() throws {
        var engine = KapitsaEngineInfo()
        engine.apply(logLine: "Fetching the file list of lmstudio-community/Qwen3.5-2B-MLX-4bit from huggingface.co...")
        XCTAssertNil(engine.download, "a start that downloads nothing fetches the list too")

        engine.apply(logLine: "Downloading lmstudio-community/Qwen3.5-2B-MLX-4bit (4bit) into ~/.cache/kapitsa/models/x")
        XCTAssertEqual(engine.download?.name, "lmstudio-community/Qwen3.5-2B-MLX-4bit")
        XCTAssertNil(engine.download?.percent)

        engine.apply(logLine: "  812 MB of 1.75 GB   46%   60.2 MB/s  15s left")
        let download = try XCTUnwrap(engine.download)
        XCTAssertEqual(download.percent, 46)
        XCTAssertEqual(download.summary, "Downloading lmstudio-community/Qwen3.5-2B-MLX-4bit · 812 MB of 1.75 GB · 60 MB/s · about 15s left")

        engine.apply(logLine: "  1.20 GB of 1.75 GB   69%   61.0 MB/s  9s left")
        XCTAssertEqual(engine.download?.summary.contains("1.20 of 1.75 GB"), true, "one unit when both share it")

        engine.apply(logLine: "Downloaded 1.75 GB in 29s (60 MB/s).")
        XCTAssertNil(engine.download)
    }

    func testEngineReadyEndsAnyDownload() {
        var engine = KapitsaEngineInfo()
        engine.apply(logLine: "Downloading qwen3.5-2b (4bit) into ~/x")
        engine.apply(logLine: "[kapitsa] engine ready: qwen3.5-2b, context 131072, 3 slots")
        XCTAssertNil(engine.download)
        XCTAssertEqual(engine.model, "qwen3.5-2b")
    }
}

final class LogsPageTests: XCTestCase {
    func testSortsLinesIntoRequestsAndProblems() {
        let log = """
        [kapitsa] engine ready: qwen3.6-35b-a3b, context 131072, 3 slots
        [kapitsa] chat: prompt 120 (cached 0) in 140 ms (+1.0 ms template/tokenize), 16 tokens in 200 ms (79.2 tok/s), stop
        Can't reach huggingface.co to see which model fits this Mac (offline?)
        [kapitsa] warning: slow disk
        """
        XCTAssertEqual(LogsPage.lines(log, show: .all, filter: "").count, 4)
        XCTAssertEqual(LogsPage.lines(log, show: .requests, filter: "").map(\.kind), [.request])
        XCTAssertEqual(LogsPage.lines(log, show: .problems, filter: "").map(\.kind), [.error, .warning])
        XCTAssertEqual(LogsPage.lines(log, show: .all, filter: "CONTEXT").count, 1, "the filter ignores case")
    }
}
