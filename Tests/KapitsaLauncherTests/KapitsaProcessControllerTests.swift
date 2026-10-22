import Foundation
import XCTest
@testable import KapitsaLauncher

final class KapitsaProcessControllerTests: XCTestCase {

    private func makeController(
        runProcess: @escaping KapitsaProcessController.ProcessRunner,
        stopProcess: @escaping KapitsaProcessController.ProcessStopper,
        statusClient: KapitsaStatusFetching = FakeStatusClient(),
        portChecker: KapitsaPortChecking = FakePortChecker(),
        keyStore: KapitsaAPIKeyStoring = FakeKeyStore()
    ) -> KapitsaProcessController {
        KapitsaProcessController(
            configuration: KapitsaConfiguration(),
            executable: KapitsaExecutable(path: "/opt/homebrew/bin/kapitsa"),
            runProcess: runProcess,
            stopProcess: stopProcess,
            statusClient: statusClient,
            portChecker: portChecker,
            keyStore: keyStore
        )
    }

    private static func requestLine(prompt: Int, cached: Int, output: Int, rate: Double) -> String {
        "[kapitsa] chat: prompt \(prompt) (cached \(cached)) in 400 ms (+1.2 ms template/tokenize; last chunk: "
            + "encoded by 1.6 ms, GPU start +57.4 ms, GPU 340.5 ms, wake +0.2 ms), \(output) tokens in 1000 ms "
            + "(\(rate) tok/s), stop, 6.12 tok/cycle\n"
    }

    func testAllowSwitchOnNetworkAddressNeedsAnAPIKey() {
        var configuration = KapitsaConfiguration()
        configuration.host = "0.0.0.0"
        configuration.allowSwitch = true
        var launched = false
        let controller = KapitsaProcessController(
            configuration: configuration, executable: KapitsaExecutable(path: "/opt/homebrew/bin/kapitsa"),
            runProcess: { _ in launched = true; return 1 }, portChecker: FakePortChecker(), keyStore: FakeKeyStore())
        controller.start()
        XCTAssertFalse(launched)
        XCTAssertNotNil(controller.launchErrorMessage)
    }

    // MARK: - start()

    func testStartTransitionsToRunningWithReturnedPID() {
        let controller = makeController(
            runProcess: { _ in 12345 },
            stopProcess: { _ in }
        )
        controller.start()
        XCTAssertEqual(controller.state, .running(processID: 12345))
        XCTAssertNil(controller.launchErrorMessage)
    }

    func testStartIsIgnoredWhileAlreadyRunning() {
        var runCallCount = 0
        let controller = makeController(
            runProcess: { _ in
                runCallCount += 1
                return 42
            },
            stopProcess: { _ in }
        )
        controller.start()
        controller.start()
        XCTAssertEqual(runCallCount, 1)
        XCTAssertEqual(controller.state, .running(processID: 42))
    }

    func testLaunchFailureStaysStoppedAndReportsError() {
        struct LaunchFailure: Error {}
        let controller = makeController(
            runProcess: { _ in throw LaunchFailure() },
            stopProcess: { _ in }
        )
        controller.start()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNotNil(controller.launchErrorMessage)
    }

    func testLaunchFailureAllowsRetryAfterStoppingState() {
        var attempt = 0
        let controller = makeController(
            runProcess: { _ in
                attempt += 1
                if attempt == 1 {
                    struct LaunchFailure: Error {}
                    throw LaunchFailure()
                }
                return 777
            },
            stopProcess: { _ in }
        )
        controller.start()
        XCTAssertEqual(controller.state, .stopped)
        controller.start()
        XCTAssertEqual(controller.state, .running(processID: 777))
        XCTAssertNil(controller.launchErrorMessage)
    }

