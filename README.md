# ClashLite

**English** | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Русский](README.ru.md)

A minimal macOS menu bar client for [mihomo](https://github.com/MetaCubeX/mihomo).

## Why

The mihomo core can already host a web dashboard by itself (`external-ui`), and dashboards like [metacubexd](https://github.com/MetaCubeX/metacubexd) already do a great job with proxies, connections, rules, and logs. Yet most clients still build their own dashboard on top, duplicating features and growing in size and complexity along the way. Meanwhile the core is going: "I already have a dashboard, you know?"

ClashLite's idea is simple: **do only what the core can't, and leave the rest to the core and its dashboard.**

- "Client" jobs such as managing the core process, profiles, subscription updates, overrides, and TUN authorization are handled by ClashLite
- "Dashboard" jobs such as viewing connections, logs, rules, and running speed tests are one click away in the core-hosted dashboard
- The most common everyday actions (switching mode, switching proxies, toggling TUN mode) live in the menu bar, so you don't need to open the dashboard

No main window, no Dock icon, just a menu bar icon.

## Features

- **Core-hosted dashboard**: open the mihomo-hosted dashboard in one click with the address and secret filled in automatically, so there's no backend to configure by hand. metacubexd is used by default; switch to another dashboard with `external-ui-url` in your profile. The dashboard can be updated from the menu
- **Profile management**: supports subscription URLs and local YAML files. Subscriptions can update automatically (using the subscription's `profile-update-interval` by default). Local profiles can be edited in the app, and subscription profiles can be viewed
- **Profile validation**: importing, editing, or updating a profile, and saving an override, all run a full validation with the core (`mihomo -t`) first, so a broken profile is never applied
- **Overrides**: "profile overrides" (apply to a single profile) and a "global override" (applies to all profiles), deep-merged as YAML
- **Menu bar shortcuts**: switch proxy mode (Rule / Global / Direct), switch proxies in proxy groups (with latency), unpin, close all connections, restart the core
- **TUN mode**: authorize only once; DNS is automatically switched to fake-ip mode when enabled, and a LAN DNS server is replaced with a public one so queries enter the tunnel
- **Dashboard sync**: changing the mode or switching proxies in the dashboard is synced back to the menu bar and kept across core restarts
- **Launch at login**
- **Multilingual**: English, Simplified Chinese, Traditional Chinese, and Russian, following the system language

## Screenshots

English interface with example profiles.

| Menu bar | Profile management |
| --- | --- |
| <img src="docs/screenshots/en/menu-bar.png" alt="Menu bar" width="220"> | <img src="docs/screenshots/en/profiles.png" alt="Profile management" width="400"> |

<details>
<summary>More screenshots</summary>

### Proxy groups

<img src="docs/screenshots/en/proxy-groups.png" alt="Proxy groups" width="300">

### Add a subscription

<img src="docs/screenshots/en/add-subscription.png" alt="Add a subscription" width="420">

### Import a local profile

<img src="docs/screenshots/en/add-local.png" alt="Import a local profile" width="420">

### Edit a local profile

<img src="docs/screenshots/en/edit-profile.png" alt="Edit a local profile" width="760">

### View a subscription profile

<img src="docs/screenshots/en/view-profile.png" alt="View a subscription profile" width="760">

### Profile override

<img src="docs/screenshots/en/profile-override.png" alt="Profile override" width="760">

### Global override

<img src="docs/screenshots/en/global-override.png" alt="Global override" width="760">

### Runtime config

<img src="docs/screenshots/en/runtime-config.png" alt="Runtime config" width="760">

</details>

## Requirements

- macOS 15 or later
- Apple silicon or Intel Mac (universal binary)

## Installation

1. Download the latest version from [Releases](../../releases) and drag ClashLite into Applications. Each release provides these DMGs:

   | File | Description |
   | --- | --- |
   | `ClashLite-x.y.z-mihomo-vA.B.C-arm64.dmg` | Bundles the mihomo core (latest stable release at build time), for Apple silicon. Recommended |
   | `ClashLite-x.y.z-mihomo-vA.B.C-amd64.dmg` | Bundles the mihomo core, for Intel |
   | `ClashLite-x.y.z.dmg` | No core included; you provide your own |

2. The app is not notarized, so remove the quarantine attribute before opening it for the first time:

   ```sh
   xattr -cr /Applications/ClashLite.app
   ```

   Alternatively, after the first launch is blocked, click "Open Anyway" in System Settings → Privacy & Security.

### Core

Versions with a bundled core copy it to the core folder on first launch; nothing else is needed. An existing core in the core folder is never overwritten, so updating ClashLite won't replace a core you placed yourself. To switch to the core bundled with a newer release, delete `mihomo` from the core folder and reopen ClashLite.

If you're using the version without a core, or want to pick the core version yourself:

1. Download the core for your architecture from [mihomo Releases](https://github.com/MetaCubeX/mihomo/releases) (`mihomo-darwin-arm64-*.gz` for Apple silicon, `mihomo-darwin-amd64-*.gz` for Intel) and extract it
2. In the menu bar, click "More → Open Core Folder", put the extracted file there and **rename it to `mihomo`**
3. Make it executable and remove the quarantine attribute:

   ```sh
   cd ~/Library/Application\ Support/com.oxi.ClashLite/Core
   chmod +x mihomo
   xattr -d com.apple.quarantine mihomo
   ```

4. The core version shows up in the menu bar, and the core starts automatically once you add a profile

To upgrade the core later, just replace this file and click "More → Restart Core". If TUN mode is on, you'll be asked to authorize again after replacing it.

## Usage

### Overrides

An override is a YAML mapping, merged onto the profile in this order:

```
Profile → Profile override → Global override → ClashLite settings (mode, TUN, controller, etc.)
```

Merge rules:

- Mappings are merged recursively key by key; other values are replaced
- For lists, `+key` inserts before the original list and `key+` appends after it

For example, to make custom rules take precedence over the subscription's rules:

```yaml
+rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
```

### TUN mode

Creating a virtual network interface requires root. The first time you enable it, ClashLite shows the system administrator authorization dialog, makes the core file owned by root and sets the setuid bit, after which no further authorization is needed. Replacing the core file drops these permissions, and you'll be asked again.

macOS cannot intercept DNS queries sent to a LAN DNS server through the TUN interface. When TUN is on and the current network service uses a LAN, loopback, or link-local DNS server, ClashLite removes those servers so the queries enter the tunnel; existing public DNS servers are kept, and 223.5.5.5 and 119.29.29.29 are used when none remain. The original settings are restored when TUN is turned off, the core stops, or ClashLite quits. This is controlled by the "Take Over System DNS" menu item and is on by default.

Apps that send DNS queries directly to a hardcoded LAN server are not affected. While TUN is on, split DNS and internal domains resolved only by the LAN DNS may stop working; turn off "Take Over System DNS" in that case.

### File locations

All data lives in `~/Library/Application Support/com.oxi.ClashLite/`:

| Path | Description |
| --- | --- |
| `Core/mihomo` | Core executable |
| `Home/` | Core working directory, with Geo data, rule sets, dashboard, etc. |
| `Home/mihomo.log` | Core log, cleared on every start |
| `Profiles/` | Profiles; the file name is the profile name |
| `Overrides/` | Profile overrides |
| `Override.yaml` | Global override |

### Security

- The controller only listens on `127.0.0.1:9097`, with a secret randomly generated on first launch
- The dashboard path is randomly generated as well
- The final config is passed to the core via an environment variable, so the secret and proxy details never appear in process arguments

## Building from source

Requires Xcode 26 or later (the project uses Swift 6.2 and an Icon Composer icon).

```sh
git clone <repository URL>
cd ClashLite
open ClashLite.xcodeproj
```

The dependency ([Yams](https://github.com/jpsim/Yams)) is fetched automatically by Swift Package Manager.

### Localization

UI strings live in the String Catalog `ClashLite/Localizable.xcstrings`, with English as the source language. To add or change a translation, edit it in Xcode.

### Releasing

Pushing a tag starting with `v` triggers GitHub Actions to build the DMGs and create a Release. Versions with a bundled core download the latest stable mihomo at build time and are packaged separately for arm64 and amd64:

```sh
git tag v1.0.0
git push origin v1.0.0
```

You can also run the workflow manually from the Actions page; build products are uploaded as artifacts.

## Acknowledgements

- [mihomo](https://github.com/MetaCubeX/mihomo)
- [metacubexd](https://github.com/MetaCubeX/metacubexd)
- [Yams](https://github.com/jpsim/Yams)
- ClashBar, [clash-verge-rev](https://github.com/clash-verge-rev/clash-verge-rev): ideas for TUN authorization and DNS handling

## License

[GPL-3.0](LICENSE)
