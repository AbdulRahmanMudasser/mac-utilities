# Phase 03 - Menu Controls Settings

## 1. Phase Purpose

Present device-wide menu-bar speeds, daily usage, collection states, and settings controls backed by the device-counter snapshot. The initial UI has no app-attribution section or placeholder.

## 2. Feature Objective

- **Phase Goal:** Present current device network activity and expose the monitoring and display preferences for the device-only release.
- **User Or System Outcome:** The user can check live rates at a glance, inspect today's device totals, and tell whether collection is complete.
- **In Scope:** One-second menu-bar label, compact usage popover, device rates/totals, Title Case labels, settings, start-at-login, pause/resume, units, reset, and device-counter availability status.
- **Out Of Scope:** New measurement sources, packet content display, historical charts, exports, and cloud features.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow Log](./execution-workflow.md)
- **Product Source:** [Mac Utilities PRD](../mac-utilities-prd.md)
- **Prerequisites (Blocked By):** Phase 01 device snapshots must be available. Phase 02 is deferred and is not required.
- **Downstream Tasks (Unlocks):** Phase 04.
- **Target Git Commit Prefix:** feat(desktop-scope): ...
- **Project Profile(s):** Native macOS desktop application; SwiftUI/AppKit menu-bar and settings surfaces.
- **Applicable Development Standards:** Codex fallback baseline `check-implementation/references/common-baseline.md`; no repository-specific standards or more-specific native desktop baseline were found.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Sections 3, 6, 7, 9, 10, 11, 15, and 16.
- **Related Build Plan Section:** Not applicable; no build plan is maintained in this repository.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** Not applicable.
- **Database/Index Changes:** None. The existing `UsageMonitor` owns device totals and local preferences.
- **Feature Flags / Config Switches:** Persist display units and start-at-login locally; show actual device-counter availability separately from the user's requested pause state.
- **Seed / Fixture Requirements:** Unit tests use synthetic interface-counter snapshots for direction, counter reset, interface changes, local-day boundaries, and persisted state.
- **Required Reusable Utilities:**
  - Extend the existing `UsageMonitor` and its formatting methods; do not add a second view model, preferences store, or login-item controller for behavior already owned there.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** Not applicable; all data is local to the app and its authorized monitoring component.
- **Request Schema:** Not applicable; no network service request is introduced.
- **Response Schema:** Not applicable; no network service response is introduced.
- **Local Contract:** `UsageMonitor` exposes device rates/totals, unit preferences, pause/reset/login-item state, and collection completeness. The UI has no app rows, attribution placeholder, or flow-unattributed total in this release.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** The menu-bar item shows compact live rates as `↓ <download rate> / ↑ <upload rate> <selected unit>` with no app icon and one shared unit suffix. Clicking it opens the compact usage view. The popover's `Settings` control (without an ellipsis) selects Settings in the shared utility window and foregrounds that same window; see Phase 06 for ownership, resizing and activation. All app-owned controls in the popover, Settings, unit choices, and confirmation sheet show a pointing-hand cursor on hover. The popover starts with Connection Health / Check, followed by Current Speed and Today’s Usage; its footer has Settings, Pause/Resume, Reset and a Quit power icon with tooltip/accessibility label. Settings expose all requested controls.
- **System Behavior Change:** Closing the popover does not stop device collection. Reset clears observed current-day totals and baselines. Settings Monitoring contains the collection switch; a separate Readiness section displays the Mac's autoupdating time zone and current monitoring status. Partial badges and historical pause/incomplete messages are removed from both surfaces; completeness metadata remains internal.
- **Error States To Support:** Device counters unavailable, monitoring paused, incomplete day, stale rate sample, no traffic, failed reset, and start-at-login configuration failure.
- **Accessibility / Platform Constraints:** Use native menu-bar and settings conventions. All visible labels and controls use Title Case. Format speed as Mbps or MB/s and data as MB/GB or MiB/GiB according to preferences; show the selected speed unit once after both menu-bar rates.

## 8. Acceptance Criteria

