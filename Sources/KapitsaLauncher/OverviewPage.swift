import AppKit
import SwiftUI

/// Server status, what Kapitsa reported about its engine, token activity and the latest request.
struct OverviewPage: View {
    @ObservedObject var controller: KapitsaProcessController
    @ObservedObject var labels: KapitsaRequestLabels
    /// Show the latest chat reply, or the latest request of any kind, background ones included.
    @AppStorage("KapitsaLauncher.overviewShowsChatReplies") private var showsChatReplies = true

    private var isLive: Bool { controller.readiness == .ready && !controller.isStopping }
    private var engine: KapitsaEngineInfo? { isLive ? controller.engine : nil }

    /// The model shown in the Server panel: the one Kapitsa loaded while ready, otherwise the
    /// selected model.
    private var displayedModel: String {
        if let model = engine?.model { return model }
        return controller.configuration.model.isEmpty ? "Best model for this Mac" : controller.configuration.model
    }

    private var copyModelButton: some View {
        CopyButton(text: displayedModel, help: "Copy the model name to the clipboard") { copied in
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 26, height: 26)
                .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy model name")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MissingKapitsaNotice(controller: controller)
            Panel("Server", symbol: "power") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(engine?.model == nil ? "Selected model" : "Loaded model")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 8) {
                            ModelSwitcher(controller: controller, isLarge: true)
                            copyModelButton
                        }
                    }
                    Spacer(minLength: 12)
                    StatusBadge(controller: controller)
                }
                if isLive {
                    HStack(spacing: 8) {
                        Image(systemName: "network")
                        Text(engine?.address ?? "\(controller.configuration.host):\(String(controller.configuration.port))")
                            .textSelection(.enabled)
                        if let gpu = engine?.gpu {
                            Image(systemName: "cpu").padding(.leading, 8)
                            Text(gpu)
                        }
                        // Kapitsa's own chat page, in the browser; the header keeps to Start, Stop and Restart.
                        if let url = controller.webUIURL {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Label("Open Kapitsa's web page", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.plain).foregroundStyle(KapitsaTheme.accent).padding(.leading, 8)
                            .help("Open Kapitsa's own chat page in your browser")
                        }
                        Spacer()
                        if let pid = controller.state.processID { Text("PID \(String(pid))") }
                    }.font(.caption).foregroundStyle(.secondary)
                } else if controller.state.isRunning, !controller.isStopping, let download = controller.engine.download {
                    VStack(alignment: .leading, spacing: 6) {
                        if let percent = download.percent {
                            ProgressView(value: Double(percent), total: 100).tint(KapitsaTheme.accentFill)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(KapitsaTheme.accentFill)
                        }
                        HStack {
                            Text(download.summary)
                            Spacer()
                            if let percent = download.percent { Text("\(percent)%").monospacedDigit() }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        Text("The first start of a model downloads it; later starts load it from this Mac. It loads once the download finishes.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(controller.isStopping ? "Waiting for Kapitsa to finish shutting down…"
                         : controller.state.isRunning ? "Loading the model and starting the server. The first start downloads it, which can take a while."
                         : "Ready when you are. Start Kapitsa to load your model.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Engine").font(.headline)
                Spacer()
                Text(engine == nil ? "Available once the server is ready" : "Reported by Kapitsa at startup")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                metricCard("Context per conversation", value: engine?.contextTokens.map { $0.formatted() } ?? "—",
                           detail: engine?.slots.map { "tokens · \($0) slots" } ?? "tokens", symbol: "text.alignleft",
                           help: "The most tokens one conversation can hold, after Kapitsa sized it for this Mac's memory or your Context setting. Slots are the requests Kapitsa runs at once, each keeping its conversation ready for instant follow-ups.")
                metricCard("Memory allocated", value: gigabytes(engine?.allocatedGB), detail: "model, buffers and slots",
                           symbol: "memorychip",
                           help: "GPU memory Kapitsa allocated at startup for the model's weights, its working buffers and every slot's state.")
                metricCard("Memory budget", value: gigabytes(engine?.budgetGB),
                           detail: engine?.recommendedGB.map { "of \(gigabytes($0)) macOS recommends" } ?? "GPU memory Kapitsa may hold",
                           symbol: "gauge.with.dots.needle.50percent",
                           help: "The GPU memory Kapitsa may hold: by default a little less than the working set macOS recommends for this GPU, or the Memory budget you set.")
                metricCard("KV cache room", value: gigabytes(engine?.kvRoomGB),
                           detail: engine?.kvTokens.map { "\($0.formatted()) tokens across all slots" } ?? "for conversations",
                           symbol: "square.stack.3d.up",
                           help: "Memory left in the budget for conversations' key-value cache, and how many tokens it holds in total across every slot.")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal").foregroundStyle(KapitsaTheme.accent)
                    Text("Decoding")
                    SettingHelpIcon(title: "Decoding", message: "How Kapitsa generates tokens for this model, for example speculative decoding with a DFlash2 drafter, and whether it reads images.")
                    Spacer(minLength: 16)
                    Text(engine?.decoding ?? "—").foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                if let leftOut = engine?.drafterLeftOut {
                    Label {
                        Text("Kapitsa left out the faster DFlash2 drafter: its \(gigabytes(leftOut.drafterGB)) wouldn't fit beside a \(leftOut.contextTokens.formatted())-token conversation, so replies are written more slowly. To get the drafter back, set a smaller Context per conversation in Settings, or leave it blank so Kapitsa chooses the largest context that still leaves room for the drafter.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(KapitsaTheme.accent)
                    }
                }
            }
            .font(.callout).padding(18).background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("Token activity").font(.headline)
                Spacer()
                Text(controller.totals.requests == 0 ? "Across all requests · this server session"
                     : "Across \(controller.totals.requests.formatted()) \(controller.totals.requests == 1 ? "request" : "requests") · this server session")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let totals = controller.totals
            let hasActivity = totals.requests > 0
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                metricCard("Prompt tokens processed", value: hasActivity ? totals.prefilledTokens.formatted() : "—",
                           detail: !hasActivity ? "cumulative prefill tokens"
                               : totals.cachedTokens == 0 ? "none reused from cache"
                               : "\(totals.cachedTokens.formatted()) more reused from cache",
                           symbol: "text.badge.plus",
                           help: "Prompt tokens Kapitsa had to process across all requests. Tokens reused from its prefix cache (in memory or on the SSD) are counted separately. Resets when the server restarts.")
                metricCard("Output tokens generated", value: hasActivity ? totals.outputTokens.formatted() : "—",
                           detail: "cumulative decode tokens", symbol: "text.bubble",
                           help: "Tokens Kapitsa generated across all requests in this server session, including any reasoning tokens. Resets when the server restarts.")
                metricCard("Prompt processing speed", value: rate(totals.prefillTokensPerSecond),
                           detail: "tokens/sec · session average", symbol: "arrow.down.doc",
                           help: "Processed prompt tokens ÷ the time Kapitsa spent processing prompts, across this session. Calculated by the launcher from Kapitsa's request lines.")
                metricCard("Generation speed", value: rate(totals.decodeTokensPerSecond),
                           detail: "tokens/sec · session average", symbol: "speedometer",
                           help: "Output tokens ÷ the time Kapitsa spent generating them, across this session. Calculated by the launcher from Kapitsa's request lines.")
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(KapitsaTheme.accent)
                Text("Prefix cache hits")
                SettingHelpIcon(title: "Prefix cache hits", message: "The share of prompt tokens Kapitsa reused from an earlier request instead of processing again. Follow-ups in the same conversation usually hit the cache.")
                Spacer()
                Text(totals.cacheHitRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout).padding(18).background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            latestRequestSection
            ConnectAppPanel(controller: controller)
        }
    }

    @ViewBuilder
    private var latestRequestSection: some View {
        let request = showsChatReplies
            ? controller.recentRequests.first { labels.kind(of: $0) == .chatReply } : controller.lastRequest
        HStack(spacing: 10) {
            Text(showsChatReplies ? "Latest chat reply" : "Latest request").font(.headline)
            KapitsaSegmentedPicker(options: [true, false], selection: $showsChatReplies) { $0 ? "Chat reply" : "Any request" }
                .fixedSize()
                .accessibilityLabel("Show")
            .help("Chat reply shows your latest answer in the Chat page. Any request also shows the short background requests the launcher makes for the topic index, and export summaries.")
            Spacer()
            Text(request.map { "\(requestTitle($0)) · finished at \($0.finishedAt)" }
                 ?? (!controller.state.isRunning ? "Available once Kapitsa handles a request"
                     : showsChatReplies ? "Waiting for a chat reply" : "Waiting for the first request"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], alignment: .leading, spacing: 12) {
            requestRow("Prompt tokens", value: request.map { "\($0.promptTokens.formatted()) (\($0.cachedTokens.formatted()) cached)" },
                       help: "Input tokens in the request, as counted by Kapitsa. Cached tokens were reused from an earlier request and did not need processing again.")
            requestRow("Prefill time", value: request.map { formattedSeconds($0.prefillSeconds) },
                       help: "Time Kapitsa spent processing the prompt before generating, as it measured it.")
            requestRow("Output tokens", value: request.map { $0.outputTokens.formatted() },
                       help: "Tokens the model generated, including any reasoning (thinking) tokens.")
            requestRow("Prompt processing", value: request?.prefillTokensPerSecond.map(formattedRate),
                       help: "Uncached prompt tokens ÷ prefill time.")
            requestRow("Finish reason", value: request.map { $0.stopReason ?? "Not reported" },
                       help: "Why generation ended: stop means the model finished its answer; length means it reached the token limit.")
            requestRow("Decode time", value: request.map { formattedSeconds($0.decodeSeconds) },
                       help: "Time Kapitsa spent generating the output tokens, as it measured it.")
            requestRow("Time to first token", value: request.map { "≈ " + formattedSeconds($0.prefillSeconds) },
                       help: "Kapitsa doesn't print TTFT, so the launcher uses the prefill time. It leaves out template rendering and any wait for a free slot.")
            requestRow("Decode speed", value: request?.decodeTokensPerSecond.map(formattedRate),
                       help: "Generation speed Kapitsa reported for this request.")
            requestRow("Total response time", value: request.map { "≈ " + formattedSeconds($0.totalSeconds) },
                       help: "Prefill time + decode time. Kapitsa doesn't print the request's total time, so this is calculated.")
            requestRow("End-to-end speed", value: request?.endToEndTokensPerSecond.map { "≈ " + formattedRate($0) },
                       help: "Output tokens ÷ total response time: the effective speed you experienced, including the wait for the first token.")
            requestRow("Tokens per draft cycle", value: request?.tokensPerCycle.map { $0.formatted(.number.precision(.fractionLength(2))) },
                       help: "With speculative decoding, the tokens Kapitsa accepted per verification step. Higher means the drafter guessed well and generation ran faster.")
        }
        .padding(18)
        .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KapitsaTheme.border, lineWidth: 1))
    }

    private func requestTitle(_ request: KapitsaRequestMetrics) -> String {
        labels.kind(of: request)?.title ?? "From another app or Kapitsa's web page"
    }

    private func requestRow(_ title: String, value: String?, help: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            SettingHelpIcon(title: title, message: help)
            Spacer(minLength: 8)
            Text(value ?? "—").font(.callout.weight(.medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8).textSelection(.enabled)
        }
    }

    private func formattedSeconds(_ seconds: Double) -> String {
        guard seconds >= 60 else { return seconds.formatted(.number.precision(.fractionLength(seconds < 10 ? 2 : 1))) + " s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(String(format: "%02d", whole % 60)) s"
    }

    private func formattedRate(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(1))) + " tok/s"
    }

    private func metricCard(_ title: String, value: String, detail: String, symbol: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(KapitsaTheme.accent)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                SettingHelpIcon(title: title, message: help)
            }
            Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(KapitsaTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KapitsaTheme.border, lineWidth: 1))
    }

    private func rate(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate >= 0 else { return "—" }
        return rate.formatted(.number.precision(.fractionLength(1)))
    }

    /// Kapitsa reports memory in decimal gigabytes.
    private func gigabytes(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + " GB"
    }
}
