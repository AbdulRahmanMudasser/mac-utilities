# Phase 07 - Usage History Chart

## 1. Phase Purpose

Extend the existing device-counter monitor with durable daily history and an interactive Usage section in the shared Mac Utilities window. Preserve the compact tray and existing connection checks.

## 2. Feature Objective

- **Phase Goal:** Retain observed daily download/upload totals and explore them through one compact stacked bar chart.
- **User Or System Outcome:** Select This Month, 30 Days, 15 Days or 7 Days, see range totals, and inspect individual days with pointer and keyboard interaction.
- **In Scope:** Snapshot migration, reset-independent daily records, local-calendar ranges, native Swift Charts, shared styling, error/empty states, accessibility, regression tests and target-Mac visual verification.
- **Out Of Scope:** Allowances, thresholds, limits, alerts, per-app attribution, iOS, remote storage, export, automatic speed checks, changes to network traffic and automatic history expiry. Git publication was outside the Phase 07 implementation scope; its later user-requested PRs are tracked separately.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md)
- **Product Source:** [Mac Utilities PRD](../mac-utilities-prd.md); current approved conversation supersedes its original exclusion of usage history.
- **Prerequisites (Blocked By):** Completed [Phase 01](./phase-01-device-usage-counters.md) and [Phase 06](./phase-06-unified-utility-window.md).
- **Downstream Tasks (Unlocks):** Not applicable; no additional phase is required for the approved feature.
- **Target Git Commit Prefix:** `feat(usage): ...`
- **Project Profile(s):** Native macOS SwiftUI/AppKit desktop application (high confidence).
- **Applicable Development Standards:** `MacUtilities/UtilityStyle.swift` and Phase 06 Section 7 for shared fonts, monochrome surfaces, padding, scroll position, resizing, singleton ownership and accessible controls. Fallback: `/Users/abdulrahman/.codex/skills/check-implementation/references/common-baseline.md` for validation, atomic persistence, lifecycle and regression coverage. No applicable AGENTS.md or separate development standards document exists; no web/mobile baseline applies.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** Completed 2026-10-15.
- **Related PRD Section:** Goals And Non-Goals, Feature Scope, Functional Requirements and Acceptance Criteria; usage history is approved by the current task.
- **Related Build Plan Section:** Not applicable; the execution workflow owns delivery status.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** No new production variables. Tests must use an isolated sandbox-temporary snapshot, deterministic counters/clock and disabled automatic collection.
- **Database/Index Changes:** Extend the existing `Application Support/MacUtilities/today-usage.json` into schema 3 with daily history in the same atomic JSON envelope. No database dependency or second independently committed history file.
- **Feature Flags / Config Switches:** Debug-only `--usage` opens Usage without starting any connection test. `--usage-preview` supplies disposable synthetic history with collection disabled; `--usage-preview-light` and `--usage-preview-compact` select fixture appearance/size without changing system settings. Retain the existing sandbox and network entitlements.
- **Seed / Fixture Requirements:** Isolated legacy snapshots; known daily records across month/year/DST boundaries; missing and measured-zero days; reset, restart, counter and storage failures. Visual fixtures contain synthetic values only.
- **Required Reusable Utilities:** `UsageMonitor` owns collection and persistence. Reuse `UtilityWindowCoordinator`, `UtilityScrollContent`, `UtilityPanel`, `UtilityValueRow`, `UtilityStyle`, `handPointer()` and existing data-unit formatting. Use Apple's built-in Charts framework; no package is required.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** No network endpoint. Existing counter samples update both Today counters and history; UI range/day selection reads the same monitor.
- **Request Schema:** `UsageHistoryRange` has This Month, 30 Days, 15 Days and 7 Days. This Month begins on local day 1; rolling ranges contain N calendar days including today. Use Gregorian civil date keys and calendar day arithmetic in the current local time zone, never fixed 86,400-second subtraction.
- **Response Schema:** Each day has an optional `DailyUsageRecord` containing a unique `YYYY-MM-DD` key, downloaded/uploaded bytes, observation timestamps and internal collection-gap metadata. Missing record means No Data; a recorded zero means measured zero. Range totals sum recorded values without inventing missing data. Today's bar updates during collection.
- **Migration Contract:** Preserve legacy schema 1/2 keys and byte totals. Seed its saved day exactly once before rollover, including a snapshot from an earlier date. New history starts from available stored observations; do not reconstruct earlier days. Reopening an already migrated snapshot must not reseed/reset history. Schema 3 stores live checkpoint and history atomically. Older saved pause fields are ignored and no longer written; formerly paused snapshots establish a fresh counter baseline and automatically collect subsequent intervals.
- **Accounting Contract:** Add each valid interface delta to history once, independent of the resettable Today total. Reset Today preserves historical totals including today's accumulated history. Save old days before replacing the live checkpoint, even when counters fail. Revisited civil dates merge new observations, not overwrite previous totals. Rebaseline ambiguous cross-day, clock-backward, time-zone and reboot intervals rather than allocating traffic to an unproven day. Same-day same-boot comparable restarts may recover deltas; store a boot identity to avoid treating a reboot as comparable counters.
- **Observation Boundaries:** A fresh baseline alone is not a measured zero; create new day records on a successful comparable interval. Migrated zeros remain legacy incomplete observations. Rebaseline same-date time-zone changes too. Reset and clear first consume an eligible pending interval; reset then clears Today only, and clear then removes the ledger only. Unsupported/corrupt storage disables Clear History to preserve the protected file.
- **Storage Contract:** Validate versions, civil keys, duplicate records, finite ordered timestamps and byte arithmetic; prevent overflow. Preserve invalid/unsupported snapshots rather than silently overwriting them. Surface saving/loading failures in Usage, retain in-memory observations and retry transient write failures. Keep records until explicit Clear History confirmation; no automatic pruning. Clear History clears the history ledger only and starts a new observation baseline without importing today's counter again or resetting Today.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** Add Usage between Connection and Settings. Preserve Command-1 Connection and Command-2 Settings; give Usage Command-3. Today's Usage appears only in the popover, with a right-aligned Usage button opening the Usage tab through the existing coordinator. The Usage tab starts with Usage Summary, without duplicate Today counters or Reset. Keep Reset in the popover footer; its confirmation explains that chart history stays unchanged. Remove Pause/Resume from the tray and the monitoring toggle from Settings; retain the remaining tray layout and actions.
- **Chart:** Use separate Usage Summary and Daily Usage panels with the existing shared section/card convention. A compact menu range picker sits beside the summary heading. Summary totals use three full-width shared value rows, with labels on the left, values aligned right, and Combined emphasized. The daily chart uses stacked monochrome bars, a concise legend, date labels without axis ticks, and an MB/GB or MiB/GiB scale. Clear History sits below and outside the chart card. Preserve readable labels and shared scroll geometry at compact widths.
- **Interaction:** Hover shows the day's date and downloaded/uploaded/combined values in a compact chart tooltip; no separate day picker, arrow-button row or permanent day-value section remains. Clicking pins the tooltip, chart arrow keys change its day, and Escape dismisses it. Use intrinsic width, caption-sized rows, a callout date and centralized 4-point spacing/8-point padding; place the tooltip above the selected rule with overflow fitting to chart bounds. Empty days show No Data; recorded zeros show their values. Range changes dismiss the tooltip. Do not show a second instructional help tooltip.
- **System Behavior Change:** Monitoring runs while the app is open, including with the popover/window closed; no user pause state remains. Opening Usage or navigating sections starts no diagnostics. Persist history with the existing bounded write cadence and flush on termination.
- **Error States To Support:** Entirely empty history, missing dates, read-only invalid/future snapshot, transient save failure with retry, unavailable counters. Keep internal gap metadata without reintroducing Partial badges or historical pause warnings. When history is empty, explain briefly that usage will appear as readings are collected.
- **Settings Presentation:** Keep monitoring status as a compact full-width status row. Put Local Time Zone inside General beside Start At Login; do not retain a one-row Readiness section.
- **Accessibility / Platform Constraints:** Native chart accessibility, explicit series labels, semantic shared fonts, selected range/day values, keyboard operations, minimum 620 × 420 and default 860 × 660 content sizing, light/dark appearance and shared scrollbar placement. Clear History is a distinct destructive action with Cancel as default; it does not change today's counters.