- Menu-bar download/upload rates refresh about once per second while monitoring is active, independently of popover visibility.
- The menu-bar item displays `↓ <download rate> / ↑ <upload rate> <selected unit>`, updates about once per second, and contains no app icon.
- The popover shows device-wide current rates and today's device download/upload/combined totals.
- Current Speed uses a single compact neutral row with inline Download and Upload labels and semibold monospaced rate values, separated by a thin vertical divider. There are no speed icons, direction badges, colored cards, or gradients. Labels remain readable and rates scale down when necessary.
- App identity uses a flat matte white utility mark on a charcoal rounded-square tile, without a glossy rim, metallic bevel, or colored detail. All ten macOS asset-catalog slots contain grayscale PNGs with transparency. Branding accents are black in light appearance and white in dark appearance. Settings About loads the compiled bundle icon and displays the icon/name on the left and bundle version/build on the right in one compact row, without the Network Activity descriptor. Menu-bar and speed-row icon exclusions still apply.
- All app-owned action buttons, switches, unit selectors, unit-choice buttons, and reset-confirmation buttons show a pointing-hand cursor. Reusable SwiftUI controls and a shared continuous-hover cursor handler cover both Settings and the popover; system window chrome retains macOS behavior.
- The popover contains no per-app section or deferred-attribution placeholder; device totals remain clearly device-wide.
- Readiness distinguishes current active, paused, and unavailable monitoring. No Partial badge or historical pause/incomplete text is rendered.
- Settings support start-at-login, pause/resume, Mbps/MB/s, MB/GB or MiB/GiB, and reset today's counters; status reflects actual device-counter availability. The popover's `Settings` control has no trailing ellipsis, selects Settings in the shared utility window and brings that same window forward, including while the app runs with accessory activation policy. The power-icon Quit control gracefully terminates the app. Settings has no Privacy section; Reset Today's Counters is right-aligned below the totals card within Today's Usage.
- All user-visible section, metric, status, and control labels use Title Case.

## 9. Implementation Steps (Component Audit)

### A. Project And Data Layer

- [MODIFY] MacUtilities/Monitoring/UsageMonitor.swift:
  - **Target Anchor:** Existing `formattedDownloadRate`, `formattedUploadRate`, `formattedDownloadedToday`, `formattedUploadedToday`, and `formattedCombinedToday` values.
  - [x] Keep formatting shared by the menu-bar label, popover, and Settings; add focused conversions only where current formatting is not correct.
- [MODIFY] `Mac UtilitiesTests/UsageMonitorTests.swift`:
  - **Target Anchor:** Existing `UsageMonitorTests` target and shared `UsageMonitor` formatting/state helpers.
  - [x] Cover unit conversion, rate samples, interface deltas/resets, local-day boundaries, and persisted-state round trips.

### B. Monitoring Layer

- [MODIFY] MacUtilities/Monitoring/UsageMonitor.swift:
  - **Target Anchor:** Existing `setPaused(_:)`, `resetToday()`, `setLoginItemEnabled(_:)`, and ServiceManagement status handling.
  - [x] Implement pause/resume and reset behavior for device totals and interface baselines; both interrupt completeness and rebaseline rates.
  - [x] Keep device-counter availability separate from the user's requested pause state.

### C. Client / UI Layer

- [MODIFY] MacUtilities/Mac_UtilitiesApp.swift:
- **Target Anchor:** Existing live `MenuBarExtra` label and `SettingsView`; shared window routing now belongs to Phase 06.
  - [x] Implement one-second rate refresh, accessible status text, persisted unit preferences, and visible login-item failure messages.
  - [x] Remove the app icon from the menu-bar item and show download/upload rates with a slash separator and one shared selected-unit suffix.
  - [x] Populate all ten AppIcon slots, configure monochrome light/dark accents, and display bundle-based identity/version in Settings About.
- [MODIFY] MacUtilities/ContentView.swift:
  - **Target Anchor:** Existing device rate cards, daily totals, and menu footer.
  - [x] Keep observed rates/totals visible without Partial or historical messages; place current status and local time zone in Settings Readiness.
  - [x] Do not render an app-attribution section or deferred-attribution placeholder in this release.
  - [x] Keep all visible labels in Title Case and avoid presenting unavailable values as zero.
  - [x] Label the popover control `Settings` without an ellipsis.
  - [x] Use a uniquely identified SwiftUI `Window` scene and `openWindow(id:)` for the popover Settings control; request app activation so an accessory app foregrounds the window reliably.
  - [x] Apply the shared hand-pointer modifier to all app controls, use reusable switch and unit-choice controls, and provide explicit Quit. Keep the native menu-bar item free of hover event handlers so opening the popover remains reliable.
  - [x] Interactively open Settings, cover it with another app, then use the popover control to verify the existing Settings window comes to the front.

### D. Tests And Configuration

- [MODIFY] `Mac UtilitiesTests/UsageMonitorTests.swift`:
  - **Target Anchor:** Existing macOS test target.
  - [x] Verify rate/data unit conversions and core counter persistence/status behavior with the unit suite.
  - [x] Manually verify pause/resume, reset, unit selection, and Start At Login behavior in the running app; inspect the Settings and paused-state screens.
  - [x] Manually verify the Settings label has no ellipsis and the pointing-hand cursor on all app controls, including switches, unit selections, options, and confirmation buttons. Verify graceful Quit from the menu-bar popover.

