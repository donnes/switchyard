import SwiftUI
import SwitchyardCore

struct SettingsView: View {
    let store: ConfigStore
    @State private var browsers = AppCatalog.browsers()
    @State private var editing: RuleDraft?
    @State private var isDefault = AppCatalog.isDefaultBrowser

    var body: some View {
        Form {
            if let error = store.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }

            Section {
                if store.config.rules.isEmpty {
                    Text("No rules yet. Every link opens as Everything else says.").foregroundStyle(.secondary)
                }
                ForEach(store.config.rules) { rule in
                    RuleRow(store: store, rule: rule) { editing = RuleDraft(original: rule, isNew: false) }
                }
            } header: {
                SectionTitle("Rules", "Checked from the top. The first rule that fits a link decides where it opens.")
            }

            Section {
                TargetFields(target: Binding(
                    get: { store.config.fallback },
                    set: { value in store.update { $0.fallback = value } }
                ), browsers: browsers)
            } header: {
                SectionTitle("Everything else", "Where links that no rule catches open.")
            }

            Section {
                TryLinkView(store: store)
            } header: {
                SectionTitle("Try a link", "See where a link from an app would open. Nothing opens.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Switchyard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isDefault {
                    Label("Default Browser", systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .padding(.trailing, 8)
                        .help("Links from other apps come to Switchyard first.")
                } else {
                    Button("Make Default Browser…") {
                        AppCatalog.becomeDefaultBrowser()
                    }
                    .buttonStyle(.glassProminent)
                    .help("Links from other apps won't reach Switchyard until it's the default browser.")
                }
            }
            // The status label is plain text. A glass capsule makes it look like a button and clips its title.
            .sharedBackgroundVisibility(isDefault ? .hidden : .automatic)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Add Rule", systemImage: "plus") {
                    editing = RuleDraft(original: Rule(open: Target(browser: store.config.fallback.browser)), isNew: true)
                }
                .help("Add Rule")
            }
        }
        .sheet(item: $editing) { draft in
            RuleEditor(rule: draft.original, browsers: browsers, onSave: { saved in
                // The draft started from `draft.original`. If config.json changed that rule since, saving
                // would quietly undo the change, or bring back a rule someone removed.
                let current = store.config.rules.first { $0.id == saved.id }
                if !draft.isNew, current != draft.original {
                    return current == nil
                        ? "This rule was removed from \(store.url.lastPathComponent) while you edited it."
                        : "This rule changed in \(store.url.lastPathComponent) while you edited it. Cancel and open it again."
                }
                return store.update { config in
                    if let index = config.rules.firstIndex(where: { $0.id == saved.id }) {
                        config.rules[index] = saved
                    } else {
                        config.rules.append(saved)
                    }
                }
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = AppCatalog.isDefaultBrowser
            browsers = AppCatalog.browsers()
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// A rule open in the editor, with the rule as it was when the editor opened.
struct RuleDraft: Identifiable {
    let original: Rule
    let isNew: Bool
    var id: String { original.id }
}

struct RuleRow: View {
    let store: ConfigStore
    let rule: Rule
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { rule.enabled },
                set: { value in change { $0.enabled = value } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            Button("Edit", systemImage: "pencil", action: edit)
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Move Up") { move(by: -1) }.disabled(index == 0)
                Button("Move Down") { move(by: 1) }.disabled(index == store.config.rules.count - 1)
                Button("Duplicate") {
                    store.update { config in
                        var copy = rule
                        copy.id = Rule.newID()
                        config.rules.insert(copy, at: (index ?? config.rules.count - 1) + 1)
                    }
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Button("Delete", systemImage: "trash") {
                store.update { $0.rules.removeAll { $0.id == rule.id } }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private var index: Int? { store.config.rules.firstIndex { $0.id == rule.id } }

    private var title: Text {
        let target = AppCatalog.label(for: rule.open)
        guard let name = rule.name, !name.isEmpty else { return Text(target) }
        return Text("\(name) \(Text("→ \(target)").foregroundStyle(.secondary))")
    }

    private var summary: String {
        let apps = rule.from.isEmpty ? "Any app" : rule.from.map(AppCatalog.name(for:)).joined(separator: ", ")
        let links = rule.match.isEmpty ? "any link" : rule.match.joined(separator: ", ")
        return "\(apps) · \(links)"
    }

    private func change(_ edit: @escaping (inout Rule) -> Void) {
        store.update { config in
            if let i = config.rules.firstIndex(where: { $0.id == rule.id }) { edit(&config.rules[i]) }
        }
    }

    private func move(by offset: Int) {
        store.update { config in
            guard let i = config.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            let j = i + offset
            guard config.rules.indices.contains(j) else { return }
            config.rules.swapAt(i, j)
        }
    }
}

struct TryLinkView: View {
    let store: ConfigStore
    @State private var source = ""
    @State private var text = ""
    @State private var apps = AppCatalog.runningApps()

    var body: some View {
        Picker("From", selection: $source) {
            Text("An unknown app").tag("")
            Divider()
            ForEach(apps) { Text($0.name).tag($0.id) }
        }
        TextField("Link", text: $text, prompt: Text("Paste a link, like github.com/ardia"))
        Text(result).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private var result: String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let link = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              link.host() != nil else {
            return "Type a link to see where it lands."
        }
        let decision = store.router.decide(url: link, from: source.isEmpty ? nil : source)
        let reason: String
        if let id = decision.ruleID, let index = store.config.rules.firstIndex(where: { $0.id == id }) {
            let name = store.config.rules[index].name.flatMap { $0.isEmpty ? nil : "\"\($0)\"" }
            reason = "Rule \(index + 1)\(name.map { " \($0)" } ?? "") fits"
        } else {
            reason = "No rule fits, so Everything else decides"
        }
        let destination = AppCatalog.label(for: decision.target)
        do {
            let plan = try LaunchPlanner.plan(link: link, target: decision.target, profiles: ProfileCache.shared.profiles(for:))
            return "\(reason): \(destination).\n\(describe(plan))"
        } catch {
            return "\(reason): \(destination).\nProblem: \(error) The link would open in \(AppCatalog.name(for: decision.target.browser)) without a profile."
        }
    }

    private func describe(_ plan: LaunchPlan) -> String {
        switch plan {
        case .open(let link, _, _): "Hands \(link.absoluteString) to the app."
        case .arguments(_, let args, _): "Starts it with: \(args.joined(separator: " "))"
        case .ardia(_, let profileID, _): "Asks Ardia over its control socket to open it in profile \(profileID)."
        }
    }
}
