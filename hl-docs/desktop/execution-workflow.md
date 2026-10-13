# Desktop Execution Workflow

## 1. Document Purpose

This document is the delivery source of truth for the Desktop layer. It tracks implementation order, execution status, dependencies, blockers, and completion evidence for desktop-specific work.

Use this file for:
- sequencing phases
- tracking active and upcoming work
- recording blockers
- linking detailed phase plans
- confirming readiness and completion

Do not use this file for:
- product requirements definition
- architecture rationale beyond brief references
- code-level implementation instructions
- deployment runbooks

## 2. Linked Source Documents

* **Product Source:** [Mac Utilities PRD](../mac-utilities-prd.md)

## 3. Platform Baseline

* **Platform Name:** Desktop
* **Primary Runtime:** SwiftUI with AppKit integration; local device interface counters; ad-hoc signed personal build
* **Target Environments:** Local development and personal use on the target MacBook only
* **Deployment Target:** `~/Applications/Mac Utilities.app` on the target MacBook; no public distribution target
* **Branch Strategy:** Feature branches from `master`, reviewed through lowercase conventional commits and a pull request before merging into `master`.
* **Required Verification Commands:**
  - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-install CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build`
  - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-install CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
  - `codesign --verify --deep --strict "$HOME/Applications/Mac Utilities.app"`
* **Release Gates:**
  - Verify live device rates, current-day totals, restart persistence, local-midnight rollover, collection-state messaging, and normal network connectivity on the target MacBook; local personal use uses ad-hoc signing.
  - Keep per-app usage explicitly deferred until a supported macOS report handoff and app-identity path are proven.

## 4. Status Definitions

- **Planned:** Identified but not ready to start.
- **Ready:** Fully scoped and unblocked.
- **In Progress:** Actively being implemented.
- **Blocked:** Cannot proceed due to a dependency or unresolved issue.
- **Completed:** Implemented and verified.
- **Cancelled:** Intentionally dropped from scope.

## 5. Platform Definition Of Done

Every completed phase must satisfy all of the following:

1. Scope matches the linked phase document.
2. Build, compile, or bundle succeeds for the target platform.
3. Required tests, lint checks, and type checks pass.
4. Functional verification has been performed and recorded.
5. Any required docs, configs, or environment changes are updated.
6. Evidence is logged in the linked phase file.

## 6. Current Active Phase

* **Current Phase:** None - All Defined Phases Complete
* **Status:** Completed
* **Owner:** Product Developer
* **Linked Phase Doc:** [phase-03-menu-controls-settings.md](./phase-03-menu-controls-settings.md)
* **Immediate Goal:** None. All approved desktop phases are complete and verified on the target MacBook.
* **Current Blockers:** None for the approved device-wide monitoring scope. Per-app attribution remains deferred as a future scope decision.

## 7. Ready Queue

None. All defined phases are Completed. App-level attribution remains out of scope until a low-impact, supported handoff is proven.

## 8. Phase Register

| Phase | Name | Status | Priority | Owner | Depends On | Linked File | Target Window |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 00 | Root Project Foundation | Completed | High | TBD | None | [phase-00-project-layout-foundation.md](./phase-00-project-layout-foundation.md) | Completed 2026-10-13 |
| 01 | Device Usage Counters | Completed | High | Product Developer | Phase 00 | [phase-01-device-usage-counters.md](./phase-01-device-usage-counters.md) | Completed 2026-10-13 |
| 02 | Flow Attribution Feasibility Decision | Completed | Deferred | Product Developer | Apple API feasibility review | [phase-02-flow-app-attribution.md](./phase-02-flow-app-attribution.md) | Decision 2026-10-13 |
| 03 | Menu Controls Settings | Completed | High | Product Developer | Phases 00 and 01; Phase 02 is not required | [phase-03-menu-controls-settings.md](./phase-03-menu-controls-settings.md) | Updated And Completed 2026-10-13 |
| 04 | Target Install Verification | Completed | High | Product Developer | Phases 00, 01, and 03 | [phase-04-target-install-verification.md](./phase-04-target-install-verification.md) | Completed 2026-10-13 |

## 9. Blockers And Risks

### Active Blockers

- None for the approved device-wide monitoring scope.

### Execution Risks

- Interface membership changes, counter resets, sleep, pause intervals, and time-zone changes can make totals incomplete.
- Multiple active physical or virtual interfaces may have platform-specific coverage or duplicate-accounting behavior that needs target-Mac verification.
- App attribution remains deferred until both report handoff and app-identity resolution can be proven with documented macOS-supported behavior.
- Ad-hoc signing supports this local personal install only; public distribution would require a separately scoped signing and notarization plan.

## 10. Decision Log

| Date | Decision | Reason | Impact |
| :--- | :--- | :--- | :--- |
| 2026-10-13 | Ship the first release with device-wide counters and defer per-app ranking; do not use a proxy, best-effort `nettop` estimates, or in-path payload sampling. | Live per-app rates require traffic-path sampling, which was not proven low-impact on the target MacBook. | Network Extension and app-group dependencies are removed from the first-release scope; Phase 02 records the completed feasibility decision and does not block Phases 03–04. |
| 2026-10-13 | Use a project-specific bundle identifier and ad-hoc signing for the local personal install. | The Xcode scaffold identifier was a placeholder, and no Apple signing identity is configured on the target MacBook. | The app is uniquely identified, runs from the user Applications folder, and supports Start At Login without Apple account credentials; distribution signing remains out of scope. |
| 2026-10-13 | Use a singleton identified `Window` scene and `openWindow(id:)` for Settings, then request app activation. | The app runs with accessory activation policy, and `SettingsLink` did not reliably foreground an already-open Settings window in the reported interaction. | The scene action explicitly orders an existing Settings window to the front and the app requests activation; interactive verification remains pending. |


## 11. Execution Log

### 2026-10-13 - Phase 00 / Root Project Foundation
- **Status Change:** Planned -> Completed
- **Summary:** Confirmed the app source and Xcode project stay at repository root, completed Xcode license/first-launch setup, built and launched the app, and observed live rates in the menu bar.
- **Evidence:** The root-level arm64 Xcode build succeeded; a screen capture showed changing download/upload rates in the menu bar. At the time, signing and Network Extension activation were tracked in Phase 04; the later product decision below removed the filter from first-release scope.

### 2026-10-13 - Phases 01 And 03 / Device Monitor And Controls
- **Status Change:** Planned -> In Progress
- **Summary:** Added device-interface sampling, local daily persistence, rate/data unit preferences, pause/resume, reset, start-at-login, and explicit app-attribution setup messaging.
- **Evidence:** The root-level arm64 Xcode build succeeded; the running app updated live menu-bar rates and wrote direction-specific daily counters and interface baselines to local Application Support. App attribution remains unavailable pending the Phase 02 product/architecture decision.

### 2026-10-13 - Phases 02 And 03 / App Attribution Decision
- **Status Change:** In Progress -> Blocked
- **Summary:** SDK and Apple documentation review found no supported path for the sandboxed filter data provider to hand report totals to durable host-app storage. The app-ranking UI is therefore explicitly unavailable pending an approved product tradeoff.
- **Evidence:** Local macOS SDK headers and Apple's Network Extension sandbox and deployment documentation; options are recorded in Phase 02.

### 2026-10-13 - Phase 01 / Counter Persistence Check
- **Status Change:** In Progress -> In Progress
- **Summary:** Added a persisted local time-zone identifier and incomplete-state handling when the time zone changes without changing the local-day key. Kept the app project at repository root and moved the phase workflow to `hl/docs/desktop/` as specified.
- **Evidence:** The root-level arm64 build succeeded. Restarting the rebuilt app preserved and advanced the current-day counters and wrote schema version 2 with the local time-zone identifier. `xcodebuild test` could not run because the `Mac Utilities` scheme has no configured test action. At that time, app-group migration and app attribution were open; the later product decision below removes the app-group dependency and defers attribution.

### 2026-10-13 - Product Scope / Device-Only First Release
- **Status Change:** Phase 02 remains Blocked/Deferred; Phase 03 becomes In Progress; Phase 04 remains Planned.
- **Summary:** Product decision accepted: keep public device counters and normal traffic behavior; defer app-level totals and ranking until a supported macOS flow-report handoff is demonstrated. The first release no longer depends on a Network Extension, app group, proxy, or `nettop` process estimates.
- **Evidence:** Product owner selected the recommended architecture. PRD and phase plans updated to reflect the device-only release scope.

### 2026-10-13 - Phases 01 And 03 / Device-Only Build Check
- **Status Change:** In Progress -> In Progress
- **Summary:** Updated the popover and Settings to label per-app usage as deferred, switched live-rate timing to monotonic system uptime, reset the rate baseline after counter-read errors and manual resets, rebuilt the device-only app, and launched the fresh arm64 build. The status now says Monitoring Unavailable when interface counters cannot be read.
- **Evidence:** A clean arm64 Xcode build succeeded; the app process ran and updated the local current-day snapshot. Local Markdown links resolved and `git diff --check` passed. `xcodebuild test` remains unavailable because the scheme has no configured test action; popover and Settings visual verification remains outstanding.

### 2026-10-13 - Phases 01 And 03 / Counter Tests And UI Scope
- **Status Change:** Phase 01 In Progress -> Completed; Phase 03 remains In Progress
- **Summary:** Added a shared test action and closed coverage for rate intervals, byte direction, counter/interface changes, persistence, DST/local-day rollover, same-day time-zone changes, and unit formatting. Removed the per-app attribution placeholder from the popover and Settings.
- **Evidence:** The final arm64 `xcodebuild test` run passed all 10 `UsageMonitorTests`; the running build's popover showed live device rates, current-day device totals, and a partial-collection state with no app rows or deferral copy. Settings implementation was compiled and source-reviewed; the computer-use accessibility bridge timed out while attempting to capture its window, so Phase 03 interaction evidence remains open.

### 2026-10-13 - Phase 04 / Local Install Readiness
- **Status Change:** Planned -> Blocked
- **Summary:** Relaunched the latest local build on the target MacBook. A signed install and Start At Login validation cannot proceed until a valid local code-signing identity is configured.
- **Evidence:** The arm64 app launched and displayed live rates; `security find-identity -v -p codesigning` reported `0 valid identities found`. No branch or pull request was created.

### 2026-10-13 - Phase 03 / Menu Controls Settings
- **Status Change:** In Progress -> Completed
- **Summary:** Interactively verified the installed app's popover and Settings. Pause/resume, reset, speed and data units, and Start At Login all worked; test preferences were restored and the pre-reset daily snapshot was recovered.
- **Evidence:** Ten `UsageMonitorTests` passed. The popover showed active device-wide rates and totals without attribution copy. Settings displayed Monitoring Paused after pause and Device Monitoring Active after resume. Both units changed and returned to Mbps and MB/GB. Start At Login registered as on and was unregistered back to off. Reset displayed zero totals with a partial state; the saved snapshot was restored. With the popover closed, sample time and totals advanced over six seconds. UI images were not committed because they include local usage totals.

### 2026-10-13 - Phase 04 / Target Install Verification
- **Status Change:** Blocked -> Completed
- **Summary:** Built an ad-hoc signed arm64 app, installed it at `~/Applications/Mac Utilities.app`, migrated the previous same-day local aggregate into the sandbox container, and completed target checks.
- **Evidence:** `codesign --verify --deep --strict` passed; `codesign` identified an ad-hoc signature and the project-specific bundle ID. Start At Login was registered, then unregistered; after relaunch, Settings reported it off. Daily totals survived app restart and continued advancing. Local-day rollover and counter recovery tests passed. `curl https://example.com/` returned HTTP 200 while monitoring was active and after the app exited; the app was relaunched afterward. This is personal-use signing evidence, not Developer ID or notarization readiness.