## 10. Risks And Rollback Notes

- **Implementation Risks:** The UI can imply false precision if device totals are presented as app-level values or an omitted feature is represented as zero.
- **Operational Risks:** A stale snapshot or unavailable counter source must not appear as current active monitoring; login and monitoring preferences can fail independently.
- **Rollback Approach:** Preserve device totals and show paused/unavailable status if sampling fails; do not restore a placeholder or fabricate app values.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO`.
- **Targeted Tests:** Rate/data formatting, rate interval validation, interface deltas/resets, local-day keys, and persisted-state cases in `Mac UtilitiesTests/UsageMonitorTests.swift`.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Compact menu-bar rates | Observe the menu bar in Mbps, then change Speed Display to MB/s | No app icon appears; download/upload rates use a slash separator and show the selected unit once | Visual captures showed `↓ 0.0 / ↑ 0.0 Mbps` and `↓ 0.1 / ↑ 0.0 MB/s`; Settings change applied live and was restored to Mbps. |
| Active traffic | Generate inbound traffic and leave the popover closed | Menu-bar rates render and collection continues independently of popover visibility | Popover and Settings visually inspected; persisted sample time and device totals advanced over a six-second closed-popover interval |
| Attribution scope | Open the popover and Settings | No app-attribution section or deferral placeholder appears; device totals are identified as device-wide | Popover and Settings accessibility trees and visual inspection |
| Settings activation | Open Settings from the popover, cover it with another app, then select Settings again | The `Settings` control has no ellipsis; an existing Settings window is ordered to the front | Covered the Settings window with ChatGPT, selected Settings from the popover, then confirmed Mac Utilities was frontmost and its Settings window remained open. |
| Cursor and Quit | Hover app controls in the popover, Settings, unit choices, and reset confirmation | All app-owned controls show the hand cursor; moving to plain text restores the arrow | Cursor captures confirmed Settings, Pause, Resume, Reset, Quit, both switches, both selectors, unit choices, Settings reset, Cancel, and confirmation reset. Quit behavior was previously verified and the action remains unchanged. |
| Paused/unavailable | Pause collection, then resume | Readiness shows current paused/active status; completeness stays internal | Monitoring bindings and counter tests retain pause/resume behavior; historical explanations are removed from the view source |
| Preferences/reset | Change units, exercise monitoring, open reset confirmation | Preferences apply and switches retain accessible on/off values; reset requires explicit confirmation in the popover | Both speed and data units changed and restored to Mbps and MB/GB. Monitoring was paused and resumed. Reset confirmation was opened and canceled without clearing real counters; both buttons displayed hand cursors. |

### C. Evidence To Capture

- Test output for formatting and status behavior, when a test action is available.
- Inspect current status in Readiness, Title Case labels, and absence of attribution placeholders, Partial badges, and historical pause messages. UI captures remain outside the repository.
- Verify compact menu-bar rates, live popover rates and observed totals, the Settings label without dots, and Readiness as a separate Settings section. Reset confirmation describes restarting observed totals without mentioning Partial.
- A target-Mac observation confirmed that sample timestamps and counters advance while the popover is closed.

## 12. Execution Notes

- **Icon Format Verification:** The primary app icon is `MacUtilities/UtilityIcon.icon`, compiled with the UtilityIcon asset name. Its white vector utility mark uses a solid charcoal fill; specular, blur, refraction, translucency, and shadow effects are disabled. Legacy AppIcon PNGs remain available as source fallback assets. Build 2 was installed as a clean bundle and passed strict signature verification. Finder inspection confirmed the new single-tile mark replaces the older inset icon. macOS may still render its own outer tile treatment.

- **Status:** Completed
- **Started At:** 2026-10-13
- **Completed At:** 2026-10-13.
- **Blockers Encountered:** None for Phase 03.
- **Notes:** All thirteen counter tests passed; the signed arm64 build and strict signature verification succeeded. Visual inspection and the Settings accessibility tree confirmed separate Monitoring and Readiness sections, Asia/Karachi (GMT+5), current Device Monitoring Active status, and no historical pause/incomplete messages. The latest signed rebuild and visual capture confirmed an icon-free single-line speed row with inline Download/Upload labels, live rate values, and a thin divider. The popover displayed observed totals without Partial or historical explanations. Internal completeness metadata and counters remain preserved. Reusable controls retain hand cursors. Historical execution entries retain their original evidence.