    func testStartWithoutExecutableReportsErrorAndStaysStopped() {
        let controller = KapitsaProcessController(
            configuration: KapitsaConfiguration(),
            executable: nil,
            runProcess: { _ in 1 },
            stopProcess: { _ in },
            portChecker: FakePortChecker(),
            keyStore: FakeKeyStore()
        )
        XCTAssertFalse(controller.hasExecutable)
        controller.start()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(controller.launchErrorMessage, "No Kapitsa executable found.")
    }

    // MARK: - stop()

    func testStopStopsOwnedProcessAndExitTransitionsToStopped() {
        var stopCallCount = 0
        let controller = makeController(
            runProcess: { _ in 12345 },
            stopProcess: { _ in stopCallCount += 1 }
        )
        controller.start()
        controller.stop()
        XCTAssertEqual(stopCallCount, 1)
        controller.handleProcessExit()
        XCTAssertEqual(controller.state, .stopped)
    }

    func testStopIsNoopWhenNotRunning() {
        var stopCallCount = 0
        let controller = makeController(
            runProcess: { _ in 1 },
            stopProcess: { _ in stopCallCount += 1 }
        )
        controller.stop()
        XCTAssertEqual(stopCallCount, 0)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testStopAfterProcessExitedIsNoop() {
        var stopCallCount = 0
        let controller = makeController(
            runProcess: { _ in 5 },
            stopProcess: { _ in stopCallCount += 1 }
        )
        controller.start()
        controller.handleProcessExit()
        controller.stop()
        XCTAssertEqual(stopCallCount, 0)
        XCTAssertEqual(controller.state, .stopped)
    }

    // MARK: - process exit

    func testProcessExitTransitionsToStopped() {
        let controller = makeController(
            runProcess: { _ in 77 },
            stopProcess: { _ in }
        )
        controller.start()
        XCTAssertEqual(controller.state, .running(processID: 77))
        controller.handleProcessExit()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.state.processID)
    }

    // MARK: - status polling

    func testReadyFalseThenTrueTransitionsWithoutChangingProcessOwnership() {
        let client = FakeStatusClient()
        let controller = makeController(runProcess: { _ in 100 }, stopProcess: { _ in }, statusClient: client)
        controller.start()
        XCTAssertEqual(controller.readiness, .loading)
        XCTAssertEqual(client.requests.count, 1)

        client.complete(.success(KapitsaStatus(status: "loading")))
        XCTAssertEqual(controller.readiness, .loading)
        XCTAssertEqual(controller.state, .running(processID: 100))

        controller.pollStatus()
        client.complete(.success(KapitsaStatus(status: "ok")))
        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertEqual(controller.status?.ready, true)
        XCTAssertEqual(controller.state, .running(processID: 100))
    }

    func testStartupStatusTimeoutIsHiddenUntilReady() {
        let client = FakeStatusClient()
        let controller = makeController(runProcess: { _ in 201 }, stopProcess: { _ in }, statusClient: client)
        controller.start()
        client.complete(.failure(URLError(.timedOut)))
        XCTAssertEqual(controller.readiness, .loading)
        XCTAssertNil(controller.statusErrorMessage)
        XCTAssertEqual(controller.state, .running(processID: 201))

        controller.pollStatus()
        client.complete(.success(KapitsaStatus(status: "ok")))
        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertNil(controller.statusErrorMessage)
    }

    func testUnexpectedExitDuringStartupShowsFailure() {
        let controller = makeController(runProcess: { _ in 202 }, stopProcess: { _ in })
        controller.start()
        controller.handleProcessExit()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(controller.launchErrorMessage, "Kapitsa stopped before it was ready. Check the logs for details.")
    }

