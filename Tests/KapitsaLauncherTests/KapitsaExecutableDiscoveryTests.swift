import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaExecutableDiscoveryTests: XCTestCase {

    // MARK: - discover(candidatePaths:)

    func testSelectsFirstValidExecutable() {
        let discovery = discovery(validPaths: ["/second/kapitsa"])
        let result = discovery.discover(candidatePaths: [
            "/first/kapitsa",
            "/second/kapitsa",
            "/third/kapitsa",
        ])
        XCTAssertEqual(result?.path, "/second/kapitsa")
    }

    func testSelectsFirstCandidateWhenSeveralAreValid() {
        let discovery = discovery(validPaths: ["/first/kapitsa", "/third/kapitsa"])
        let result = discovery.discover(candidatePaths: [
            "/first/kapitsa",
            "/second/kapitsa",
            "/third/kapitsa",
        ])
        XCTAssertEqual(result?.path, "/first/kapitsa")
    }

    func testReturnsNilWhenNoCandidateIsValid() {
        let discovery = discovery(validPaths: [])
        let result = discovery.discover(candidatePaths: [
            "/first/kapitsa",
            "/second/kapitsa",
        ])
        XCTAssertNil(result)
    }

    func testEmptyCandidateListReturnsNil() {
        let discovery = discovery(validPaths: ["/anything"])
        XCTAssertNil(discovery.discover(candidatePaths: []))
    }

    // MARK: - discover() using the standard candidate locations

    func testDiscoverUsesFirstDefaultPathWhenValid() {
        let discovery = KapitsaExecutableDiscovery(
            isExecutable: { $0 == "/opt/homebrew/bin/kapitsa" },
            expandHome: { $0 }
        )
        XCTAssertEqual(discovery.discover()?.path, "/opt/homebrew/bin/kapitsa")
    }

    func testDiscoverExpandsTildeInDefaultPaths() {
        let discovery = KapitsaExecutableDiscovery(
            isExecutable: { $0 == "/fake/home/.local/bin/kapitsa" },
            expandHome: { path in
                path.hasPrefix("~/") ? "/fake/home" + String(path.dropFirst(1)) : path
            }
        )
        XCTAssertEqual(discovery.discover()?.path, "/fake/home/.local/bin/kapitsa")
    }

    // MARK: - defaultCandidatePaths

    func testDefaultCandidatePathsAreInPriorityOrder() {
        XCTAssertEqual(
            KapitsaExecutableDiscovery.defaultCandidatePaths,
            ["/opt/homebrew/bin/kapitsa", "~/.local/bin/kapitsa"]
        )
    }

    // MARK: - expandHomePath

    func testExpandHomePathReplacesTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(
            KapitsaExecutableDiscovery.expandHomePath("~/foo/bar"),
            home.appendingPathComponent("foo/bar").path
        )
    }

    func testExpandHomePathLeavesAbsolutePathUnchanged() {
        XCTAssertEqual(
            KapitsaExecutableDiscovery.expandHomePath("/opt/homebrew/bin/kapitsa"),
            "/opt/homebrew/bin/kapitsa"
        )
    }

    // MARK: - KapitsaExecutable

    func testExecutableURL() {
        let executable = KapitsaExecutable(path: "/opt/homebrew/bin/kapitsa")
        XCTAssertEqual(executable.url.path, "/opt/homebrew/bin/kapitsa")
    }

    // MARK: - Helpers

    private func discovery(validPaths: Set<String>) -> KapitsaExecutableDiscovery {
        KapitsaExecutableDiscovery(
            isExecutable: { validPaths.contains($0) },
            expandHome: { $0 }
        )
    }
}
