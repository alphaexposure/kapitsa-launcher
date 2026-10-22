import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaStatusTests: XCTestCase {
    func testHealthOKMeansReady() throws {
        let status = try JSONDecoder().decode(KapitsaStatus.self, from: Data(#"{"status":"ok"}"#.utf8))
        XCTAssertTrue(status.ready)
    }

    func testOtherOrMissingStatusIsNotReady() throws {
        XCTAssertFalse(try JSONDecoder().decode(KapitsaStatus.self, from: Data(#"{"status":"loading"}"#.utf8)).ready)
        XCTAssertFalse(try JSONDecoder().decode(KapitsaStatus.self, from: Data("{}".utf8)).ready)
    }
}
