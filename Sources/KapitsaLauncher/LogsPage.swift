import SwiftUI

/// Kapitsa's server output: long lines wrap, a filter and a choice of All, Requests or
/// Problems narrow it, and warnings and errors stand out. Auto-scroll, Copy and Clear as before.
struct LogsPage: View {
    @ObservedObject var controller: KapitsaProcessController
    @State private var followLogs = true
    @State private var filter = ""
    @State private var show = Show.all
    private let logEndID = "log-end"

    enum Show: Hashable { case all, requests, problems }

    var body: some View {
        let lines = Self.lines(controller.logs, show: show, filter: filter)
        Panel("Server output", symbol: "terminal") {
            HStack(spacing: 10) {
                KapitsaSegmentedPicker(options: [Show.all, .requests, .problems], selection: $show) { show in
                    switch show {
                    case .all: return "All"
                    case .requests: return "Requests"
                    case .problems: return "Warnings and errors"
                    }
                }
                .fixedSize()
                .accessibilityLabel("Show")
                .help("All: everything Kapitsa printed. Requests: a line per request it answered. Warnings and errors: only lines about problems.")
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .onExitCommand { filter = "" }
                Spacer()
                Toggle("Auto-scroll", isOn: $followLogs)
                    .toggleStyle(.checkbox)
                    .help("Keep the newest output in view. Turn off to read earlier lines while Kapitsa is busy.")
                CopyButton(text: lines.isEmpty ? controller.logs : lines.map(\.text).joined(separator: "\n"),
                           help: "Copy the lines shown to the clipboard. API keys are already redacted.") { copied in
                    Text(copied ? "Copied" : "Copy")
                }
                .disabled(controller.logs.isEmpty)
                Button("Clear logs") { controller.clearLogs() }.disabled(controller.logs.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if controller.logs.isEmpty {
                            Text("No activity yet. Server output will appear here after you start Kapitsa.")
                                .foregroundStyle(.secondary)
                        } else if lines.isEmpty {
                            Text("No lines match.").foregroundStyle(.secondary)
                        }
                        ForEach(lines) { line in
                            Text(line.text)
                                .foregroundStyle(Self.color(line.kind))
                                .fontWeight(line.kind == .error ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 1).id(logEndID)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                }
                .onAppear { proxy.scrollTo(logEndID, anchor: .bottom) }
                .onChange(of: controller.logs) {
                    if followLogs { proxy.scrollTo(logEndID, anchor: .bottom) }
                }
                .onChange(of: followLogs) {
                    if followLogs { proxy.scrollTo(logEndID, anchor: .bottom) }
                }
            }
            .frame(minHeight: 240, maxHeight: .infinity)
            .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    struct Line: Identifiable, Equatable {
        enum Kind { case plain, request, warning, error }
        let id: Int
        let text: String
        let kind: Kind
    }

    /// The log's lines, each with what it's about, narrowed to `show` and `filter`.
    static func lines(_ log: String, show: Show, filter: String) -> [Line] {
        let filter = filter.trimmingCharacters(in: .whitespaces)
        return log.split(separator: "\n", omittingEmptySubsequences: true).enumerated().compactMap { index, text in
            let line = Line(id: index, text: String(text), kind: kind(of: text))
            switch show {
            case .all: break
            case .requests: guard line.kind == .request else { return nil }
            case .problems: guard line.kind == .warning || line.kind == .error else { return nil }
            }
            guard filter.isEmpty || line.text.localizedCaseInsensitiveContains(filter) else { return nil }
            return line
        }
    }

    static func kind(of line: some StringProtocol) -> Line.Kind {
        let lower = line.lowercased()
        if ["error", "failed", "fatal", "exception", "refused", "can't", "cannot", "could not"].contains(where: lower.contains) {
            return .error
        }
        if lower.contains("warning") || lower.contains("⚠") || lower.contains("deprecated") { return .warning }
        if lower.contains("chat: prompt") { return .request }
        return .plain
    }

    static func color(_ kind: Line.Kind) -> Color {
        switch kind {
        case .plain: return .secondary
        case .request: return .primary
        case .warning: return KapitsaTheme.accent
        case .error: return .red
        }
    }
}
