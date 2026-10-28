import XCTest
@testable import KapitsaLauncher

final class KapitsaModelFinderTests: XCTestCase {
    private func folder(config: [String: Any]?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let config { try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json")) }
        return url
    }

    func testAcceptsWhatKapitsaRunsAndExplainsWhatItDoesnt() throws {
        XCTAssertEqual(KapitsaModelFinder.check(try folder(config: ["model_type": "qwen3_5"])), .ok, "the 2B and 27B")
        XCTAssertEqual(KapitsaModelFinder.check(try folder(config: ["model_type": "qwen3_5_moe"])), .ok, "the 35B")
        XCTAssertEqual(KapitsaModelFinder.check(try folder(config: ["model_type": "x", "text_config": ["model_type": "qwen3_5_text"]])), .ok)

        guard case .problem(let gemma) = KapitsaModelFinder.check(try folder(config: ["model_type": "gemma4_unified"])) else {
            return XCTFail("Gemma is refused")
        }
        XCTAssertTrue(gemma.contains("gemma4_unified"))
        guard case .problem = KapitsaModelFinder.check(try folder(config: nil)) else { return XCTFail("no config.json") }
        guard case .note = KapitsaModelFinder.check(try folder(config: ["hidden_size": 1])) else { return XCTFail("unnamed") }
        guard case .note = KapitsaModelFinder.check(URL(fileURLWithPath: "/x/model-Q4_K_M.gguf")) else { return XCTFail("a GGUF") }
    }
}
