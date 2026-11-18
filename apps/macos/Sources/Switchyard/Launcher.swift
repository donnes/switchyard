import AppKit
import SwitchyardCore

/// Turns a target into a launch plan and runs it with NSWorkspace, without spawning `open`.
@MainActor
final class Launcher {
    private let profiles = ProfileCache.shared

    /// Calls `done` on the main actor with a problem to show, or nil when the link opened as planned.
    func launch(_ link: URL, target: Target, done: @escaping @MainActor (String?) -> Void) {
        let plan: LaunchPlan
        var problem: String?
        do {
            plan = try LaunchPlanner.plan(link: link, target: target, profiles: profiles.profiles(for:))
        } catch {
            // Still open the link, in the right browser, so a stale profile name never loses it.
            problem = "\(error)"
            plan = .open(link: link, app: target.browser, activate: target.background != true)
        }
        run(plan) { failure in done(failure ?? problem) }
    }

    private func run(_ plan: LaunchPlan, done: @escaping @MainActor (String?) -> Void) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: plan.app) else {
            return done("\(plan.app) isn't installed.")
        }
        let configuration = NSWorkspace.OpenConfiguration()

        switch plan {
        case .open(let link, _, let activate):
            configuration.activates = activate
            NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration) { _, error in
                let message = error.map { "Couldn't open the link in \(plan.app): \($0.localizedDescription)" }
                Task { @MainActor in done(message) }
            }

        case .arguments(_, let args, let activate):
            configuration.activates = activate
            configuration.arguments = args
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                let message = error.map { "Couldn't start \(plan.app): \($0.localizedDescription)" }
                Task { @MainActor in done(message) }
            }

        case .ardia(let link, let profileID, let activate):
            // Ask Launch Services now, while the link's event is being handled: it only brings an app forward
            // for such requests. The same request starts a closed Ardia (without the link, so the socket can
            // place it in the profile) and makes a windowless Ardia open the window the new tab needs.
            let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: plan.app).isEmpty
            if activate || !isRunning {
                configuration.activates = activate
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            }
            Task.detached {
                let failure: ArdiaControl.Failure?
                do {
                    try ArdiaControl.open(link, profileID: profileID, activate: activate, waitForSocket: isRunning ? .zero : .seconds(5))
                    failure = nil
                } catch let error as ArdiaControl.Failure {
                    failure = error
                } catch {
                    failure = ArdiaControl.Failure(description: "\(error)")
                }
                await MainActor.run {
                    guard let failure else { return done(nil) }
                    // Opening it again could add a second tab, in whatever profile Ardia picks. The link stays
                    // in Recent links, where a click copies it.
                    if failure.unconfirmed {
                        return done("\(failure) It may or may not have opened, so Switchyard didn't open it again.")
                    }
                    // Ardia isn't reachable or refused: open it anyway and let Ardia pick the profile.
                    self.run(.open(link: link, app: plan.app, activate: activate)) { second in
                        done(second ?? "\(failure) Opened with Ardia's own routing instead.")
                    }
                }
            }
        }
    }
}

/// Profiles per browser, re-read only when one of the browser's profile files changes.
/// Shared by the launcher and the settings window.
@MainActor
final class ProfileCache {
    static let shared = ProfileCache()
    private var entries: [BrowserKind: (modified: [Date?], profiles: BrowserProfiles)] = [:]

    func profiles(for kind: BrowserKind) -> BrowserProfiles {
        let modified = ProfileDiscovery.sourceFiles(for: kind).map {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
        if let cached = entries[kind], cached.modified == modified { return cached.profiles }
        let fresh = ProfileDiscovery.profiles(for: kind)
        entries[kind] = (modified, fresh)
        return fresh
    }
}