## 8. Acceptance Criteria

- Existing saved totals migrate once, survive restart and appear under their saved date; missing historical days are not fabricated.
- Each supported range includes today, uses calendar boundaries and yields exact directional and combined totals over stored records.
- Valid deltas, multiple resets, counter resets, interface changes, midnight, time-zone changes, backward clocks, reboot and restart do not duplicate or destroy historical totals.
- No record is created for unobserved intervening dates. Counter failures still advance the live day without attributing cross-day bytes.
- Usage fits the shared window at compact/default/expanded sizes and matches shared typography, card, control and scroll conventions. Its summary uses three full-width label/value rows and the date axis displays labels without tick marks.
- Pointer, pinned selection, keyboard day navigation and data-unit changes produce consistent selected-day values and chart labels.
- Clear History requires confirmation, preserves Today and does not reimport it on restart; cancelling changes nothing.
- Invalid/future data is preserved with a visible failure state; transient write failures recover without dropping in-memory history.
- No threshold/allowance/limit/alert, iOS target or automatic network check is introduced. Pause/Resume and the monitoring toggle are absent; saved formerly paused states automatically collect new observations.
- Tests never read/write real user usage data or leave test app instances running. Build, signature, tests and visual/interaction evidence cover the acceptance matrix.

## 9. Implementation Steps (Component Audit)

