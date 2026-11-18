import Foundation

/// The concrete way to open a link, decided before anything launches.
public enum LaunchPlan: Equatable, Sendable {
    /// Hand the link to the app, like `open -a`.
    case open(link: URL, app: String, activate: Bool)
    /// Start a new instance with arguments, like `open -n -a <app> --args …`. Chromium and Firefox
    /// forward these to the instance that is already running and exit.
    case arguments(app: String, args: [String], activate: Bool)
    /// Ask Ardia over its control socket to open a tab in a profile.
    case ardia(link: URL, profileID: String, activate: Bool)

    public var app: String {
        switch self {
        case .open(_, let app, _), .arguments(let app, _, _): app
        case .ardia: BrowserKind.ardiaBundleID
        }
    }
}

public enum PlanError: Error, Equatable, CustomStringConvertible {
    case unknownProfile(String, available: [String])
    case containersNeedFirefox(String)
    case containerExtensionMissing(String)

    public var description: String {
        switch self {
        case .unknownProfile(let name, let available):
            "No profile named \"\(name)\". Profiles: \(available.isEmpty ? "none found" : available.joined(separator: ", "))."
        case .containersNeedFirefox(let browser):
            "\(browser) has no containers. Containers work in Firefox and Zen."
        case .containerExtensionMissing(let container):
            "The \(container) container needs the \"Open external links in a container\" extension, which isn't installed."
        }
    }
}

public enum LaunchPlanner {
    public static func plan(link: URL, target: Target, profiles: (BrowserKind) -> BrowserProfiles) throws -> LaunchPlan {
        let kind = BrowserKind.of(target.browser)
        let activate = target.background != true
        lazy var known = profiles(kind) // Read only for a container or a profile.

        var link = link
        if let container = target.container, !container.isEmpty {
            guard case .firefox = kind else { throw PlanError.containersNeedFirefox(target.browser) }
            // Without the extension the browser can't open the link at all, so it would be lost.
            guard known.hasContainerExtension else { throw PlanError.containerExtensionMissing(container) }
            link = containerLink(link, container: container)
        }

        guard let wanted = target.profile, !wanted.isEmpty, kind != .plain else {
            return .open(link: link, app: target.browser, activate: activate)
        }
        guard let profile = known.profile(named: wanted) else {
            throw PlanError.unknownProfile(wanted, available: known.profiles.map(\.name))
        }
        switch kind {
        case .chromium:
            return .arguments(app: target.browser, args: ["--profile-directory=\(profile.id)", link.absoluteString], activate: activate)
        case .firefox:
            return .arguments(app: target.browser, args: ["-P", profile.id, link.absoluteString], activate: activate)
        case .ardia:
            return .ardia(link: link, profileID: profile.id, activate: activate)
        case .plain:
            return .open(link: link, app: target.browser, activate: activate)
        }
    }

    /// The link format of the "Open external links in a container" Firefox extension.
    static func containerLink(_ link: URL, container: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return URL(string: "ext+container:name=\(encode(container))&url=\(encode(link.absoluteString))")!
    }
}
