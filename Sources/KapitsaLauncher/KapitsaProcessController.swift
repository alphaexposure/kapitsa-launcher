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
    /// The requests finished in this server session, the most recent first, up to `recentLimit`.
    @Published private(set) var recentRequests: [KapitsaRequestMetrics] = []
    static let recentLimit = 100
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
    /// The owned process has exited, and its output has ended (both are waited for, so the last
    /// lines it printed, often why it failed, reach the log).
    private var processExited = false
    private var outputEnded = false
    private let now: () -> Date
    private let runProcess: ProcessRunner
    private let stopProcess: ProcessStopper
    private let forceStopProcess: ProcessStopper
    /// How long a stop waits before saying it's slow or, while quitting, forcing the process to quit.
    private let stopGracePeriod: TimeInterval
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
        forceStopProcess: @escaping ProcessStopper = { if $0.isRunning { kill($0.processIdentifier, SIGKILL) } },
        stopGracePeriod: TimeInterval = 10,
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
        self.forceStopProcess = forceStopProcess
        self.stopGracePeriod = stopGracePeriod
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
        components.host = activeConfiguration.host == "0.0.0.0" ? "127.0.0.1" : activeConfiguration.host
        components.port = activeConfiguration.port
        components.path = "/"
        return components.url
    }

    /// How another app reaches the server: the running one's settings, else the ones Start uses.
    func appConnection(installed: [String]) -> KapitsaAppConnection {
        let running = state.isRunning ? activeConfiguration : nil
        let settings = running ?? configuration
        let live = readiness == .ready && !isStopping && running != nil
        return KapitsaAppConnection(host: settings.host, port: settings.port, modelID: settings.modelID,
                                    engineModel: live ? engine.model : nil, configured: settings.model,
                                    installed: installed, needsAPIKey: running != nil ? activeAPIKey != nil : hasAPIKey)
    }

    /// The API key apps need, read only when it is copied: the running server's, else the saved one.
    func apiKeyForApps() -> String? {
        if state.isRunning { return activeAPIKey }
        return try? keyStore.read()
    }

    /// What `--model` was given for the server running now, to find its folder; nil when stopped.
    var runningModelSetting: String? { state.isRunning ? activeConfiguration?.model : nil }

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
        process.arguments = KapitsaServeArguments.serveArguments(configuration, installed: KapitsaModelStorage.installedModels())
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
                self.processExited = true
                self.finishExitOnceOutputEnds()
                // A process Kapitsa started may hold the output open after it exits; don't wait on it long.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.ownedProcess.map(ObjectIdentifier.init) == identity else { return }
                    self.handleProcessExit()
                }
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
            recentRequests = []
            totals = KapitsaSessionTotals()
            engine = KapitsaEngineInfo()
            processExited = false
            outputEnded = false
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                // Empty once the output has ended.
                if data.isEmpty { handle.readabilityHandler = nil }
                DispatchQueue.main.async {
                    guard let self, self.ownedProcess.map(ObjectIdentifier.init) == identity else { return }
                    if data.isEmpty {
                        self.outputEnded = true
                        self.finishExitOnceOutputEnds()
                    } else {
                        self.appendLog(data)
                    }
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
        scheduleShutdownTimer()
    }

    /// After the grace period, explains the wait or, while quitting, forces the owned process to
    /// quit: quitting the app, and logging out, would otherwise wait on it for ever.
    private func scheduleShutdownTimer() {
        shutdownTimer?.invalidate()
        shutdownTimer = Timer.scheduledTimer(withTimeInterval: stopGracePeriod, repeats: false) { [weak self] _ in
            guard let self, self.isStopping, let process = self.ownedProcess else { return }
            if self.quitCompletion != nil {
                self.shutdownMessage = "Kapitsa didn't stop in time, so it was forced to quit."
                self.forceStopProcess(process)
            } else {
                self.shutdownMessage = "Kapitsa is still shutting down. Waiting for the owned process to exit."
            }
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
        if isStopping { scheduleShutdownTimer() } else { stop() }
        return true
    }

    private func finishExitOnceOutputEnds() {
        if processExited && outputEnded { handleProcessExit() }
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
            // A model by name that doesn't load leaves the menus. A folder or file stays, since
            // the failure may pass (memory, a download); it leaves once it's gone from the disk.
            if let model = activeConfiguration?.model, !KapitsaKnownModels.isPath(model) { KapitsaKnownModels.forget(model) }
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
                recentRequests = [request] + recentRequests.prefix(Self.recentLimit - 1)
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
            // Assigned only when they change: every assignment redraws the windows watching this
            // controller, and the answer is nearly always the same as a second ago.
            switch result {
            case .success(let status):
                self.update(\.status, to: status)
                self.update(\.readiness, to: status.ready ? .ready : .loading)
                if status.ready && !self.hasReachedReady, let model = self.activeConfiguration?.model {
                    KapitsaKnownModels.remember(model)
                }
                if status.ready { self.hasReachedReady = true }
                self.update(\.statusErrorMessage, to: nil)
            case .failure(let error):
                self.update(\.readiness, to: .loading)
                self.update(\.statusErrorMessage, to: self.hasReachedReady ? error.localizedDescription : nil)
            }
        }
        if statusRequestInFlight && generation == pollingGeneration { statusRequest = request }
        else { request.cancel() }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<KapitsaProcessController, Value>,
                                          to value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
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