### A. Data And Monitoring Layer

- [NEW] `MacUtilities/Monitoring/UsageHistory.swift`:
  - **Target Anchor:** Native monitoring folder beside `UsageMonitor.swift`; pure history records, range calendar helpers, validation and query results.
  - [x] Define daily records, four ranges, missing-day query results and safe summation.
  - [x] Provide deterministic calendar/range/date validation and migration/accounting helpers, avoiding a second collection owner.
- [MODIFY] `MacUtilities/Monitoring/UsageMonitor.swift`:
  - **Target Anchor:** `PersistedUsage`, initializer, `sample`, `resetToday`, `applyDelta`, rollover, `saveState` and `loadState`.
  - [x] Extend the envelope and migrate legacy saved-day totals once; validate before writes.
  - [x] Publish reset-independent history and storage errors; handle calendar/clock/boot boundaries and continuous collection.
  - [x] Keep bounded atomic writes, retry failures, flush on termination and provide confirmed ledger clearing.
  - [x] Inject snapshot URL, clock, calendar/time zone, counter reader, boot identity and sampling switch for deterministic sandbox-isolated tests.

### B. Client / UI Layer

- [NEW] `MacUtilities/Monitoring/UsageHistoryView.swift`:
  - **Target Anchor:** Usage page in the existing shared window.
  - [x] Implement native stacked Charts bars, four ranges, totals, missing/empty/error states and matching selected-day detail.
  - [x] Add compact hover/pinned tooltips, native chart accessibility, arrow-key day selection and explicit confirmed Clear History. Remove separate day controls and instructional chart help per the approved UI revision.
- [MODIFY] `MacUtilities/UtilityWindow.swift`:
  - **Target Anchor:** `UtilitySection` and `UtilityWindowView` switch/sidebar.
  - [x] Add Usage and an explicit per-section shortcut while preserving singleton and diagnostic lifecycle.
- [MODIFY] `MacUtilities/UtilityStyle.swift`:
  - **Target Anchor:** Shared tokens; add chart-only dimensions and neutral series styles here, not local copies.
  - [x] Apply shared fonts, responsive cards/controls and consistent scroll geometry to Usage.
- [MODIFY] `MacUtilities/Mac_UtilitiesApp.swift`:
  - **Target Anchor:** App initialization, `AppDelegate.applicationWillTerminate` and debug window routing.
  - [x] Isolate test-host monitoring, flush on quit and expose `--usage`; remove Today's Usage and the monitoring toggle from Settings. Keep Today's Usage only in ContentView with a Usage navigation button, retaining footer Reset and removing Pause/Resume.

### C. Tests And Local Configuration

- [NEW] `Mac UtilitiesTests/UsageHistoryTests.swift`:
  - **Target Anchor:** Existing Swift Testing target.
  - [x] Cover migration/idempotency, day/range boundaries, reset-independent accumulation, missing/zero, overflow, invalid/future data, save failure/retry, restart/clock/boot behavior and clear semantics with isolated fixtures.
- [REUSE / MODIFY] `Mac UtilitiesTests/UsageMonitorTests.swift` and `Mac UtilitiesTests/UtilityWindowTests.swift`:
  - **Target Anchor:** Existing pure counter tests and parameterized singleton/window routing cases.
  - [x] Retain existing counter behavior coverage and update saved-state expectations for continuous collection; cover history regressions in UsageHistoryTests and extend window cases for Usage selection, preserved shortcuts, resize/reopen and hosted-view bounds with synthetic history. Native interaction verifies selected-day details.
- [MODIFY, LOCAL ONLY] `MacUtilities.xcodeproj/project.pbxproj`:
  - **Target Anchor:** Explicit app/test source lists; project remains ignored per prior user instruction.
  - [x] Register new Swift files; Charts links through Swift's framework import. Keep only Mac targets and existing local signing.

## 10. Risks And Rollback Notes

