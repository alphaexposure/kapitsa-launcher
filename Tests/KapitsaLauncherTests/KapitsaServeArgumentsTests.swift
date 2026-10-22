import XCTest
@testable import KapitsaLauncher

final class KapitsaServeArgumentsTests: XCTestCase {
    func testDefaultsLeaveTheModelChoiceToKapitsa() {
        XCTAssertEqual(KapitsaServeArguments.serveArguments(KapitsaConfiguration()),
                       ["serve", "--host", "127.0.0.1", "--port", "8000"])
    }

    func testEverySettingBecomesItsOwnArgument() {
        var configuration = KapitsaConfiguration()
        configuration.model = "27b:8bit"
        configuration.host = "0.0.0.0"
        configuration.port = 9001
        configuration.modelID = "qwen"
        configuration.context = "128k"
        configuration.slots = "2"
        configuration.dflash = "none"
        configuration.memBudget = "24"
        configuration.prefillChunk = "1024"
        configuration.diskCache = "16G"
        configuration.allowSwitch = true
        XCTAssertEqual(KapitsaServeArguments.serveArguments(configuration), [
            "serve", "--model", "27b:8bit", "--host", "0.0.0.0", "--port", "9001",
            "--model-id", "qwen", "--context", "128k", "--slots", "2", "--dflash", "none",
            "--mem-budget", "24", "--prefill-chunk", "1024", "--disk-cache", "16G", "--allow-switch",
        ])
    }

    func testModelPathWithSpacesStaysOneArgument() {
        var configuration = KapitsaConfiguration()
        configuration.model = "/Users/me/My Models/x.gguf"
        let arguments = KapitsaServeArguments.serveArguments(configuration)
        XCTAssertEqual(arguments[1...2], ["--model", "/Users/me/My Models/x.gguf"])
    }

    func testAPIKeyIsNeverAnArgument() {
        XCTAssertFalse(KapitsaServeArguments.serveArguments(KapitsaConfiguration()).contains("--api-key"))
    }
}
