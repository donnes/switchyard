import AppKit
import SwiftUI
import SwitchyardCore

struct RuleEditor: View {
    @State var rule: Rule
    let browsers: [AppInfo]
    /// Returns why the rule couldn't be saved, or nil when it was.
    let onSave: (Rule) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var saveFailed: String?
    @State private var patterns: String
    @State private var runningApps = AppCatalog.runningApps()

    init(rule: Rule, browsers: [AppInfo], onSave: @escaping (Rule) -> String?) {
        _rule = State(initialValue: rule)
        _patterns = State(initialValue: rule.match.joined(separator: "\n"))
        self.browsers = browsers
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: Binding(
                        get: { rule.name ?? "" },
                        set: { rule.name = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("Optional"))
                }

                Section {
                    ForEach(rule.from, id: \.self) { id in
                        LabeledContent(AppCatalog.name(for: id)) {
                            Button("Remove", systemImage: "minus.circle") { rule.from.removeAll { $0 == id } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    Menu("Add App") {
                        ForEach(runningApps.filter { !rule.from.contains($0.id) }) { app in
                            Button(app.name) { rule.from.append(app.id) }
                        }
                        Divider()
                        Button("Choose App…", action: chooseApp)
                    }
                    .fixedSize()
                } header: {
                    Text("From")
                } footer: {
                    Text("No apps means links from any app.").foregroundStyle(.secondary)
                }

                Section {
                    TextField("Patterns", text: $patterns, prompt: Text("Any link"), axis: .vertical)
                        .lineLimit(2...8)
                        .labelsHidden()
                        .font(.body.monospaced())
                } header: {
                    Text("Links")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let patternError {
                            Text(patternError).foregroundStyle(.red)
                        }
                        Text("One per line. Any of them fits. `github.com` covers its subdomains, `*://*.slack.com/client/T03/*` is a glob on the full link, `linear.app/team/*` skips the scheme, and `regex:` starts a regular expression.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Open in") {
                    TargetFields(target: $rule.open, browsers: browsers)
                }
            }
            .formStyle(.grouped)

            HStack {
                // The draft stays open so a refused save doesn't lose it.
                if let saveFailed {
                    Label(saveFailed, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    rule.match = patternList
                    saveFailed = onSave(rule)
                    if saveFailed == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(patternError != nil)
            }
            .padding()
        }
        .frame(width: 540, height: 600)
    }

    private var patternList: [String] {
        patterns.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var patternError: String? {
        for pattern in patternList {
            do { _ = try URLPattern(pattern) } catch { return "\(pattern) doesn't compile: \(error.localizedDescription)" }
        }
        return nil
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let app = AppCatalog.app(at: url),
              !rule.from.contains(app.id) else { return }
        rule.from.append(app.id)
    }
}

/// Browser, profile, container and background, for a rule or for Everything else.
struct TargetFields: View {
    @Binding var target: Target
    let browsers: [AppInfo]

    var body: some View {
        let kind = BrowserKind.of(target.browser)
        let known = ProfileCache.shared.profiles(for: kind)

        Picker("Browser", selection: Binding(
            get: { target.browser },
            // A new browser has different profiles, so the old choice doesn't carry over.
            set: { target = Target(browser: $0, background: target.background) }
        )) {
            ForEach(browserChoices) { Text($0.name).tag($0.id) }
        }

        // Shown with a configured profile even when discovery finds none, so it can be cleared.
        if !known.profiles.isEmpty || target.profile?.isEmpty == false {
            Picker("Profile", selection: Binding(
                // The config may hold a profile id, like Chrome's "Profile 3". Show it by name.
                get: { target.profile.map { known.profile(named: $0)?.name ?? $0 } ?? "" },
                set: { target.profile = $0.isEmpty ? nil : $0 }
            )) {
                Text("The browser's choice").tag("")
                ForEach(known.profiles, id: \.self) { Text($0.name).tag($0.name) }
                if let profile = target.profile, !profile.isEmpty, known.profile(named: profile) == nil {
                    Text("\(profile) (not found)").tag(profile)
                }
            }
        }

        if case .firefox = kind, !known.containers.isEmpty {
            Picker("Container", selection: optional(\.container)) {
                Text("None").tag("")
                ForEach(known.containers, id: \.self) { Text($0).tag($0) }
            }
            if target.container?.isEmpty == false, !known.hasContainerExtension {
                Label("Install the \"Open external links in a container\" extension in \(AppCatalog.name(for: target.browser)). Until then, links open without the container.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }

        Toggle("Open in the background", isOn: Binding(
            get: { target.background == true },
            set: { target.background = $0 ? true : nil }
        ))
    }

    /// Installed browsers, plus the configured one if it isn't installed, so the picker never shows blank.
    private var browserChoices: [AppInfo] {
        if browsers.contains(where: { $0.id == target.browser }) { return browsers }
        return browsers + [AppInfo(id: target.browser, name: "\(target.browser) (not installed)")]
    }

    private func optional(_ path: WritableKeyPath<Target, String?>) -> Binding<String> {
        Binding(
            get: { target[keyPath: path] ?? "" },
            set: { target[keyPath: path] = $0.isEmpty ? nil : $0 }
        )
    }
}
