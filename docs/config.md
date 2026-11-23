# Config format

Every Switchyard app reads the same file: `~/.config/switchyard/config.json`. The macOS settings window writes it, and you can edit it by hand. A running app reloads it as soon as it changes.

```json
{
  "fallback": { "browser": "app.zen-browser.zen" },
  "rules": [
    {
      "name": "T3 Code",
      "from": ["com.t3tools.t3code"],
      "open": { "browser": "com.ardia.browser", "profile": "Personal" }
    },
    {
      "name": "Slack",
      "from": ["com.tinyspeck.slackmacgap"],
      "open": { "browser": "app.zen-browser.zen", "container": "Work" }
    },
    {
      "name": "Work links from anywhere",
      "match": ["linear.app/acme/*", "*://app.slack.com/client/T0ACME000/*"],
      "open": { "browser": "app.zen-browser.zen", "container": "Work" }
    }
  ]
}
```

## Rules

Rules are checked from the top. The first enabled rule that fits a link decides where it opens. If none fits, `fallback` decides.

| Field | Meaning |
|---|---|
| `id` | Stable id. Hand-written rules can leave it out and get `r-<position>`, counting from 1. If another rule already uses that id, it gets `r-<position>-2`, then `-3`, and so on. |
| `name` | Optional label. |
| `enabled` | `false` skips the rule. Defaults to `true`. |
| `from` | App ids the link must come from. On macOS these are bundle ids. Empty or missing means any app. |
| `match` | URL patterns. The link must fit at least one. Empty or missing means any link. |
| `open` | The target, see below. |

A rule fits when both `from` and `match` fit.

A link from a command-line tool, like `gh` or a script, comes from the app the tool runs in, like Terminal or a code editor. Switchyard finds that app by climbing the tool's parent processes. Tools that hand the link to `open` or `osascript` are traced only if those are still running when the link arrives, and they often quit first. Then only rules without `from` fit, and recent links show "Command-line tool".

## URL patterns

Matching ignores case. A pattern is a host with an optional path, and `*` matches anything, including nothing.

| Pattern | Matches |
|---|---|
| `cloudflare.com` | `cloudflare.com` and any subdomain, like `dash.cloudflare.com`, on any path. |
| `*.cloudflare.com` | The same. A host always covers its subdomains. |
| `github.com/acme` | `github.com/acme` and everything under it, like `github.com/acme/repo?tab=code`. Not `github.com/acmecorp`. |
| `github.com/acme/*` | The same. A trailing `/*` adds nothing. |
| `play.google.com/console/*/developers/42` | `*` works anywhere in the host or path. |
| `*://github.com/acme` | The same as without the prefix. Any other scheme, like `http://`, must match the link's. |
| `regex:^https://github\.com/acme/` | A regular expression on the full link. |

## Targets

| Field | Meaning |
|---|---|
| `browser` | The browser's app id. On macOS this is its bundle id. |
| `profile` | Profile name, or the browser's own profile id. |
| `container` | A Firefox container name. Firefox-family browsers only. |
| `background` | `true` opens the link without bringing the browser forward. |

How each browser family gets the profile:

| Family | Browsers | How |
|---|---|---|
| Chromium | Chrome, Brave, Edge, Vivaldi, Chromium, Helium | Starts the app with `--profile-directory=<dir>`. The directory comes from the browser's `Local State`. |
| Firefox | Firefox, Zen | Starts the app with `-P <name>`, using names from `profiles.ini`. A container becomes an `ext+container:name=…&url=…` link, which needs the [Open external links in a container](https://addons.mozilla.org/firefox/addon/open-url-in-container/) extension in the browser's default profile. Without it, the link opens without the container. |
| Ardia | Ardia | Sends `apply` with an `open` op to Ardia's control socket. Profile names come from Ardia's `session.json`. Needs "Let the ardia command control Ardia" on in Ardia's settings. A closed Ardia is started first, and Switchyard waits up to 5 s for its socket. |
| Other | Safari and the rest | The link opens in the app. `profile` is ignored. |

If a profile, container or Ardia's socket isn't available, the link still opens in the right browser without it, and the menu bar icon shows a warning.

One case doesn't open the link again: Switchyard sent the whole request to Ardia and got no reply. It may already have opened the tab, and a second open could put the link in another profile. The menu bar icon shows a warning, and the link is in the menu's recent links, where a click copies it.
