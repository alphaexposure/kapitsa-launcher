import AppKit
import SwiftUI

/// The main window: sidebar, page header with the server controls, and the selected page.
struct ContentView: View {
    @ObservedObject var controller: KapitsaProcessController
    // Not observed here: only the Chat page redraws when the chat list or a conversation changes.
    let chats: KapitsaChatLibrary
    @State private var page: LauncherPage = .overview
    /// The chat this window or tab shows, kept when the app relaunches; empty until chosen.
    @SceneStorage("KapitsaLauncher.chatID") private var chatID = ""
    /// Words to open Find with in the chat just opened from a search; empty otherwise.
    @State private var findOnOpen = ""
    /// The chat the page draws. It follows `chatID` one frame late, so a click first shows the
    /// chosen chat selected and "Opening…" before the new chat's messages are laid out.
    @State private var shownChat: UUID?

    /// This window's chat: the one it showed last, else the most recent, else a new one.
    private var currentChat: UUID {
        if let id = UUID(uuidString: chatID) { return id }
        return chats.summaries.first?.id ?? Self.firstNewChat
    }

    /// Stands in for a window's chat until one is chosen, so it stays the same between redraws.
    private static let firstNewChat = UUID()

    private func openChat(_ id: UUID, find: String = "") {
        chatID = id.uuidString
        findOnOpen = find
        Task {
            // Long enough for the selection and "Opening…" to be drawn first.
            try? await Task.sleep(for: .milliseconds(30))
            if chatID == id.uuidString { shownChat = id }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(KapitsaTheme.border).frame(width: 1)
            VStack(spacing: 0) {
                // As wide as the page below it, so the title and buttons line up with its edges.
                pageHeader
                    .padding(.horizontal, 30)
                    .padding(.top, 30)
                    .padding(.bottom, 24)
                    .frame(maxWidth: page == .chat ? 1360 : 1000, alignment: .leading)
                    .frame(maxWidth: .infinity)
                pageContent
            }
            .frame(maxWidth: .infinity)
            .background(KapitsaTheme.canvas)
        }
        .tint(KapitsaTheme.accent)
        .frame(minWidth: 850, minHeight: 650)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview: scrolling { OverviewPage(controller: controller, labels: chats.requestLabels) }
        case .settings: scrolling { SettingsPage(controller: controller) }
        case .app: scrolling { AppPage() }
        case .chat:
            // The conversation has its own scroll view, with the message box pinned below it.
            let shown = shownChat ?? currentChat
            // The thinking buttons follow the model running, else the one that ran last.
            let thinkingModel = controller.engine.model ?? UserDefaults.standard.string(forKey: KapitsaThinkingChoice.lastModelKey)
            ChatPage(server: ChatServerFacts(connection: controller.chatConnection, isRunning: controller.state.isRunning,
                                             contextTokens: controller.engine.contextTokens, thinkingModel: thinkingModel,
                                             thinking: thinkingModel.map {
                                                 KapitsaThinkingOptions.forModel($0, configured: controller.runningModelSetting)
                                             } ?? .onOff),
                     chat: chats.controller(for: shown), chats: chats, chatID: shown,
                     selectedChat: currentChat, isOpening: shown != currentChat,
                     onSelectChat: { openChat($0) },
                     onOpenSearchResult: { openChat($0, find: $1) },
                     initialFind: findOnOpen)
                // Skips the redraws the server's status checks and log lines would cause.
                .equatable()
                // A different chat starts a fresh page: its own scroll position, sheets and draft.
                .id(shown)
                .onChange(of: controller.engine.model, initial: true) {
                    if let model = controller.engine.model {
                        UserDefaults.standard.set(model, forKey: KapitsaThinkingChoice.lastModelKey)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 24)
                // Wider than the other pages, so the outline adds room instead of taking it from the chat.
                .frame(maxWidth: 1360, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity)
        case .logs:
            // The log has its own scroll view, so it fills the window instead of scrolling with the page.
            LogsPage(controller: controller)
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
                .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity)
        }
    }

    private func scrolling<Page: View>(@ViewBuilder _ page: () -> Page) -> some View {
        ScrollView {
            page()
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }

    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.rawValue).font(.system(size: 28, weight: .semibold))
            Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    pageTitle.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    serverControls
                }
                VStack(alignment: .leading, spacing: 16) {
                    pageTitle
                    serverControls
                }
            }
            if let message = controller.shutdownMessage { Notice(message, symbol: "hourglass") }
            if let error = controller.statusErrorMessage { Notice(error, symbol: "exclamationmark.circle") }
            if let error = controller.launchErrorMessage { Notice(error, symbol: "exclamationmark.triangle", isError: true) }
        }
    }

    private var serverControls: some View {
        HStack(spacing: 10) {
            Button { controller.start() } label: { Label("Start", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .tint(KapitsaTheme.accentFill)
                .disabled(!controller.hasExecutable || controller.state.isRunning)
            Button { controller.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!controller.state.isRunning || controller.isStopping)
            Button { controller.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .disabled(!controller.hasExecutable)
        }
        .controlSize(.large).buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 10) {
                KapitsaMarkShape()
                    .fill(KapitsaTheme.accent)
                    .frame(width: 24, height: 24)
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                    .background(KapitsaTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                // Two lines so the full name fits the sidebar without truncating.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Kapitsa").font(.system(size: 17, weight: .semibold))
                    Text("Launcher").font(.system(size: 17, weight: .semibold))
                    Text("FOR APPLE SILICON").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.secondary).padding(.top, 3)
                }
                .lineLimit(1)
                .fixedSize()
            }
            VStack(spacing: 6) {
                ForEach(LauncherPage.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.rawValue).fontWeight(page == item ? .semibold : .regular)
                            Spacer()
                        }
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .foregroundStyle(page == item ? KapitsaTheme.accent : Color.primary.opacity(0.75))
                        .background(page == item ? KapitsaTheme.accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? [.isSelected] : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                StatusBadge(controller: controller)
                Text("Always within reach")
                    .font(.caption.weight(.semibold))
                Text("Use the Kapitsa Launcher menu bar icon to reopen this window or stop your server.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
            .padding(.horizontal, 5)
        }
        .padding(20)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(KapitsaTheme.sidebar)
    }
}
