# Desktop Execution Log

Chronological delivery history for the desktop app. Read when historical evidence is relevant; current status and sequencing belong to the [Desktop Execution Workflow](./execution-workflow.md). Preserve existing entries and append material events only when authorized.

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
- **Evidence:** The root-level arm64 build succeeded. Restarting the rebuilt app preserved and advanced the current-day counters and wrote schema version 2 with the local time-zone identifier. `xcodebuild test` could not run because the `Mac Utilities` scheme has no configured test action. At that time, a future App Group data-transfer path and app attribution were open. The later product decision deferred attribution; Phase 08 subsequently adopted App Group storage for the shared architecture.

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

### 2026-10-17 - Phases 08–11 / Planning
- **Status Change:** New phases registered as Planned; implementation has not started.
- **Summary:** Researched current storage, accounting, diagnostics, window lifecycle, source membership and tests, plus official Apple CoreWLAN/WidgetKit/App Group guidance and XcodeGen documentation. Created four phase plans with the shared architecture/storage foundation first, followed by stability checks, Wi-Fi readings and the usage chart widget.
- **Evidence:** All four plan filenames, twelve-section structures, Planned statuses, unchecked tasks, relative links and workflow entries passed documentation structure validation. `git diff --check` passed. No app source, project configuration, personal data or tests were changed or executed. A subsequent strict check-plan pass refined atomic embedded widget publication, old-writer gates, file-size and projection recovery, probe interruption cleanup and Wi-Fi visibility/discovery. Phase 08's later implementation superseded the earlier signing and data-transfer gates. No source code, tests or live data were changed during planning.

### 2026-10-18 - Local Release / Version 1.1.1
- **Status Change:** Installed version 1.1.0 (build 11) -> 1.1.1 (build 12)
- **Summary:** Released the compact connection guidance cards and reduced shared content and card padding in the signed local app.
- **Evidence:** The arm64 Release build succeeded and passed strict code-signature verification with the existing team and App Group. The prior app bundle and canonical usage ledger were backed up before replacement; the ledger backup hash matched the original. Version 1.1.1 (build 12) was installed, signature-verified and launched, and the canonical ledger remained readable.

### 2026-10-20 - Local Release / Version 1.3.0
- **Status Change:** Installed version 1.2.0 (build 14) -> 1.3.0 (build 15)
- **Summary:** Released expandable descriptions for shared utility panels and installed the Wi-Fi link-quality implementation in the signed local app.
- **Evidence:** The arm64 Release build succeeded and passed strict code-signature verification with the same team and App Group as the prior app. The previous app bundle and canonical usage ledger were preserved in a local rollback backup; the ledger copy matched before replacement. Version 1.3.0 (build 15) was installed and launched, and the canonical ledger remained valid JSON.
