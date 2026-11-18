# Switchyard

Switchyard is a link router for macOS, with an Omarchy (Linux) app planned. The user makes it the default browser, and it sends each link to the browser, profile or Firefox container that fits the app the link came from and the link itself. The macOS app is a native AppKit menu bar app with a SwiftUI settings window, built with SwiftPM. Finicky is the feature baseline.

## What we never compromise on

1. **Speed and memory.** Switchyard sits in front of every link the user clicks, so it has to be invisible. It idles at about 13 MB, decides where a link goes in about 0.1 ms, and hands it to the browser in 22 to 30 ms. Rules compile once per config load, browser profiles are cached by file modification time, and browsers open through NSWorkspace, never through a shell or `open`. The settings window exists only while it's open. Measure before adding work that runs on every link.
2. **A link is never lost or sent to the wrong place.** If a profile, a container or Ardia's socket isn't available, the link still opens in the right browser without it, and the menu bar icon shows a warning. The one exception is an Ardia request that went out and got no reply: opening the link again could add a second tab in another profile, so Switchyard reports it instead. Decide what a new way to open links does when it fails before writing the case where it works.
3. **The user's setup is theirs.** Switchyard reads browser data and never writes it. It writes `config.json` only from settings, and never over a file it can't load or one that changed on disk since settings read it.

## A note on taste

We like ambitious ideas, simple systems, and software that feels obvious. Don't keep complexity because it already exists, and don't add machinery because it looks architecturally impressive. Find the real constraint, then build the smallest model that makes the correct behavior unsurprising. Measure twice, cut once, and fight scope creep.

These are good defaults, not hard rules. If one fights the task in front of you, say so and get a sign-off before breaking it.

## Glossary

- **you** means the agent reading this file.
- **user** means the person who set Switchyard as their default browser.
- **link** means one URL that reaches Switchyard as a `kAEGetURL` Apple Event.
- **source app** means the app the link came from, identified by bundle id from the event's sender PID.
- **rule** means one entry in `config.json`: source apps, URL patterns and a target. The first enabled rule that fits decides.
- **target** means where a link opens: a browser's bundle id plus an optional profile, container and background flag.
- **fallback** means the target for links no rule catches. Settings call it Everything else.
- **browser family** means how a browser takes a profile from outside: Chromium, Firefox (including Zen), Ardia, or plain.

## Ways to hurt yourself

1. **Opening real links.** A link sent to a running Switchyard opens a tab in the user's browsers, in their profiles. Use Try a link in settings or the core tests. When you need a real launch, put a temporary rule at the top whose target is a bundle id that isn't installed, like `dev.example.not-installed`, so nothing opens.
2. **Writing the live config.** `~/.config/switchyard/config.json` is the config the user's installed Switchyard reads, and a running copy reloads it as soon as it changes. Copy it aside before a test changes it, restore it after, and add test rules instead of editing the user's.
3. **Killing by pattern.** Never `pkill`, `killall` or kill a PID you found by matching a name. The user's own Switchyard runs under the same name and bundle id. Start the dev build with `build/Switchyard.app/Contents/MacOS/Switchyard &`, keep `$!`, and stop only that PID. If the user's copy is already running, ask before starting yours: they share a bundle id, so links and Apple Events can reach either one.
4. **Changing the user's system.** Don't make Switchyard the default browser, register Open at Login, or change a browser's settings, such as Ardia's "Let the ardia command control Ardia". Those are the user's to do. If a test needs one, ask.
5. **Driving Ardia.** Ardia's control socket controls the user's real browser. Send it only `hello` and `apply` with an `open` op, and only for a link the user agreed to open.

## Hit every surface

The most common defect is a change that works on the path you tested and is missing everywhere else. Before calling work done, walk this list and say which entries applied:

- **Settings and the file.** Anything settings can change lives in `config.json`, works when written by hand (ids are optional, and the file reloads live), and is described in `docs/config.md`.
- **Config contract.** `docs/config.md` is the contract with the Omarchy app. Change it in the same change as the format or pattern rules. Add fields; don't rename or remove them.
- **Browser families.** A new target option needs a decision for Chromium, Firefox, Ardia and plain browsers, even if the decision is "not supported", and a fallback that still opens the link.
- **Failure paths.** A missing profile or extension, Ardia closed, without a window, unreachable or silent, and a config that doesn't load. Each one shows in the menu bar icon and in recent links.
- **Try a link.** It explains what the router decides and how the link would open, so routing and launch changes show up there too.
- **Reverse states.** If you add a way in, add the way out and a way to see it.

