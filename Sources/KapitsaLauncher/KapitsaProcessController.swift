import Foundation
import Combine

/// Whether this app still owns a Kapitsa child. Status responses do not change this state.
enum KapitsaProcessState: Equatable {
    case stopped
    case running(processID: pid_t)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
    var processID: pid_t? {
        if case .running(let processID) = self { return processID }
        return nil
    }
    var label: String { isRunning ? "Running" : "Stopped" }
}

enum KapitsaReadinessState: Equatable {
    case stopped
    case loading
    case ready

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .loading: return "Starting / Loading"
        case .ready: return "Ready"
        }
    }
}

/// Retains and controls only the exact Process launched by this app.
final class KapitsaProcessController: ObservableObject {
    typealias ProcessRunner = (Process) throws -> pid_t
    typealias ProcessStopper = (Process) -> Void

    @Published private(set) var state: KapitsaProcessState = .stopped
    @Published private(set) var launchErrorMessage: String?
    @Published private(set) var readiness: KapitsaReadinessState = .stopped
    @Published private(set) var status: KapitsaStatus?
    @Published private(set) var statusErrorMessage: String?
    @Published private(set) var isStopping = false
    @Published private(set) var shutdownMessage: String?
    @Published private(set) var logs = ""
    /// The most recent finished request reported in this server session's output.
    @Published private(set) var lastRequest: KapitsaRequestMetrics?
    /// Every request finished in this server session, added up from the request lines.
    @Published private(set) var totals = KapitsaSessionTotals()
    /// What Kapitsa reported about the loaded engine while it started.
    @Published private(set) var engine = KapitsaEngineInfo()
    @Published private(set) var hasAPIKey = false
    @Published private(set) var keyErrorMessage: String?
    @Published private(set) var executable: KapitsaExecutable?
    @Published var configuration: KapitsaConfiguration {
        didSet { settingsStore?.saveConfiguration(configuration) }
    }

    private var ownedProcess: Process?
    private var outputPipe: Pipe?
    private var activeConfiguration: KapitsaConfiguration?
    private var activeAPIKey: String?
    private var pendingLogText = ""
    private var partialLogLine = Data()
    private var restartPending = false
    private var hasReachedReady = false
    private var quitCompletion: (() -> Void)?
    private var shutdownTimer: Timer?
    private let now: () -> Date
    private let runProcess: ProcessRunner
    private let stopProcess: ProcessStopper
    private let statusClient: KapitsaStatusFetching
    private let portChecker: KapitsaPortChecking
    private let keyStore: KapitsaAPIKeyStoring
    private let settingsStore: KapitsaSettingsStore?
    private var statusTimer: Timer?
    private var statusRequest: KapitsaStatusRequest?
    private var statusRequestInFlight = false
    private var pollingGeneration = 0

    convenience init(configuration: KapitsaConfiguration, executable: KapitsaExecutable?, settingsStore: KapitsaSettingsStore? = nil) {
        self.init(configuration: configuration, executable: executable,
                  runProcess: { process in try process.run(); return process.processIdentifier },
                  settingsStore: settingsStore)
    }

    init(
        configuration: KapitsaConfiguration,
        executable: KapitsaExecutable?,
        runProcess: @escaping ProcessRunner,
        stopProcess: @escaping ProcessStopper = { if $0.isRunning { $0.terminate() } },
        statusClient: KapitsaStatusFetching = KapitsaStatusClient(),
        portChecker: KapitsaPortChecking = KapitsaPortChecker(),
        keyStore: KapitsaAPIKeyStoring = KapitsaAPIKeyStore(),
        settingsStore: KapitsaSettingsStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        self.configuration = configuration
        self.executable = executable
        self.runProcess = runProcess
        self.stopProcess = stopProcess
        self.statusClient = statusClient
        self.portChecker = portChecker
        self.keyStore = keyStore
        self.settingsStore = settingsStore
        self.hasAPIKey = (try? keyStore.read()) != nil
    }

    var hasExecutable: Bool { executable != nil }

    var webUIURL: URL? {
        guard state.isRunning, readiness == .ready, !isStopping,
              let activeConfiguration else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        switch activeConfiguration.host {
        case "0.0.0.0": components.host = "127.0.0.1"
        case "::": components.host = "::1"
        default: components.host = activeConfiguration.host
        }
        components.port = activeConfiguration.port
        components.path = "/"
        return components.url
    }

