# Platform state

The macOS/Xcode version Coffee Control was last fully tested against (`scripts/check.sh` green, deployed).
`scripts/status.sh` compares the last `tested:` line with the running system.
Append new lines at the bottom and keep the format exactly (the "Platform now" value from `status.sh` + ` date=YYYY-MM-DD`).

## Dependencies on the system (an update can break these)
- **MenuBarExtra (.window)** and window notifications used to detect the menu closing (`App/AppModel.swift`).
- **SMAppService** (login item) – `scripts/status.sh` checks it via `sfltool dumpbtm`.
- **Private AppKit methods** used by the performance test (`App/StructureTest.swift`): `_updateStructuralRegionsOnNextDisplayCycle`,
  `_setTrackingAreasDirty:` – test only, not the app.
- **`pmset -a disablesleep 0|1`** (kernel sleep off, even with the lid closed) and **`pmset -c|-b powermode 0|1|2`**
  (energy mode per power source; older macOS called it `lowpowermode`) – `App/SleepHelper.swift`. If Apple changes names or
  values, the sudo rule stops working: the status line then shows "Lid open only"; check `pmset -g custom`.
- **Sudo rule** `/etc/sudoers.d/coffeecontrol` (macOS reads `sudoers.d` via `#includedir`), validated with `visudo -cf`.
- **IORegistry `IOPMrootDomain`**: `SleepDisabled`, `AppleClamshellState` (read) and the notification
  `kIOPMMessageClamshellStateChange` = `0xE0034100` (lid close/open, `LidMonitor` in `App/KeepAwake.swift`).
- **IOPMAssertion** (PreventUserIdleSystemSleep, PreventSystemSleep, PreventUserIdleDisplaySleep).
- **Signing**: builds are ad-hoc signed by default. If you sign with your own certificate via `Config/Local.xcconfig`, it expires; `scripts/status.sh` shows when, then renew it in Xcode.
- **GitHub releases API** (`App/UpdateCheck.swift`), only while Check for Updates is on: `GET api.github.com/repos/ape97/CoffeeControl/releases/latest`,
  reads `tag_name` and `html_url`, ignores drafts and pre-releases. If GitHub changes this, only the update notice stops working.

tested: macOS=27.0.1 (26A434) Xcode=27.0 SDK=27.0 date=2026-10-18