### 2026-10-13 - Documentation Layout / Final Status
- **Status Change:** All Defined Phases remain Completed
- **Summary:** Updated product and phase links to the current `hl-docs/desktop/` location and recorded the completed phase evidence.
- **Evidence:** All phase-register links resolve; the PRD remains at `hl-docs/mac-utilities-prd.md`; `git diff --check`, project plist validation, and Xcode build/test checks pass. No branch or pull request was created.

### 2026-10-13 - Phase 01 / Local Time-Zone Warning Repair
- **Status Change:** Completed -> Completed
- **Summary:** Corrected the false-positive path for legacy snapshots with no saved time-zone identifier and migrated the prior combined “changed or unknown” warning to a clear partial-collection explanation. A known time-zone change still preserves totals and marks the day partial.
- **Evidence:** All 12 `UsageMonitorTests` passed and the arm64 ad-hoc build succeeded. Relaunching the rebuilt app migrated the sandbox snapshot to the new explanation while preserving its local day, time-zone identifier, totals, and partial status. The computer-use bridge timed out when attaching to this menu-bar app, so no new Settings screenshot was captured.

### 2026-10-13 - Phase 03 / Settings Window Activation
- **Status Change:** In Progress -> In Progress
- **Summary:** Replaced `SettingsLink` and the `Settings` scene with a singleton identified `Window` scene opened through `openWindow(id:)`; the click also requests activation for the accessory app. This directly addresses the reported failure to foreground an existing window.
- **Evidence:** The arm64 `xcodebuild test` suite passed all 12 monitor tests and the signed arm64 build succeeded. The signed build was installed at `~/Applications/Mac Utilities.app`, passed strict code-signature verification, and launched. Apple documents that opening an identified `Window` scene orders an already-open window to the front. The computer-use bridge timed out attaching to the menu-bar app, so interactive window ordering remains to be verified on the target UI.

## 12. Workflow Rules

- Every phase listed in the phase register must have a real linked file.
- If a phase becomes too large, split it into sub-phases such as phase-02a-* and phase-02b-*.
- Move a phase to Ready only when prerequisites, scope, and verification expectations are clear.
- Move a phase to Completed only after verification evidence exists in the linked phase document.
- Update this file during execution, not only at the end of work.