    func testFailureKeepsOwnedProcessRunningAndAllowsNextPoll() {
        struct NetworkFailure: LocalizedError {
            var errorDescription: String? { "Unavailable" }
        }
        let client = FakeStatusClient()
        let controller = makeController(runProcess: { _ in 200 }, stopProcess: { _ in }, statusClient: client)
        controller.start()
        client.complete(.success(KapitsaStatus(status: "ok")))
        XCTAssertEqual(controller.readiness, .ready)

        controller.pollStatus()
        client.complete(.failure(NetworkFailure()))
        XCTAssertEqual(controller.readiness, .loading)
        XCTAssertEqual(controller.state, .running(processID: 200))
        XCTAssertEqual(controller.statusErrorMessage, "Unavailable")

        controller.pollStatus()
        client.complete(.success(KapitsaStatus(status: "ok")))
        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertNil(controller.statusErrorMessage)
    }

    func testPollsDoNotOverlapAndExitCancelsRequestAndIgnoresLateResponse() {
        let client = FakeStatusClient()
        let controller = makeController(runProcess: { _ in 300 }, stopProcess: { _ in }, statusClient: client)
        controller.start()
        controller.pollStatus()
        XCTAssertEqual(client.requests.count, 1)

        controller.handleProcessExit()
        XCTAssertTrue(client.requests[0].cancelled)
        XCTAssertEqual(controller.readiness, .stopped)
        client.complete(.success(KapitsaStatus(status: "ok")))
        XCTAssertEqual(controller.readiness, .stopped)
        XCTAssertNil(controller.status)
        controller.pollStatus()
        XCTAssertEqual(client.requests.count, 1)
    }


    // MARK: - later milestones

    func testPortConflictPreventsLaunchWithoutTouchingAnotherProcess() {
        var runs = 0
        let controller = makeController(
            runProcess: { _ in runs += 1; return 1 },
            stopProcess: { _ in },
            portChecker: FakePortChecker(error: "Port 8000 is already in use.")
        )
        controller.start()
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(controller.launchErrorMessage, "Port 8000 is already in use.")
    }

    func testStopWaitsForOwnedProcessExit() {
        var stops = 0
        let controller = makeController(runProcess: { _ in 42 }, stopProcess: { _ in stops += 1 })
        controller.start()
        controller.stop()
        controller.stop()
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(controller.isStopping)
        XCTAssertEqual(controller.state, .running(processID: 42))
        XCTAssertNotNil(controller.shutdownMessage)
        controller.handleProcessExit()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(controller.isStopping)
    }

    func testRestartStartsOnlyAfterOwnedProcessExits() {
        var runs = 0
        var stops = 0
        let controller = makeController(
            runProcess: { _ in runs += 1; return pid_t(runs) },
            stopProcess: { _ in stops += 1 }
        )
        controller.start()
        controller.restart()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(controller.isStopping)
        controller.handleProcessExit()
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(controller.state, .running(processID: 2))
    }

