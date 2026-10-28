import SwiftUI

/// A row of choices with the chosen one filled in the theme's indigo. macOS draws its own
/// segmented control in the system blue while the window is active, whatever the app's tint.
struct KapitsaSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    /// Each choice's width; nil shares the width offered between them.
    var segmentWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let isSelected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.callout)
                        .lineLimit(1)
                        .frame(width: segmentWidth)
                        .frame(maxWidth: segmentWidth == nil ? .infinity : nil)
                        .padding(.horizontal, segmentWidth == nil ? 8 : 0).padding(.vertical, 3)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(isSelected ? KapitsaTheme.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                // A divider between two unchosen neighbours, as macOS draws them.
                if index < options.count - 1 {
                    Rectangle().fill(KapitsaTheme.border).frame(width: 1, height: 12)
                        .opacity(isSelected || options[index + 1] == selection ? 0 : 1)
                }
            }
        }
        .padding(2)
        .background(KapitsaTheme.inset, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(KapitsaTheme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// The model to run, chosen from a menu: downloaded models, then Kapitsa's catalog. While
/// Kapitsa runs, a change asks first, then restarts it with the new model; the Settings page
/// has the rest (another model by name or folder, context, slots).
struct ModelSwitcher: View {
    @ObservedObject var controller: KapitsaProcessController
    /// A reply is being written, so switching now would cut it off.
    var isBusy = false
    /// The Overview's large name, or the Chat toolbar's small one.
    var isLarge = false
    @State private var installed: [String] = []
    @State private var pending: String?

    /// What the menu's button says: the model running, else the one chosen.
    private var shownName: String {
        if let model = controller.engine.model { return model }
        return Self.name(of: controller.configuration.model)
    }

    static func name(of model: String) -> String {
        if model.isEmpty { return "Best model for this Mac" }
        return KapitsaConfiguration.catalogModels.first { $0.name == model }?.label ?? model
    }

    var body: some View {
        Menu {
            choice("", title: "Best model for this Mac")
            if !installed.isEmpty {
                Section("Downloaded") {
                    ForEach(installed, id: \.self) { name in
                        choice(name, title: KapitsaConfiguration.catalogModel(forDownloaded: name)
                            .map { "\(name) — \($0.label), \($0.architecture)" } ?? name)
                    }
                }
            }
            Section("Kapitsa catalog") {
                ForEach(KapitsaConfiguration.catalogModels, id: \.name) { model in
                    choice(model.name, title: "\(model.label) (\(model.name)) — \(model.details(physicalMemoryGB: KapitsaConfiguration.physicalMemoryGB))")
                }
            }
            let current = controller.configuration.model
            if !current.isEmpty && !installed.contains(current) && !KapitsaConfiguration.catalogModels.contains(where: { $0.name == current }) {
                Section("From Settings") { choice(current, title: current) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(shownName).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: isLarge ? 11 : 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(isLarge ? .system(size: 18, weight: .semibold) : .caption)
            .foregroundStyle(isLarge ? Color.primary : Color.secondary)
            .padding(.horizontal, isLarge ? 0 : 8).padding(.vertical, isLarge ? 0 : 2)
            .overlay {
                if !isLarge { Capsule().stroke(KapitsaTheme.border, lineWidth: 1) }
            }
            .contentShape(Rectangle())
            // One element for VoiceOver, not the name and the chevron apart.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Model: \(shownName)")
        }
        // A plain button keeps the label as drawn; the borderless menu style redraws it small, in the tint.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy || controller.isStopping)
        .help(isBusy ? "Wait for the reply to finish before switching models"
              : controller.state.isRunning ? "Switch models: Kapitsa restarts and loads the one you choose"
              : "Choose the model Kapitsa starts with")
        .accessibilityLabel("Model: \(shownName)")
        .onAppear { installed = KapitsaModelStorage.installedModels() }
        .confirmationDialog("Switch to \(Self.name(of: pending ?? ""))?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Restart with It") {
                guard let model = pending else { return }
                pending = nil
                controller.configuration.model = model
                controller.restart()
            }
        } message: {
            Text("Kapitsa stops and loads the new model, which takes from several seconds to a minute; a model not downloaded yet is downloaded first. Its first reply reads your chat again, and its context may be smaller, so a long chat may come nearer the limit.")
        }
    }

    private func choice(_ model: String, title: String) -> some View {
        Button {
            guard model != controller.configuration.model else { return }
            if controller.state.isRunning { pending = model } else { controller.configuration.model = model }
        } label: {
            if model == controller.configuration.model { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
