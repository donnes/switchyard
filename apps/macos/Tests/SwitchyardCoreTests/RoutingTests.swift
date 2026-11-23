import Foundation
import Testing
@testable import SwitchyardCore

private func url(_ text: String) -> URL { URL(string: text)! }

@Test(arguments: [
    // A host covers its subdomains, with or without `*.`.
    ("cloudflare.com", "https://cloudflare.com/x", true),
    ("cloudflare.com", "https://dash.cloudflare.com/x", true),
    ("cloudflare.com", "https://notcloudflare.com/", false),
    ("*.cloudflare.com", "https://cloudflare.com/", true),
    ("*.cloudflare.com/*", "https://dash.cloudflare.com/a/b", true),
    ("oidc.*.amazonaws.com", "https://oidc.us-east-2.amazonaws.com/authorize?client_id=x", true),
    // A path covers itself and everything below it, with or without `/*`.
    ("github.com/acme", "https://github.com/acme", true),
    ("github.com/acme", "https://github.com/acme/repo/pulls", true),
    ("github.com/acme", "https://github.com/acme?tab=repositories", true),
    ("github.com/acme/*", "https://github.com/acme", true),
    ("github.com/acme", "https://github.com/acmecorp", false),
    ("github.com/acme", "https://github.com/", false),
    ("app.slack.com/client/T0ACME000", "https://app.slack.com/client/T0ACME000/C1", true),
    ("app.slack.com/client/T0ACME000", "https://app.slack.com/client/T0OTHER00/C1", false),
    ("play.google.com/console/*/developers/42", "https://play.google.com/console/u/0/developers/42/app", true),
    ("linear.app/acme/*", "https://Linear.app/acme/issue/ACME-1", true),
    // A scheme prefix still works: `*://` is ignored, any other must match.
    ("*://app.slack.com/client/T0ACME000/*", "https://app.slack.com/client/T0ACME000/C1", true),
    ("http://example.com", "https://example.com/", false),
    ("regex:^https://github\\.com/[^/]+/switchyard", "https://github.com/me/switchyard/pulls", true),
])
func patternMatching(pattern: String, link: String, expected: Bool) throws {
    #expect(try URLPattern(pattern).matches(url(link)) == expected)
}

@Test func firstEnabledRuleThatFitsBothAppAndLinkWins() throws {
    let ardia = Target(browser: "com.ardia.browser", profile: "Personal")
    let zen = Target(browser: "app.zen-browser.zen", container: "Work")
    let config = Config(fallback: Target(browser: "com.apple.Safari"), rules: [
        Rule(id: "off", enabled: false, from: ["com.t3tools.t3code"], open: zen),
        Rule(id: "t3-github", from: ["com.t3tools.t3code"], match: ["github.com"], open: zen),
        Rule(id: "t3", from: ["com.t3tools.t3code"], open: ardia),
        Rule(id: "slack", from: ["com.tinyspeck.slackmacgap"], open: zen),
    ])
    let router = try Router(config: config)

    #expect(router.decide(url: url("https://github.com/x"), from: "com.t3tools.t3code").ruleID == "t3-github")
    #expect(router.decide(url: url("https://example.com"), from: "com.t3tools.t3code") == Decision(target: ardia, ruleID: "t3"))
    #expect(router.decide(url: url("https://example.com"), from: "com.tinyspeck.slackmacgap").target == zen)
    // Unknown sender: rules with `from` never fit, so the fallback decides.
    #expect(router.decide(url: url("https://example.com"), from: nil).ruleID == nil)
}

@Test func rulesWithoutIDsKeepTheirIDsAcrossReloads() throws {
    // The last rule carries an id an earlier settings save wrote, which the new first rule's position would reuse.
    let file = Data(#"{"fallback":{"browser":"a"},"rules":[{"open":{"browser":"b"}},{"id":"mine","open":{"browser":"c"}},{"id":"r-1","open":{"browser":"d"}}]}"#.utf8)
    let first = try JSONDecoder().decode(Config.self, from: file)
    let second = try JSONDecoder().decode(Config.self, from: file)
    #expect(first == second)
    #expect(first.rules.map(\.id) == ["r-1-2", "mine", "r-1"])
}

@Test func plansUseEachBrowsersProfileMechanism() throws {
    let link = url("https://example.com/a?b=1&c=2")
    let profiles: (BrowserKind) -> BrowserProfiles = { kind in
        switch kind {
        case .ardia: BrowserProfiles(profiles: [.init(id: "default", name: "Personal"), .init(id: "p-1e", name: "Work")])
        case .chromium: BrowserProfiles(profiles: [.init(id: "Profile 2", name: "Work")])
        case .firefox: BrowserProfiles(profiles: [.init(id: "Default (release)", name: "Default (release)")], hasContainerExtension: true)
        case .plain: BrowserProfiles()
        }
    }

    #expect(try LaunchPlanner.plan(link: link, target: Target(browser: "com.ardia.browser", profile: "work"), profiles: profiles)
        == .ardia(link: link, profileID: "p-1e", activate: true))
    #expect(try LaunchPlanner.plan(link: link, target: Target(browser: "com.google.Chrome", profile: "Work", background: true), profiles: profiles)
        == .arguments(app: "com.google.Chrome", args: ["--profile-directory=Profile 2", link.absoluteString], activate: false))
    #expect(try LaunchPlanner.plan(link: link, target: Target(browser: "app.zen-browser.zen", container: "Work"), profiles: profiles)
        == .open(link: url("ext+container:name=Work&url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1%26c%3D2"), app: "app.zen-browser.zen", activate: true))
    #expect(throws: PlanError.unknownProfile("Nope", available: ["Personal", "Work"])) {
        try LaunchPlanner.plan(link: link, target: Target(browser: "com.ardia.browser", profile: "Nope"), profiles: profiles)
    }
}

@Test func containerWithoutTheExtensionIsAProblemNotALostLink() {
    // Zen can't open an ext+container: link without the extension, so the launcher must open the plain link instead.
    #expect(throws: PlanError.containerExtensionMissing("Work")) {
        try LaunchPlanner.plan(
            link: url("https://example.com"),
            target: Target(browser: "app.zen-browser.zen", container: "Work"),
            profiles: { _ in BrowserProfiles(containers: ["Work"]) }
        )
    }
}