    func testQuitWaitsForExitAndCancelsPendingRestart() {
        var runs = 0
        var completionCount = 0
        let controller = makeController(runProcess: { _ in runs += 1; return 1 }, stopProcess: { _ in })
        controller.start()
        controller.restart()
        XCTAssertTrue(controller.stopBeforeQuit { completionCount += 1 })
        XCTAssertEqual(completionCount, 0)
        controller.handleProcessExit()
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testKeyUsesEnvironmentAndStatusAuthorizationWithoutAppearingInArgumentsOrLogs() {
        let statusClient = FakeStatusClient()
        var launchedProcess: Process?
        let controller = makeController(
            runProcess: { process in launchedProcess = process; return 1 },
            stopProcess: { _ in },
            statusClient: statusClient,
            keyStore: FakeKeyStore(key: "secret")
        )
        controller.start()
        XCTAssertEqual(launchedProcess?.environment?["KAPITSA_API_KEY"], "secret")
        XCTAssertFalse(launchedProcess?.arguments?.joined().contains("secret") ?? true)
        XCTAssertEqual(statusClient.apiKeys, ["secret"])
        controller.appendLog(Data("before sec".utf8))
        XCTAssertFalse(controller.logs.contains("secret"))
        controller.appendLog(Data("ret after extra text".utf8))
        XCTAssertTrue(controller.logs.contains("[REDACTED]"))
        XCTAssertFalse(controller.logs.contains("secret"))
    }

    func testMissingKapitsaNoticeShowsUntilAValidExecutableIsChosen() throws {
        let controller = KapitsaProcessController(configuration: KapitsaConfiguration(), executable: nil,
                                                 runProcess: { _ in 1 }, keyStore: FakeKeyStore())
        XCTAssertFalse(controller.hasExecutable, "notice shows: nothing found")
        controller.start()
        XCTAssertEqual(controller.launchErrorMessage, "No Kapitsa executable found.")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notExecutable = folder.appendingPathComponent("readme.txt")
        try Data("not a program".utf8).write(to: notExecutable)
        controller.selectExecutable(path: notExecutable.path)
        XCTAssertFalse(controller.hasExecutable, "notice still shows after an invalid choice")
        XCTAssertEqual(controller.launchErrorMessage, "Selected file is not executable.")

        let executable = folder.appendingPathComponent("kapitsa")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        controller.selectExecutable(path: executable.path)
        XCTAssertTrue(controller.hasExecutable, "notice hides once a valid executable is chosen")
        XCTAssertNil(controller.launchErrorMessage)
        XCTAssertEqual(KapitsaLinks.home.absoluteString, "https://github.com/nace-ai/kapitsa")
    }

    func testLatestRequestIsReadFromLogLinesSplitAcrossReads() {
        let controller = makeController(runProcess: { _ in 1 }, stopProcess: { _ in },
                                        keyStore: FakeKeyStore(key: "secret"))
        controller.start()
        let line = Data(Self.requestLine(prompt: 813, cached: 0, output: 9, rate: 3.1).utf8)
        controller.appendLog(Data("[kapitsa] listening on http://127.0.0.1:8000\n".utf8) + line[..<40])
        XCTAssertNil(controller.lastRequest)
        controller.appendLog(line[40...])
        XCTAssertEqual(controller.lastRequest?.promptTokens, 813)
        controller.appendLog(Data(Self.requestLine(prompt: 900, cached: 800, output: 20, rate: 4.0).utf8))
        XCTAssertEqual(controller.lastRequest?.cachedTokens, 800)
        controller.clearLogs()
        XCTAssertEqual(controller.lastRequest?.decodeTokensPerSecond, 4.0)
        XCTAssertEqual(controller.totals.requests, 2)
        XCTAssertEqual(controller.totals.prefilledTokens, 913)
        XCTAssertEqual(controller.totals.outputTokens, 29)
        XCTAssertEqual(controller.engine.address, "http://127.0.0.1:8000")
    }

    func testRestartClearsEngineInfoAndTotals() {
        let controller = makeController(runProcess: { _ in 1 }, stopProcess: { _ in })
        controller.start()
        controller.appendLog(Data(("[kapitsa] engine ready: qwen3.8-27b, context 32768, 4 slots, images on\n"
                                   + Self.requestLine(prompt: 10, cached: 0, output: 2, rate: 2.0)).utf8))
        XCTAssertEqual(controller.engine.model, "qwen3.8-27b")
        controller.handleProcessExit()
        controller.start()
        XCTAssertNil(controller.engine.model)
        XCTAssertEqual(controller.totals, KapitsaSessionTotals())
        XCTAssertNil(controller.lastRequest)
    }

    func testProgressBarRedrawsReplaceTheCurrentLine() {
        var log = "Selected model.gguf\n"
        for update in ["\rFetching 2 files:   0%|          | 0/2", "\rFetching 2 files:  50%|█████     | 1/2",
                       "\rFetching 2 files: 100%|██████████| 2/2\n", "14:52:22 Ready\n"] {
            log = KapitsaProcessController.appendingTerminalOutput(update, to: log)
        }
        XCTAssertEqual(log, "Selected model.gguf\nFetching 2 files: 100%|██████████| 2/2\n14:52:22 Ready\n")
    }

    func testCarriageReturnSplitAcrossReadsStillEndsTheLine() {
        var log = KapitsaProcessController.appendingTerminalOutput("Loading\r", to: "")
        log = KapitsaProcessController.appendingTerminalOutput("\nReady\n", to: log)
        XCTAssertEqual(log, "Loading\nReady\n")
        log = KapitsaProcessController.appendingTerminalOutput("A\r\nB\r\n", to: log)
        XCTAssertEqual(log, "Loading\nReady\nA\nB\n")
    }

    func testPlainOutputIsAppendedUnchangedAndTrimmed() {
        XCTAssertEqual(KapitsaProcessController.appendingTerminalOutput("two\n", to: "one\n"), "one\ntwo\n")
        XCTAssertEqual(KapitsaProcessController.appendingTerminalOutput("abcdef", to: "", limit: 3), "def")
    }

    func testDownloadProgressUpdatesInPlaceInDisplayedLogsWithAPIKey() {
        let controller = makeController(runProcess: { _ in 1 }, stopProcess: { _ in },
                                        keyStore: FakeKeyStore(key: "secret"))
        controller.start()
        controller.appendLog(Data("Fetching:  10%\r".utf8))
        controller.appendLog(Data("Fetching:  90%\rFetching: 100%\n15:00:00 Ready\n".utf8))
        controller.appendLog(Data("more output\n".utf8))
        // The last key.count - 1 characters stay held back until more output arrives (key redaction).
        XCTAssertEqual(controller.logs, "Fetching: 100%\n15:00:00 Ready\nmore ou")
    }

    func testFinalRequestLineWithoutNewlineIsReadWhenProcessExits() {
        let controller = makeController(runProcess: { _ in 1 }, stopProcess: { _ in })
        controller.start()
        controller.appendLog(Data(Self.requestLine(prompt: 10, cached: 0, output: 2, rate: 2.0).dropLast().utf8))
        XCTAssertNil(controller.lastRequest)
        controller.handleProcessExit()
        XCTAssertEqual(controller.lastRequest?.outputTokens, 2)
    }

    // MARK: - state model

    func testStateLabels() {
        XCTAssertEqual(KapitsaProcessState.stopped.label, "Stopped")
        XCTAssertEqual(KapitsaProcessState.running(processID: 1).label, "Running")
    }

    func testStateProcessID() {
        XCTAssertNil(KapitsaProcessState.stopped.processID)
        XCTAssertEqual(KapitsaProcessState.running(processID: 9).processID, 9)
        XCTAssertFalse(KapitsaProcessState.stopped.isRunning)
        XCTAssertTrue(KapitsaProcessState.running(processID: 9).isRunning)
    }
}

private final class FakeStatusClient: KapitsaStatusFetching {
    private(set) var completions: [(Result<KapitsaStatus, Error>) -> Void] = []
    private(set) var requests: [FakeStatusRequest] = []
    private(set) var apiKeys: [String?] = []

    func fetchStatus(
        configuration: KapitsaConfiguration,
        apiKey: String?,
        completion: @escaping (Result<KapitsaStatus, Error>) -> Void
    ) -> KapitsaStatusRequest {
        let request = FakeStatusRequest()
        apiKeys.append(apiKey)
        requests.append(request)
        completions.append(completion)
        return request
    }

    func complete(_ result: Result<KapitsaStatus, Error>, at index: Int? = nil) {
        completions[index ?? completions.count - 1](result)
    }
}

private final class FakeStatusRequest: KapitsaStatusRequest {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

private struct FakePortChecker: KapitsaPortChecking {
    var error: String? = nil
    func check(_ configuration: KapitsaConfiguration) -> String? { error }
}

private final class FakeKeyStore: KapitsaAPIKeyStoring {
    var key: String?
    init(key: String? = nil) { self.key = key }
    func read() throws -> String? { key }
    func save(_ key: String) throws { self.key = key }
    func remove() throws { key = nil }
}