    /// Where the Chat page sends requests, while the server this app started is ready.
    var chatConnection: KapitsaChatConnection? {
        guard let webUIURL else { return nil }
        return KapitsaChatConnection(baseURL: webUIURL, apiKey: activeAPIKey,
                                     model: engine.model ?? (activeConfiguration?.model.isEmpty == false ? activeConfiguration!.model : "kapitsa"))
    }

    func selectExecutable(path: String) {
        guard !state.isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            launchErrorMessage = "Selected file is not executable."
            return
        }
        executable = KapitsaExecutable(path: path)
        settingsStore?.saveExecutablePath(path)
        launchErrorMessage = nil
    }

    func saveAPIKey(_ key: String) {
        do {
            try keyStore.save(key)
            hasAPIKey = true
            keyErrorMessage = nil
        } catch {
            keyErrorMessage = error.localizedDescription
        }
    }

    func removeAPIKey() {
        do {
            try keyStore.remove()
            hasAPIKey = false
            keyErrorMessage = nil
        } catch {
            keyErrorMessage = error.localizedDescription
        }
    }

    func start() {
        guard !state.isRunning else { return }
        guard let executable else { launchErrorMessage = "No Kapitsa executable found."; return }
        if let error = configuration.validationError { launchErrorMessage = error; return }
        if let error = portChecker.check(configuration) { launchErrorMessage = error; return }

        let key: String?
        do { key = try keyStore.read() }
        catch { launchErrorMessage = "Could not read API key: \(error.localizedDescription)"; return }
        if configuration.allowSwitch && !configuration.isLocalHost && key == nil {
            launchErrorMessage = "Model switching on a network address needs an API key. Save one in Settings."
            return
        }

        let process = Process()
        process.executableURL = executable.url
        process.arguments = KapitsaServeArguments.serveArguments(configuration)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KAPITSA_API_KEY")
        if let key { environment["KAPITSA_API_KEY"] = key }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let identity = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.ownedProcess.map(ObjectIdentifier.init) == identity else { return }
                self.handleProcessExit()
            }
        }

        do {
            let processID = try runProcess(process)
            ownedProcess = process
            outputPipe = pipe
            activeConfiguration = configuration
            activeAPIKey = key
            logs = ""
            pendingLogText = ""
            partialLogLine = Data()
            lastRequest = nil
            totals = KapitsaSessionTotals()
            engine = KapitsaEngineInfo()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, self.ownedProcess.map(ObjectIdentifier.init) == identity else { return }
                    self.appendLog(data)
                }
            }
            pipe.fileHandleForWriting.closeFile()
            launchErrorMessage = nil
            shutdownMessage = nil
            isStopping = false
            state = .running(processID: processID)
            startPolling()
        } catch {
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
            launchErrorMessage = "Could not launch Kapitsa: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let process = ownedProcess, state.isRunning, !isStopping else { return }
        restartPending = false
        isStopping = true
        shutdownMessage = "Stopping Kapitsa and releasing engine resources…"
        stopProcess(process)
        shutdownTimer?.invalidate()
        shutdownTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.isStopping else { return }
            self.shutdownMessage = "Kapitsa is still shutting down. Waiting for the owned process to exit."
        }
    }

    func restart() {
        if state.isRunning {
            if !isStopping { stop() }     // stop() clears restartPending, so set it afterwards
            restartPending = true
        } else {
            start()
        }
    }

    /// Called by the app delegate. Returns true when quitting must wait for the child.
    func stopBeforeQuit(_ completion: @escaping () -> Void) -> Bool {
        guard state.isRunning else { return false }
        restartPending = false
        quitCompletion = completion
        stop()
        return true
    }

    /// Applies the transition after the owned child exits. Exposed for process-free tests.
    func handleProcessExit() {
        guard ownedProcess != nil else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe?.fileHandleForReading.closeFile()
        outputPipe = nil
        if !pendingLogText.isEmpty {
            logs = Self.appendingTerminalOutput(pendingLogText, to: logs)
        }
        scanRequestLines(Data("\n".utf8))
        pendingLogText = ""
        if !hasReachedReady && !isStopping && quitCompletion == nil && !restartPending {
            launchErrorMessage = "Kapitsa stopped before it was ready. Check the logs for details."
        }
        ownedProcess = nil
        activeConfiguration = nil
        activeAPIKey = nil
        state = .stopped
        isStopping = false
        shutdownMessage = nil
        shutdownTimer?.invalidate()
        shutdownTimer = nil
        stopPolling()
        if let completion = quitCompletion {
            quitCompletion = nil
            restartPending = false
            completion()
        } else if restartPending {
            restartPending = false
            start()
        }
    }

    func clearLogs() { logs = "" }

    /// Holds a short suffix so a key split across pipe reads is never displayed.
    func appendLog(_ data: Data) {
        scanRequestLines(data)
        let chunk = String(decoding: data, as: UTF8.self)
        guard let key = activeAPIKey, !key.isEmpty else {
            logs = Self.appendingTerminalOutput(chunk, to: logs)
            return
        }
        let redacted = (pendingLogText + chunk).replacingOccurrences(of: key, with: "[REDACTED]")
        let heldCount = min(key.count - 1, redacted.count)
        let boundary = redacted.index(redacted.endIndex, offsetBy: -heldCount)
        logs = Self.appendingTerminalOutput(String(redacted[..<boundary]), to: logs)
        pendingLogText = String(redacted[boundary...])
    }

    /// Appends output the way a terminal shows it: a carriage return rewrites the current line,
    /// so progress bars (such as model downloads) update in place instead of piling up.
    /// A trailing carriage return is kept until the next output shows whether a newline follows.
    static func appendingTerminalOutput(_ text: String, to log: String, limit: Int = 50_000) -> String {
        guard text.unicodeScalars.contains("\r") || log.hasSuffix("\r") else {
            return String((log + text).suffix(limit))
        }
        let lineStart = log.lastIndex(of: "\n").map { log.index(after: $0) } ?? log.startIndex
        // Swift treats "\r\n" as one Character, so normalise it before splitting on "\n".
        let combined = String(log[lineStart...] + text).replacingOccurrences(of: "\r\n", with: "\n")
        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        let unfinished = lines.removeLast()

        func visible(_ line: Substring) -> Substring {
            let body = line.hasSuffix("\r") ? line.dropLast() : line
            return body.lastIndex(of: "\r").map { body[body.index(after: $0)...] } ?? body
        }
        var rendered = String(log[..<lineStart])
        for line in lines { rendered += visible(line) + "\n" }
        rendered += visible(unfinished) + (unfinished.hasSuffix("\r") ? "\r" : "")
        return String(rendered.suffix(limit))
    }

    /// Reads complete lines only, so a request line split across pipe reads is still recognised.
    /// It scans unredacted output without holding text back, so a finished request shows at once;
    /// only numbers and the timestamp are kept, and nothing scanned here is displayed.
    private func scanRequestLines(_ data: Data) {
        // Split on newline bytes before decoding, so a multi-byte character split across reads stays intact.
        var buffer = partialLogLine + data
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            if let request = KapitsaRequestMetrics(logLine: line, finishedAt: Self.clockTime(now())) {
                lastRequest = request
                totals.add(request)
            } else {
                engine.apply(logLine: line)
            }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        // Request lines are short; a long unterminated line (e.g. a progress bar) is not one.
        partialLogLine = Data(buffer.suffix(4_096))
    }

    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    func pollStatus() {
        guard state.isRunning, !statusRequestInFlight, let activeConfiguration else { return }
        statusRequestInFlight = true
        let generation = pollingGeneration
        let request = statusClient.fetchStatus(configuration: activeConfiguration, apiKey: activeAPIKey) { [weak self] result in
            guard let self, generation == self.pollingGeneration, self.state.isRunning else { return }
            self.statusRequest = nil
            self.statusRequestInFlight = false
            switch result {
            case .success(let status):
                self.status = status
                self.readiness = status.ready ? .ready : .loading
                if status.ready { self.hasReachedReady = true }
                self.statusErrorMessage = nil
            case .failure(let error):
                self.readiness = .loading
                self.statusErrorMessage = self.hasReachedReady ? error.localizedDescription : nil
            }
        }
        if statusRequestInFlight && generation == pollingGeneration { statusRequest = request }
        else { request.cancel() }
    }

    private func startPolling() {
        stopPolling()
        hasReachedReady = false
        readiness = .loading
        pollStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollStatus() }
    }

    private func stopPolling() {
        pollingGeneration += 1
        statusTimer?.invalidate()
        statusTimer = nil
        statusRequest?.cancel()
        statusRequest = nil
        statusRequestInFlight = false
        status = nil
        statusErrorMessage = nil
        readiness = .stopped
    }

    deinit {
        statusTimer?.invalidate()
        shutdownTimer?.invalidate()
        statusRequest?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
    }
}
