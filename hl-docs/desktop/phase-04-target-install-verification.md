# Phase 04 - Target Install Verification

## 1. Phase Purpose

Verify the device-only developer-installed build on the owner's target MacBook, including live rates, current-day persistence, and release-gate evidence.

## 2. Feature Objective

- **Phase Goal:** Demonstrate that the integrated app works on the single supported MacBook and accurately reports which collection intervals are incomplete.
- **User Or System Outcome:** The owner can rely on observed current-day totals under a verified local setup and knows when device counters are unavailable or collection is interrupted.
- **In Scope:** Target-local ad-hoc signing and launch, start-at-login and pause/resume checks, restart/midnight tests, live device-counter checks, and rollback verification.
- **Out Of Scope:** App Store publication, general installer/distribution work, support for another Mac, production fleet deployment, and cloud services.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow Log](./execution-workflow.md)
- **Product Source:** [Mac Utilities PRD](../mac-utilities-prd.md)
- **Prerequisites (Blocked By):** Phases 00, 01, and 03 must be Completed. Phase 02 is deferred and is not a prerequisite.
- **Downstream Tasks (Unlocks):** Initial personal-use readiness; no further phase is currently defined.
- **Target Git Commit Prefix:** chore(desktop-scope): ...
- **Project Profile(s):** Native macOS local application; ad-hoc signing and installation on the named MacBook.
- **Applicable Development Standards:** Codex fallback baseline `check-implementation/references/common-baseline.md`; no repository-specific standards or more-specific native desktop baseline were found.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Sections 4, 9, 10, 12, 13, 14, 16, and 17.
- **Related Build Plan Section:** Not applicable; no build plan is maintained in this repository.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** Use the selected local Xcode installation and ad-hoc code signing; no Apple account credentials or certificates are required for this personal-use build.
- **Database/Index Changes:** Not applicable; verify the current-day local snapshot produced in Phase 01.
- **Feature Flags / Config Switches:** No Network Extension capability or app-group identifier is required for the device-only release. Public Git contents include source, tests, shared Xcode configuration, app-icon assets, and documentation. `.gitignore` excludes local signing identities/private keys/provisioning material, user-specific Xcode data, signed app bundles, archives, test output, secrets, and observed usage snapshots. Ad-hoc signing is performed locally and does not require committing a private signing identity.
- **Seed / Fixture Requirements:** Known local upload/download transfers and repeatable app-generated traffic; no production user data.
- **Required Reusable Utilities:**
  - Extend the existing `SettingsView` and `UsageMonitor` only for target verification gaps. Do not add a second install or device-monitoring utility.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** Not applicable; no service API is introduced.
- **Request Schema:** Not applicable; no network service request is introduced.
- **Response Schema:** Not applicable; no network service response is introduced.
- **Local Contract:** Installation verification consumes device-counter availability and the same local current-day snapshot as the UI; missing collection intervals remain explicitly incomplete.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** No new feature surface; this phase validates setup/status and recovery behavior in the shipped local build.
- **System Behavior Change:** Start-at-login, monitor pause/resume, and app restarts must preserve local usage state and leave network traffic operating normally.
- **Error States To Support:** App signing or launch failure, unavailable interface counters, failed local writes, pause/resume gaps, and counter resets.
- **Accessibility / Platform Constraints:** Only the target MacBook and its installed macOS 26.6.2 arm64 configuration are release targets.

## 8. Acceptance Criteria

- The developer-installed app launches on the target MacBook and reports actual device-counter availability.
- Known inbound and outbound traffic updates device totals in the expected direction; the UI presents no per-app values and identifies its totals as device-wide.
- App restart preserves current-day totals, and local midnight starts the next local-day counters.
- Pausing monitoring or encountering unavailable counters changes the visible state and marks the day partial.
- Ordinary network connectivity continues while sampling is active because the app does not interpose on connections.
- The root workflow records verification evidence and no unresolved release blocker is represented as completed.

## 9. Implementation Steps (Component Audit)

### A. Project And Data Layer

- **Not applicable:** This phase verifies the local data contract implemented in Phase 01; it does not add a second store.

### B. Monitoring Layer

- [MODIFY] MacUtilities/Monitoring/UsageMonitor.swift:
  - **Target Anchor:** Existing `resetToday()`, local-day rollover, and persisted daily snapshot behavior from Phase 01.