- **Implementation Risks:** History and Today can diverge incorrectly if reset operations share a ledger; store independent daily totals in one atomic envelope. Civil-day transitions cannot accurately split unseen traffic; rebaseline those intervals and retain internal coverage metadata. Chart work must not move collection into view lifecycle.
- **Operational Risks:** The old app does not understand history; do not run it concurrently against schema 3. Invalid/future snapshots remain protected. Per-day records have small storage cost; chart queries only load the selected range for presentation.
- **Rollback Approach:** Stop the development app; restore the prior app without deleting the schema-3 snapshot. Restore a pre-migration snapshot if running the old writer, since older code does not preserve unknown history fields. Visual verification uses isolated synthetic data and does not install over the personal app.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-usage-history CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Build Command:** Same command with `-configuration Release build` in place of `test`.
- **Signature Command:** `codesign --verify --deep --strict '/tmp/mac-utilities-usage-history/Build/Products/Release/Mac Utilities.app'`
- **Targeted Tests:** `UsageHistoryTests`, `UsageMonitorTests` and `UtilityWindowTests`; run the existing diagnostic suite too. Use a fixture-backed host for all app launches. Inspect exact derived-data-owned process paths on normal/error exits and close only owned hosts.
- **Documentation Command:** `git diff --check`; verify Markdown relative links, matching phase/workflow state and the 12-section established phase structure.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Response Code |
| :--- | :--- | :--- | :--- |
| Existing Data | Open a schema-2 fixture, reopen migrated state | Saved day preserved once; no invented older days | N/A - Local App |
| Range Selection | Select all four ranges across month/DST boundaries | Correct inclusive calendar dates, bars and totals | N/A - Local App |
| Day Inspection | Hover, pin, keyboard-select missing/zero/nonzero days | Matching details without color-only meaning | N/A - Local App |
| Lifecycle | Reset, midnight, restart, reboot/clock/time-zone change | No lost/doubled history; fresh safe baseline | N/A - Local App |
| Storage Failure | Inject invalid version, malformed JSON, failing write then retry | File protected or retry succeeds; error visible | N/A - Local App |
| Clear History | Cancel, confirm, restart | Cancel unchanged; clear preserves Today and is durable | N/A - Local App |
| Resize And Appearance | Navigate all sections at compact/default/expanded sizes in light/dark | Shared spacing, readable controls/axes and no clipping | N/A - Local App |
| Window Close | Close development window | Monitoring continues; diagnostics stop as before | N/A - Local App |
| Shutdown | Quit test host | Sampling flushed; no owned host or test process remains | N/A - Local App |

Authentication/API rows are not applicable: this is a local device-counter feature with no backend or new network request.

### C. Evidence To Capture

- **Automated Evidence:** The exact test command passed 79 tests in four suites on 2026-10-15. Result bundle: `/tmp/mac-utilities-usage-history/Logs/Test/Test-Mac Utilities-2026.10.15_18-42-24-+0500.xcresult`. Includes legacy schema migration, formerly paused schema 1/2/3 snapshot compatibility, repeat migration, reset/clear independence, restart/midnight, DST/leap/year ranges, counter failures, clock/time-zone changes, malformed/future file preservation, save retry, combined-byte overflow, termination flush and real sandboxed interface/boot reads into isolated storage. Existing diagnostics and window regressions pass against the current source.
- **Build And Signature:** Signed Release 1.0.6 (8) built successfully using `/tmp/mac-utilities-install` as derived data and replaced `~/Applications/Mac Utilities.app`. Strict signature verification passed before installation; the release Info.plist reports version 1.0.6 and build 8. The app opened successfully.
- **Native Visual Evidence:** Computer use inspected compact/default/expanded layouts in light/dark appearance, range changes, day selection, recorded-zero and missing days, unit conversion, clearing and tooltip positioning. Later requested summary-row and Settings rearrangements were source-reviewed and included in the successful installed Release build; no additional native screenshots were captured for those final adjustments. Synthetic fixtures were used for chart inspection. The isolated preview uses bundle ID `com.abdulrahman.mac-utilities.usage-preview` to avoid duplicate-identity UI targeting. Hosted-view bounds passed at 620 × 420, 860 × 660 and 1100 × 800 in both appearances.
- **Implementation Review:** Native SwiftUI/AppKit profile, shared UtilityStyle conventions and common fallback baseline. Corrected combined-byte overflow persistence, measured-zero handling after counter resets, empty-range zero presentation and compact date-label truncation. Final audit found no remaining verified defect; VoiceOver interaction was not separately exercised, but native accessibility labels/values and keyboard controls were inspected.
- **Cleanup And Documentation:** Process inspection after visual checks showed only the existing installed app and no owned test/preview host. `git diff --check`, local Markdown links, 12-section phase structure and workflow consistency checks pass. Older phase documents and chronological execution logs remain unchanged.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-15
- **Completed At:** 2026-10-15
- **Blockers Encountered:** None remaining. Duplicate app identities initially confused native UI targeting; a separately identified disposable preview resolved the verification issue.
- **Notes:** Plan creation and review preceded implementation; implementation audit and documentation maintenance followed it. Two bounded research/implementation agents covered accounting/tests and UI; the parent owned integration, fixes and validation. Existing counter tests were retained with obsolete pause wording removed. No pre-feature history can be recovered beyond the saved daily snapshot. No thresholds, limits, alerts or iOS code were added. The later user-requested Git publication is split across separate implementation, test and documentation PRs. Version and personal installation follow the user's explicit release request.
