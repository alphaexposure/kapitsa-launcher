import XCTest
@testable import KapitsaLauncher

final class KapitsaAppConnectionTests: XCTestCase {
    private let installed = ["huihui-qwen3.8-27b-abliterated.q4_k_m", "qwen3.6-35b-a3b:4bit", "qwen3.8-27b:4bit"]

    private func name(engine: String?, configured: String, modelID: String = "") -> String {
        KapitsaAppConnection.apiName(modelID: modelID, engineModel: engine, configured: configured, installed: installed)
    }

    func testACatalogModelIsNamedWithItsPrecision() {
        XCTAssertEqual(name(engine: "qwen3.6-35b-a3b", configured: "qwen3.6-35b-a3b:4bit"), "qwen3.6-35b-a3b:4bit")
        XCTAssertEqual(name(engine: "qwen3.6-35b-a3b", configured: "35b"), "qwen3.6-35b-a3b:4bit")
        XCTAssertEqual(name(engine: nil, configured: "35b"), "qwen3.6-35b-a3b:4bit", "before Kapitsa is ready")
    }

    func testTheLoadedModelWinsAfterAnAppSwitchedModels() {
        XCTAssertEqual(name(engine: "qwen3.8-27b", configured: "35b"), "qwen3.8-27b:4bit")
        XCTAssertEqual(name(engine: "huihui-qwen3.8-27b-abliterated.q4_k_m", configured: "35b"), "huihui-qwen3.8-27b-abliterated.q4_k_m")
    }

    func testAConvertedGGUFAndTheAPIModelNameSetting() {
        XCTAssertEqual(name(engine: nil, configured: "/Users/me/Models/Huihui-Qwen3.8-27B-abliterated.Q4_K_M.gguf"),
                       "huihui-qwen3.8-27b-abliterated.q4_k_m")
        XCTAssertEqual(name(engine: "qwen3.6-35b-a3b", configured: "35b", modelID: "qwen"), "qwen")
        XCTAssertEqual(name(engine: nil, configured: ""), "kapitsa", "Kapitsa picks the model; it then ignores the name")
    }

    func testAddressesAndSettingsNeverHoldTheKey() {
        let connection = KapitsaAppConnection(host: "0.0.0.0", port: 8000, modelID: "", engineModel: "qwen3.6-35b-a3b",
                                              configured: "35b", installed: installed, needsAPIKey: true)
        XCTAssertEqual(connection.baseURL, "http://127.0.0.1:8000")
        XCTAssertEqual(connection.openAIBaseURL, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(connection.shellText(.openAI), """
            export OPENAI_BASE_URL="http://127.0.0.1:8000/v1"
            export OPENAI_API_KEY="PASTE-YOUR-API-KEY"
            export OPENAI_MODEL="qwen3.6-35b-a3b:4bit"
            """)
        let json = try! JSONSerialization.jsonObject(with: Data(connection.jsonText(.anthropic).utf8)) as! [String: String]
        XCTAssertEqual(json["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8000")
        XCTAssertEqual(json["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "qwen3.6-35b-a3b:4bit")
        XCTAssertEqual(json["ANTHROPIC_AUTH_TOKEN"], "PASTE-YOUR-API-KEY")

        let open = KapitsaAppConnection(host: "127.0.0.1", port: 9000, modelID: "", engineModel: nil,
                                        configured: "35b", installed: installed, needsAPIKey: false)
        XCTAssertEqual(open.environment(.openAI)[1].value, "kapitsa")
    }
}
