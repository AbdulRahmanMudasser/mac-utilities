# Phase 14 - Monthly History Table

## 1. Phase Purpose

Provide an executable scope for a separate yearly view of saved monthly usage.

## 2. Feature Objective

- **Phase Goal:** Add a History panel to Usage for monthly comparisons.
- **User Or System Outcome:** Compare observed download, upload and combined totals across recorded months in a selected year.
- **In Scope:** Local aggregation, year selection, accessible table, empty state and focused verification.
- **Out Of Scope:** New collection, retention, storage schema, widget behavior, installation or release.

## 3. Current State And Implementation Delta

- **Verified Current Behavior:** `UsageMonitor.historyRecords` supplies saved daily records; `UsageHistoryView` shows current-month and rolling ranges alongside the History panel. `UsageHistory` groups validated Gregorian local-day keys with overflow-safe addition.
- **Verified Gap:** The post-clear History transition remains visually unverified.
- **Desired Implementation Delta:** Group saved day keys by year and month and show their totals in a separate panel.
- **Preserved Or Excluded Behavior:** Existing range behavior, reset, clear semantics, storage ownership, formatting and widget ranges stay unchanged; Clear History is now inline with Daily Usage.

## 4. Project Topology & Dependencies

- **Local Tracker:** [Desktop Execution Workflow](./execution-workflow.md)
- **Prerequisites:** Phase 08 (completed).
- **Downstream Tasks:** Not applicable.
- **Target Git Commit Prefix:** `feat(usage):`
- **Project Profile:** Native macOS SwiftUI/AppKit desktop.
- **Applicable Development Standards:** [Sections 2–4 and 5–6](./development-standards.md).

## 5. Ownership And Delivery Notes

- **Owner / Priority / Target Window:** TBD.
- **Related PRD Section:** [FR-14 Usage History](../mac-utilities-prd.md).
- **Related Build Plan:** Not applicable.

## 6. Infrastructure & Environment Requirements

- **Environment Variables / Database / Flags:** Not applicable; no storage or configuration changes.
- **Fixtures:** Isolated daily records across years, missing months and measured zeroes.
- **Reusable Utilities:** `UsageHistory.add`, `UsageFormatting.data`, `UtilityPanel` and the existing monitor.

## 7. API & Data Contract Specifications

No endpoint or event. Derive year and month from existing validated `dayKey` values without changing persisted data.

## 8. UX / Behavioral Expectations

- Show History below Daily Usage, with a native year picker and chronological, evenly spaced rows for months with at least one record. Show Month, Downloaded, Uploaded and Combined. Place Clear History inline with the Daily Usage heading.
- Default to the current local year; offer that year and years with records. If the selected year disappears after clearing, select the current year. Keep an explicitly selected valid year while records update.
- Show `No Data For This Year` for an empty year and `Saved Usage Unavailable` for unreadable storage, with centered icon-and-message placeholders of matching minimum height. A measured zero is a row. Totals represent observed usage and can have gaps.
- Use the selected unit, localized month names, shared styling and accessible labels; support compact window width.

## 9. Acceptance Criteria

- Existing Usage ranges and clearing behavior remain unchanged; Clear History is inline with Daily Usage.
- Selected-year rows aggregate only recorded months, including zero records, with saturating totals and proper calendar-year grouping.
- Year choices and empty state behave correctly after updates and Clear History; displayed values follow the current unit.
- The panel remains readable and accessible at supported window widths.

## 10. Requirement Traceability

| Requirement | Planned Implementation | Affected Files / Symbols | Acceptance Criteria | Verification Evidence |
| :--- | :--- | :--- | :--- | :--- |
| Compare monthly history by year | Aggregate and display saved records | `Shared/Usage/UsageHistory.swift`, `MacUtilities/Features/Usage/UsageHistoryView.swift` | Correct chronological monthly rows and selection | Usage tests and isolated preview |
| Preserve history and existing ranges | Read existing monitor only; no persistence changes | `UsageMonitor.historyRecords`, existing Usage view | Clear semantics and existing ranges unchanged | Regression tests and preview |
| Truthful missing and zero data | Include recorded months only and distinguish unavailable storage | Monthly aggregation and panel | Empty, unavailable and zero states | Tests and preview |

## 11. Implementation Steps (Component Audit)

### A. Shared Calculations

- [MODIFY] `Shared/Usage/UsageHistory.swift`, `UsageHistory`: derive years and monthly aggregates from valid day keys using saturating addition.

### B. Usage UI

- [MODIFY] `MacUtilities/Features/Usage/UsageHistoryView.swift`, `UsageHistoryView`: add local selection and separate panel, reusing formatting and shared controls.

### C. Regression Coverage

- [MODIFY] `Mac UtilitiesTests/Usage/UsageHistoryTests.swift`: cover year/month grouping, missing and zero values, ordering and overflow.

## 12. Risks And Rollback Notes

- **Implementation Risks:** Incorrect local-day grouping, stale selection or narrow layout. Verify with isolated data.
- **Operational Risks:** None beyond existing observed-usage gaps and storage limit; no migration.
- **Rollback Approach:** Revert the source and tests; no persisted data changes.

## 13. Verification Protocol (Definition of Done)

### A. Automated Suite

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme 'Mac Utilities' -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-monthly CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- Run `git diff --check`; generate the ignored project with XcodeGen if absent.

### B. Functional Verification Matrix

| State | Trigger | Expected Result |
| :--- | :--- | :--- |
| Data | Select a recorded year | Monthly totals and chronological rows |
| Empty / zero | Select an empty year / recorded zero | Empty message / zero row |
| Clear | Confirm existing Clear History | New panel clears and selection remains valid |
| Compact | Inspect isolated Debug preview | Readable, accessible controls and rows |

### C. Evidence To Capture

Build/test results and isolated preview layout and interaction inspection; do not use production data.

## 14. Execution Notes

- **Status:** In Progress
- **Started At:** Implementation started; date not recorded.
- **Completed At:** Not completed
- **Blockers Encountered:** None known.
- **Notes:** Installed Release 3.0.0 (27) includes this implementation. The compact history table, older-year selection, empty and unavailable states, and Clear History confirmation were inspected. The confirmation was cancelled, so the post-clear History transition remains visually unverified. The full release regression suite passed 232 tests.
