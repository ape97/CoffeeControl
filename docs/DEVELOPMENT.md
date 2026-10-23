# Development

Everything you need to change, build, install and release Coffee Control yourself.

## Prerequisites

- macOS 26 or later, Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The Xcode project is generated from `project.yml` and not checked in. Run `xcodegen generate` and open
`CoffeeControl.xcodeproj` if you want to work in Xcode; the scripts below generate it themselves.

## Project layout

```
project.yml                 XcodeGen project (version in MARKETING_VERSION)
Config/Signing.xcconfig     ad-hoc signing by default, optional Config/Local.xcconfig
CoffeeControl/
  App/                      app entry, AppModel (state, settings), KeepAwake (modes, assertions, lid), SleepHelper (sudo rule, pmset), SelfTest, StructureTest
  UI/                       MenuView, SettingsPage, DesignKit (shared styles)
  Resources/                Info.plist, asset catalog (app icon)
scripts/                    check, deploy, status, screenshots, release, idle, measure-menu, icon
docs/                       PLATFORM.md (tested macOS/Xcode), images/ (README screenshots)
```

## Scripts

| Script | What it does |
|---|---|
| `./scripts/check.sh` | The gate. Warning-free Release build, invisible snapshots of every page into `build/check/`, self-test, performance test. Ends with `RESULT: GREEN` or `RED`. Changes nothing on the system. |
| `./scripts/deploy.sh` | Runs the check; only if green, installs to `/Applications`, restarts the app and measures idle CPU. |
| `./scripts/status.sh` | Shows the installed version, running state, login item and signature, and compares the system with the last tested one in `docs/PLATFORM.md`. |
| `./scripts/screenshots.sh` | Renders every page with demo data and composes the README images in `docs/images/`: every page in dark mode, the main page in light mode too. Each animation in `scripts/scenes/*.json` (cursor, clicks and captions over the rendered pages, `compose.swift --scene`) becomes `docs/images/<name>.gif`; the app icon is copied to `docs/images/icon.png`. GIFs need `ffmpeg` (`brew install ffmpeg`). |
| `./scripts/release.sh` | Builds the downloadable, ad-hoc signed and stripped `build/release/CoffeeControl-<version>.zip`. |
| `./scripts/idle.sh [seconds]` | Measures the running app's CPU use and memory footprint with the menu closed. |
| `./scripts/measure-menu.sh` | Measures CPU use while the menu is open (start it, then use the menu). |
| `./scripts/icon.sh <sf-symbol> <top-hex> <bottom-hex>` | Generates the app icon in all sizes into the asset catalog (uses `scripts/icon.swift`). |

Typical loop: edit, `./scripts/check.sh`, look at `build/check/*.png`, then `./scripts/deploy.sh` to use it.

## Command-line modes

The app binary (`CoffeeControl.app/Contents/MacOS/CoffeeControl`) understands a few arguments used by the scripts:

- `--snapshot <base>` renders the menu off-screen to `<base>-light.png`, `<base>-dark.png` and `<base>-symbol.png`
  and exits. No window is shown. Combine it with state flags: `--settings` (settings page), `--sleep` (Sleep mode),
  `--off` (Normal mode), `--blocked` (foreign sleep blocks present), `--nohelper` (no sleep rule), `--closed` (lid closed),
  `--battery` (paused on battery), `--error` (setup error shown), `--timer <minutes> --left <minutes>` (running timer,
  `--then-sleep` for Then Sleep), `--times a,b,c` (own durations in minutes), `--no-timer` (timer switched off),
  `--draft <text>` (text typed into the duration field).
- `--demo` (with `--snapshot`) uses invented data, so screenshots never show your own system.
- `--selftest <file.json>` runs the logic tests of the mode machine and writes the result as JSON.
- `--structuretest <file.json>` checks that menu updates stay structurally quiet (otherwise macOS keeps resetting the pointer) and writes the result as JSON.

## Signing

Builds are ad-hoc signed (`Config/Signing.xcconfig`), so no developer account is needed. macOS ties the login item to
the code signature, so with ad-hoc signing you may have to switch **Open at Login** on again after a rebuild. To sign
with your own certificate, create the git-ignored `Config/Local.xcconfig`:

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

## Releasing

1. Raise `MARKETING_VERSION` in `project.yml`.
2. `./scripts/check.sh` must be green; refresh the README images with `./scripts/screenshots.sh` if the UI changed.
3. `./scripts/release.sh` builds the zip. It always signs ad hoc, even with `Local.xcconfig` present, because a personal
   certificate would put the developer's name into the signature, and it strips the binary so no build paths remain.
4. Commit, tag and publish, for example with the GitHub CLI:
   ```sh
   git tag v1.2.0 && git push --tags
   gh release create v1.2.0 build/release/CoffeeControl-1.2.0.zip --title "Coffee Control 1.2.0" --notes "…"
   ```

## After a macOS or Xcode update

Run `./scripts/status.sh`. If the system differs from the last `tested:` line in `docs/PLATFORM.md`, run
`./scripts/check.sh`, fix what broke and append a new `tested:` line. `docs/PLATFORM.md` also lists the system
interfaces most likely to change (`pmset` names and values, IORegistry keys).

## How it works

- Power assertions via `IOPMAssertion` (like `caffeinate -dims`); kernel state is read from `IOPMrootDomain`, idle time from `IOHIDSystem`.
- **Awake** has two layers: the assertions, and `pmset -a disablesleep 1`, which is required for a closed lid. The status
  line shows what the kernel reports (`SleepDisabled`), not what the app assumes. Every 2 s (Awake only, registry reads only)
  it checks whether someone reset `disablesleep` and reverts that.
- **Normal**: no tick, no assertions, nothing changed on the system.
- **Sleep**: foreign assertions are ignored and a foreign `disablesleep 1` is reset to 0. With the lid closed (no external
  monitor) the Mac sleeps immediately (`pmset sleepnow`). With the lid open the app reproduces the sleep timeouts from System
  Settings: idle time against `displaysleep`/`sleep` of the current power source, display off first, sleep at the earliest
  one minute later, and only while foreign assertions exist. On the charger even `sleepnow` does not override
  `PreventSystemSleep` (`caffeinate -s`), so the app ends the `caffeinate` processes holding it before sleeping.
- **Lid and power source** changes arrive as notifications (`kIOPMMessageClamshellStateChange`, `kIOPSNotifyPowerSource`), no polling. On closing, power modes per source are saved and written back exactly on opening; the built-in display is turned off while closed without an external monitor.
- **Sleep rule**: `/etc/sudoers.d/coffeecontrol` (root:wheel 0440) is written to a temp file, validated with `visudo -cf`
  and only then moved into place, so a broken rule can never lock out `sudo`. `pmset` is called as `sudo -n`, and only
  calls from the fixed list in `App/SleepHelper.swift` are executed.
- Quitting restores everything; after a crash the next launch re-aligns. Only what the app set itself is reverted.
- The UI is SwiftUI in a `MenuBarExtra` (window style); the login item uses `SMAppService`.

## Contributing

Keep changes small and focused, run `./scripts/check.sh` before opening a pull request, and describe what you tested.
Settings get a short explanation below them (`SettingNote` in `UI/DesignKit.swift`).
