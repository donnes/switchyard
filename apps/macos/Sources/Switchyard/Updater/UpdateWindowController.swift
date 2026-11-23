import AppKit
import SwitchyardCore

/// Native AppKit "Software Update" window matching macOS / Sparkle conventions.
/// Created only while an update session is active and released when closed.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    enum Mode {
        case checking
        case available(release: ReleaseInfo, currentVersion: String)
        case downloading(version: String, fraction: Double?, detail: String)
        case installing(version: String, detail: String, canCancel: Bool)
    }

    let window: NSWindow
    var onCancel: (() -> Void)?
    var onInstall: (() -> Void)?
    var onOpenReleasePage: (() -> Void)?

    private var canClose = true
    private var currentKind: Kind?

    // Retained only for in-place updates during downloading/installing so the bar animates smoothly.
    private var progressTitleField: NSTextField?
    private var progressDetailField: NSTextField?
    private var progressIndicator: NSProgressIndicator?
    private var cancelButton: NSButton?

    private enum Kind {
        case checking
        case available
        case progress
    }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 122),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func show(_ mode: Mode, activate: Bool = true) {
        switch mode {
        case .checking:
            installCheckingView()
        case .available(let release, let currentVersion):
            installAvailableView(release: release, currentVersion: currentVersion)
        case .downloading(let version, let fraction, let detail):
            updateProgressView(
                title: "Downloading Switchyard \(version)…",
                detail: detail,
                fraction: fraction,
                canCancel: true
            )
        case .installing(let version, let detail, let canCancel):
            updateProgressView(
                title: "Installing Switchyard \(version)…",
                detail: detail,
                fraction: nil,
                canCancel: canCancel
            )
        }

        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        canClose = true
        window.delegate = nil
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canClose else { return false }
        onCancel?()
        return false
    }

    // MARK: - Views

    private func installCheckingView() {
        canClose = true
        clearProgressRefs()
        currentKind = .checking

        let content = NSView()
        let icon = makeAppIconView()
        let title = makeLabel("Checking for updates…", font: .boldSystemFont(ofSize: 13))

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.controlSize = .regular
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.startAnimation(nil)

        let cancel = makeButton("Cancel", action: #selector(cancelClicked), keyEquivalent: "\u{1b}")

        content.addSubview(icon)
        content.addSubview(title)
        content.addSubview(bar)
        content.addSubview(cancel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),

            cancel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 16),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),
        ])

        setWindowContent(content, size: NSSize(width: 420, height: 122), resizable: false)
    }

    private func installAvailableView(release: ReleaseInfo, currentVersion: String) {
        canClose = true
        clearProgressRefs()
        currentKind = .available

        let content = NSView()
        let icon = makeAppIconView()
        let title = makeLabel("A new version of Switchyard is available!", font: .boldSystemFont(ofSize: 13))
        let subtitle = makeLabel(
            "Switchyard \(release.version) is now available—you have \(currentVersion). Would you like to install it now?",
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor,
            wrapping: true
        )
        let notesHeader = makeLabel("Release Notes:", font: .systemFont(ofSize: 12, weight: .semibold))
        let notesScroll = makeReleaseNotesView(markdown: ReleaseNotesFormatter.cleanMarkdown(release.notes))

        let viewOnGitHub = makeButton("View on GitHub", action: #selector(openReleasePageClicked))
        let later = makeButton("Later", action: #selector(cancelClicked), keyEquivalent: "\u{1b}")
        let install = makeButton("Install Update", action: #selector(installClicked), keyEquivalent: "\r")
        install.bezelColor = .controlAccentColor

        content.addSubview(icon)
        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(notesHeader)
        content.addSubview(notesScroll)
        content.addSubview(viewOnGitHub)
        content.addSubview(later)
        content.addSubview(install)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            notesHeader.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            notesHeader.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            notesHeader.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),

            notesScroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            notesScroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            notesScroll.topAnchor.constraint(equalTo: notesHeader.bottomAnchor, constant: 6),
            notesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),

            viewOnGitHub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            viewOnGitHub.topAnchor.constraint(equalTo: notesScroll.bottomAnchor, constant: 16),
            viewOnGitHub.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            install.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            install.centerYAnchor.constraint(equalTo: viewOnGitHub.centerYAnchor),
            install.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            later.trailingAnchor.constraint(equalTo: install.leadingAnchor, constant: -10),
            later.centerYAnchor.constraint(equalTo: viewOnGitHub.centerYAnchor),
            later.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),
        ])

        setWindowContent(content, size: NSSize(width: 520, height: 370), resizable: true)
        window.minSize = NSSize(width: 460, height: 300)
    }

    private func updateProgressView(title: String, detail: String, fraction: Double?, canCancel: Bool) {
        canClose = canCancel

        if currentKind != .progress {
            currentKind = .progress

            let content = NSView()
            let icon = makeAppIconView()
            let titleField = makeLabel(title, font: .boldSystemFont(ofSize: 13))
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.controlSize = .regular
            bar.minValue = 0
            bar.maxValue = 1
            bar.translatesAutoresizingMaskIntoConstraints = false

            let detailField = makeLabel(detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            let cancel = makeButton("Cancel", action: #selector(cancelClicked), keyEquivalent: "\u{1b}")

            content.addSubview(icon)
            content.addSubview(titleField)
            content.addSubview(bar)
            content.addSubview(detailField)
            content.addSubview(cancel)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                icon.widthAnchor.constraint(equalToConstant: 56),
                icon.heightAnchor.constraint(equalToConstant: 56),

                titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
                titleField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
                titleField.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

                bar.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
                bar.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 10),

                detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
                detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
                detailField.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),

                cancel.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
                cancel.topAnchor.constraint(equalTo: detailField.bottomAnchor, constant: 14),
                cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
                cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),
            ])

            progressTitleField = titleField
            progressDetailField = detailField
            progressIndicator = bar
            cancelButton = cancel

            setWindowContent(content, size: NSSize(width: 420, height: 142), resizable: false)
        }

        progressTitleField?.stringValue = title
        progressDetailField?.stringValue = detail
        cancelButton?.isEnabled = canCancel
        window.standardWindowButton(.closeButton)?.isEnabled = canCancel

        if let bar = progressIndicator {
            if let fraction {
                if bar.isIndeterminate {
                    bar.stopAnimation(nil)
                    bar.isIndeterminate = false
                }
                bar.doubleValue = min(max(fraction, 0), 1)
            } else {
                if !bar.isIndeterminate {
                    bar.isIndeterminate = true
                }
                bar.startAnimation(nil)
            }
        }
    }

    private func setWindowContent(_ view: NSView, size: NSSize, resizable: Bool) {
        if resizable {
            window.styleMask.insert([.closable, .resizable])
        } else {
            window.styleMask.remove([.closable, .resizable])
        }
        window.contentView = view
        window.setContentSize(size)
        window.center()
    }

    private func clearProgressRefs() {
        progressTitleField = nil
        progressDetailField = nil
        progressIndicator = nil
        cancelButton = nil
        window.standardWindowButton(.closeButton)?.isEnabled = true
    }

    // MARK: - Controls

    private func makeAppIconView() -> NSImageView {
        let view = NSImageView()
        view.image = NSApp.applicationIconImage
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func makeLabel(
        _ text: String,
        font: NSFont,
        color: NSColor = .labelColor,
        wrapping: Bool = false
    ) -> NSTextField {
        let field = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeButton(_ title: String, action: Selector, keyEquivalent: String = "") -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        button.keyEquivalent = keyEquivalent
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeReleaseNotesView(markdown: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(ReleaseNotesAttributedRenderer.render(markdown))

        scroll.documentView = textView
        return scroll
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        onCancel?()
    }

    @objc private func installClicked() {
        onInstall?()
    }

    @objc private func openReleasePageClicked() {
        onOpenReleasePage?()
    }
}

/// Renders cleaned GitHub release Markdown into an NSAttributedString using Foundation's native parser.
enum ReleaseNotesAttributedRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var first = true

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if !first { output.append(NSAttributedString(string: "\n")) }
            first = false

            if trimmed.hasPrefix("### ") {
                let text = String(trimmed.dropFirst(4))
                output.append(styledInline(
                    text,
                    baseFont: .systemFont(ofSize: 12, weight: .semibold),
                    color: .labelColor,
                    paragraph: paragraphStyle(before: 8, after: 3)
                ))
            } else if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                output.append(styledInline(
                    text,
                    baseFont: .boldSystemFont(ofSize: 13),
                    color: .labelColor,
                    paragraph: paragraphStyle(before: 10, after: 4)
                ))
            } else if trimmed.hasPrefix("# ") {
                let text = String(trimmed.dropFirst(2))
                output.append(styledInline(
                    text,
                    baseFont: .boldSystemFont(ofSize: 14),
                    color: .labelColor,
                    paragraph: paragraphStyle(before: 10, after: 4)
                ))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let text = String(trimmed.dropFirst(2))
                let style = paragraphStyle(before: 1, after: 3, headIndent: 14)
                let bullet = NSAttributedString(string: "•  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ])
                output.append(bullet)
                output.append(styledInline(
                    text,
                    baseFont: .systemFont(ofSize: 12),
                    color: .labelColor,
                    paragraph: style
                ))
            } else {
                output.append(styledInline(
                    trimmed,
                    baseFont: .systemFont(ofSize: 12),
                    color: .labelColor,
                    paragraph: paragraphStyle(before: 0, after: 5)
                ))
            }
        }
        return output
    }

    private static func styledInline(
        _ markdown: String,
        baseFont: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: markdown, attributes: [
                .font: baseFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let slice = String(parsed[run.range].characters)
            var font = baseFont
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: max(baseFont.pointSize - 0.5, 11), weight: .regular)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let desc = baseFont.fontDescriptor.withSymbolicTraits(baseFont.fontDescriptor.symbolicTraits.union(traits))
                        font = NSFont(descriptor: desc, size: baseFont.pointSize) ?? baseFont
                    }
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if let link = run.link {
                attrs[.link] = link
            }
            result.append(NSAttributedString(string: slice, attributes: attrs))
        }
        return result
    }

    private static func paragraphStyle(before: CGFloat, after: CGFloat, headIndent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = 1.15
        style.headIndent = headIndent
        return style
    }
}