## Where code lives

- `apps/macos/Sources/SwitchyardCore` is Foundation only, so it tests without AppKit. `Config` is the file format, `URLPattern` the pattern rules, `Router` picks the rule, `Browsers` knows each browser family and reads their profiles and containers, and `LaunchPlan` turns a target into the concrete way to open a link.
- `apps/macos/Sources/Switchyard` is the app. `main.swift` starts a plain `NSApplication` with no SwiftUI lifecycle. `AppDelegate` receives links and keeps recent ones, `ConfigStore` loads, watches and saves the config, `Launcher` runs launch plans through NSWorkspace and caches profiles, `ArdiaControl` speaks Ardia's control socket, `StatusItemController` is the menu bar icon and menu, and `AppCatalog` names apps and lists browsers. `Settings/` is the SwiftUI window: `SettingsView` with Try a link, `RuleEditor` with the shared target fields, and `SettingsWindowController`, which creates and drops the window.
- `apps/macos/Tests` holds the core tests, `Support/Info.plist` the bundle's plist, and `scripts/build-app.sh` assembles the app bundle.
- `assets/` holds the app icon's Icon Composer project, the flat logo and the PNG `scripts/icons` exports. See `assets/README.md`.
- `docs/config.md` is the config format.

## Design

Switchyard follows macOS. It targets macOS 26, which gives system controls Liquid Glass; SwiftPM stamps the binary with the minimum version as its SDK, so lowering it brings back the old look. Use system components (a grouped `Form`, the window toolbar, standard pickers and toggles) and keep glass on controls and navigation, not on content. Settings mirror Ardia's Air Traffic Control page. The menu bar icon is the app icon's fork drawn as a template image.

## Running

- In `apps/macos`, `scripts/build-app.sh` builds `build/Switchyard.app` and registers it with Launch Services. It needs Xcode 26 or newer selected, because `actool` compiles the icon.
- Start it with `build/Switchyard.app/Contents/MacOS/Switchyard &` and keep the PID. Opening the app again (`open build/Switchyard.app`) shows settings.
- Showing settings brings the window forward and takes keyboard focus, so whatever the user is typing lands in it. Ask before opening settings while the user works.
- `/usr/bin/log stream --level info --predicate 'subsystem == "dev.donnes.switchyard"'` shows each link's source, target, rule and timing. Use the full path: zsh has a `log` builtin.
- Stop what you started, by its PID.

## Verifying

- `swift test` in `apps/macos` runs the core tests. Keep the build free of warnings.
- Test behavior that can break: pattern matching, rule order, config decoding, launch planning and profile discovery. Skip tests for views, wiring and copy.
- Extend an existing test before adding one. A bug fix's test must fail before the fix, for the reason the bug describes.
- No sleeps, polling or wall-clock assertions in tests. Profile discovery tests write fixtures to a temporary folder, never the user's browser data.
- After changing the link path, check the log line's timing. After changing startup or settings, check memory with `footprint -p <pid>`: about 13 MB idle, and flat across settings open and close cycles.
- Visual changes get a screenshot of the settings window with `screencapture -l <window id>`, before and after.
- After changing the icon, run `scripts/icons` and `scripts/icons --check`.

## Taste

- Complexity belongs at the boundary. Browser quirks stay in `Browsers` and `LaunchPlan`, Ardia's protocol in `ArdiaControl`; the router and views stay simple.
- Prefer inferred types. No force unwraps or `try!` on user or disk input.
- Default to no comment. Write one for a constraint, an external quirk or an invariant the code can't show, in a line or two.
- A problem message says what happened and what Switchyard did instead, like "Opened with Ardia's own routing instead."

## Pull requests

- Never open a PR unless the person you're working for asks.
- Conventional commit titles in plain language: `feat(macos): open links in Arc spaces`.
- The body states the problem in a sentence or two, then how you fixed it, then how you verified it.
- UI changes need before and after images. Upload PR evidence to GitHub; never commit it.
- One request is one PR.

## Documentation

Most changes need no documentation. Agents can read the code. Add a doc only for a decision or constraint that spans components and that the code can't show, and rewrite it when the decision changes instead of appending to it. The config format is the exception: `docs/config.md` changes with it.