- [x] Confirm reset and rollover behavior; preserve valid totals through app restarts and mark sampling gaps incomplete.

### C. Client / UI Layer

- [MODIFY] MacUtilities/Mac_UtilitiesApp.swift:
  - **Target Anchor:** Existing login-at-launch behavior and Settings scene from Phase 03.
  - [x] Ensure login launch restores sampling according to the saved pause preference and reflects actual sampler/counter availability.
- [MODIFY] MacUtilities/ContentView.swift:
  - **Target Anchor:** Existing live status presentation from Phase 03.
  - [x] Verify active, paused, and incomplete states remain visible through app launch and recovery transitions.

### D. Tests And Configuration

- Verify the app's local ad-hoc signing and app launch configuration; no provider or app-group target is included.
- [MODIFY] hl-docs/desktop/execution-workflow.md:
  - **Target Anchor:** Phase Register, Blockers And Risks, and the Phase 04 execution entry.
  - [x] Record actual target-Mac verification evidence and update phase status only after every release gate passes.

## 10. Risks And Rollback Notes

- **Implementation Risks:** A successful compile alone does not verify that device counters match the intended target-Mac coverage.
- **Operational Risks:** Signing/launch configuration, local storage failure, sleep, or interface changes can make monitoring unavailable or create incomplete intervals.
- **Rollback Approach:** Quit or remove the local app and retain current-day counter data unless the user explicitly resets it. The app has no content filter to remove.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Build Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-install CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build`.
- **Test Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-install CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`.
- **Targeted Tests:** Ten `UsageMonitorTests` covering byte direction, rate intervals, interface resets, local-day boundaries, persistence, incomplete-state handling, and unit formatting.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Install/launch | Install and launch the local build | App launches and reports device-counter availability | Ad-hoc signature passed strict verification; app ran from `~/Applications/Mac Utilities.app`; Settings reported Device Monitoring Active |
| Live traffic | Request a normal web page while monitoring is active | Network access succeeds and the device sampler continues | `curl https://example.com/` returned HTTP 200 while app was running; persisted device counters advanced |
| App restart | Restart the app on the same day | Persisted totals remain; a gap is marked if counters were unavailable or non-monotonic | Before/after current-day snapshots showed retained totals and an advancing sample time after relaunch |
| Midnight | Verify rollover using local calendar boundary in test and on target as practical | New local day starts at zero; previous snapshot is not misrepresented as today's | Local-day and DST rollover tests passed; the running app uses the Asia/Karachi local-day key |
| Pause/unavailable | Pause monitoring or simulate unavailable interface counters | UI shows paused/unavailable/incomplete and ordinary connectivity remains normal | Settings showed Monitoring Paused and an incomplete reason; resume returned to active. Unavailable-counter handling is covered by source and unit-level paths. |
| Rollback | Quit the app | App stops sampling and system network settings remain unchanged | App process exited; a post-quit `curl https://example.com/` returned HTTP 200; the app was then relaunched |

### C. Evidence To Capture

- The signed arm64 build, strict ad-hoc signature validation, and all ten unit-test results.
- Sanitized target-Mac install and launch state. No developer identity was available; the personal app uses an ad-hoc signature, not Developer ID signing or notarization.
- Before/after current-day snapshots for restart and reset restoration; UI accessibility state and visual inspection for active, paused, and incomplete states. Images containing local totals were not committed.
- Successful ordinary HTTP 200 requests while the app was active and after it was quit.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-13
- **Completed At:** 2026-10-13
- **Blockers Encountered:** None for the approved personal-use scope. `security find-identity -v -p codesigning` reports zero Apple code-signing identities; the local ad-hoc signature is sufficient for this installed personal build and Start At Login verification.
- **Notes:** The arm64 ad-hoc signed build passed `codesign --verify --deep --strict`, installed and ran from `~/Applications/Mac Utilities.app`, and Start At Login registered and unregistered successfully. Current-day counters survived relaunch after preserving the legacy same-day snapshot. Local-midnight rollover passed in unit tests. HTTP 200 requests succeeded while monitoring was active and after the app was quit. This evidence applies only to this MacBook and does not imply Developer ID signing, notarization, or general distribution readiness.
