# Phase 15 - Cross Usage Comparison

## 1. Phase Purpose

Define the desktop implementation of the approved multi-month comparison within Usage History.

## 2. Feature Objective

- **Phase Goal:** Compare observed usage for two or more selected recorded months, including across years.
- **User Or System Outcome:** Compare exact Downloaded, Uploaded and Combined values for the selected months in one table.
- **In Scope:** Compare mode, cross-year selection, current-month labeling, two-month byte difference, data-change handling and isolated verification.
- **Out Of Scope:** New collection, storage or retention, attribution, forecasts, percentages, widget changes, installation and release.

## 3. Current State And Implementation Delta

- **Verified Current Behavior:** `UsageHistoryView.monthlyHistory` presents History and comparison from `UsageHistory.monthly`, `UsageMonitor.historyRecords` and `UsageFormatting.data`; `UsageMonthID` identifies each selection by year and month.
- **Verified Gap:** The post-clear comparison transition remains visually unverified.
- **Desired Implementation Delta:** Extend the existing History owner to select recorded year/month identities across years and derive comparison presentation from the existing daily history and monthly aggregation; do not introduce another collector or ledger.
- **Preserved Or Excluded Behavior:** Normal History table, other Usage ranges, inline Clear History and its confirmation, unit preference, canonical storage, widget and existing error semantics remain intact.

## 4. Project Topology & Dependencies

- **Local Tracker:** [Desktop Execution Workflow](./execution-workflow.md).
- **Prerequisites (Blocked By):** [Phase 14](./phase-14-monthly-history-table.md) must be completed and its existing History contract preserved.
- **Downstream Tasks (Unlocks):** Not applicable.
- **Target Git Commit Prefix:** `feat(usage):`.
- **Project Profile:** Native macOS SwiftUI/AppKit desktop, macOS 26.6+.
- **Applicable Development Standards:** [Sections 2–4, 5 and 6](./development-standards.md), especially §§3, 4.1–4.3 and 4.7.

## 5. Ownership And Delivery Notes

- **Owner:** TBD. **Priority:** TBD. **Target Window:** TBD.
- **Related PRD Section:** [FR-14 Usage History](../mac-utilities-prd.md), baseline only; the approved conversation defines the new comparison scope.
- **Related Build Plan Section:** Not applicable.

## 6. Infrastructure & Environment Requirements

- **Environment Variables / Database / Flags:** Not applicable; all comparison state is derived in memory, with no new persistence or service.
- **Fixtures:** Isolated Debug fixture with multiple years, measured zero, missing months and current month; never use personal history.
- **Reusable Utilities:** `UsageHistory.monthly` and `UsageHistory.add` in `Shared/Usage/UsageHistory.swift`, `UsageFormatting.data`, `UtilityPanel` and `UsageMonitor`.

## 7. API & Data Contract Specifications

No endpoint or event. Reuse the validated local Gregorian day-key records. Selection identity must include both year and month; existing `MonthlyUsage.id` is only safe inside one year. The existing storage and widget projection contracts do not change.

## 8. UX / Behavioral Expectations

- The default History view stays unchanged. Provide icon-only `Compare` and `Done` controls using the `arrow.left.arrow.right` and `checkmark` SF Symbols, respectively, alongside the existing year selector using the shared heading layout; expose the action names accessibly and return to the default History view when Done is pressed.
- In Compare mode, show selectable recorded months in a responsive grid. Switching years retains selections; Done clears them. Use semibold text for the current month, and show years in results when selections span or differ from the displayed year. Missing months are not selectable and recorded zeroes remain selectable.
- With two or more selections show one table of Month, Downloaded, Uploaded and Combined in the current unit. For exactly two months show the absolute byte difference below the table; for more than two, show no pairwise difference. Do not show percentages or comparison bars.
- Keep no-selection and single-selection states clear without fabricated results. Preserve the existing unavailable-storage message; never present missing data as zero. Totals are observed and may have gaps; do not imply that an in-progress or incomplete month is a full-month measurement.
- Use native controls, shared spacing and semantic typography; avoid clipping at 620 × 420 and 860 × 660. Keep keyboard selection and meaningful labels. VoiceOver walkthrough is not requested.

## 9. Acceptance Criteria

- Default History, year picker and Clear History behavior remain usable and unchanged outside Compare mode.
- Two or more recorded months, including the same month in different years, can be selected and displayed together with accurate totals and exact values.
- Current month uses semibold text; missing months never become zero records, and recorded zero remains selectable and displays zero.
- Exactly two months show their byte difference without unsigned underflow; equal values show equality. More than two show no pairwise comparison.
- Selection and displayed totals stay consistent when changing years, observations, units, clearing history or losing storage access; no stale month or unavailable data is shown as a valid result.
- UI remains readable in compact and normal previews; table and difference use the same selected months and units.

## 10. Requirement Traceability

| Requirement | Planned Implementation | Affected Files / Symbols | Acceptance Criteria | Verification Evidence |
| :--- | :--- | :--- | :--- | :--- |
| Compare months across years | In-memory year/month selection using existing aggregates | `UsageHistoryView.monthlyHistory`, `UsageHistory.monthly` | Same-named months from different years remain distinct | Unit tests and multi-year preview |
| Exact values | Selected-month table | `UsageHistoryView`, `UsageFormatting.data` | Values match selected records and unit | Comparison tests and preview |
| Two-month difference | Overflow-safe absolute byte difference | `Shared/Usage/UsageHistory.swift`, `UsageHistoryView` | Increase, decrease, equal and zero work without percentage | Unit tests |
| Honest data and state | Recorded months only, current-month marker and stale-selection reconciliation | `UsageMonitor.historyRecords`, `UsageHistoryView` | Empty, zero, missing, unavailable and clearing states remain distinct | Tests and isolated preview |
| Preserve existing collection and widgets | Read existing records only | `UsageMonitor`, existing widget contract | No storage or widget changes | Diff review and existing regression suite |

## 11. Implementation Steps (Component Audit)

### A. Shared Calculations

- [MODIFY] `Shared/Usage/UsageHistory.swift`: extend the existing monthly calculations as needed to identify aggregates by year and month, reuse existing saturating totals, and compute a safe absolute difference without converting arbitrary `UInt64` totals to a signed integer. Do not change persisted `DailyUsageRecord` or widget contracts.

### B. Usage Presentation

- [MODIFY] `MacUtilities/Features/Usage/UsageHistoryView.swift`, `monthlyHistory`: add Compare/Done state, retain selection across year-picker changes, present selectable recorded months, the selected-month table and the two-month difference. Reconcile selections against updated `monitor.historyRecords`, clearing and storage failures; keep current-month status tied to `monitor.historyDate` and `historyCalendar`.
- [MODIFY if needed] `MacUtilities/App/Mac_UtilitiesApp.swift`, `previewMonitor`: extend Debug-only synthetic fixtures only as needed to demonstrate cross-year, zero and current-month selection; preserve per-process isolation and existing preview routes.

### C. Regression Coverage

- [MODIFY] `Mac UtilitiesTests/Usage/UsageHistoryTests.swift`: cover same month in different years, multiple selections, zero and missing records, signed-direction/equal byte differences and integer limits, updated observations, clearing and selected-unit formatting where applicable.
- [MODIFY if needed] `Mac UtilitiesTests/Window/UtilityWindowTests.swift`: cover comparison state or interaction only where existing hosted window patterns can verify the behavior meaningfully.

## 12. Risks And Rollback Notes

- **Implementation Risks:** Month-only IDs collide across years; unsigned subtraction can underflow; stale selections after clearing could imply nonexistent history. Current month and missing observations can distort comparisons.
- **Operational Risks:** No schema, network or service changes; existing observed-usage gaps remain.
- **Rollback Approach:** Revert comparison presentation and calculation changes; canonical history is unaffected.

## 13. Verification Protocol (Definition of Done)

### A. Automated Suite

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme 'Mac Utilities' -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-comparison CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- Run `git diff --check`; generate the ignored project with `xcodegen generate --spec project.yml` if absent. Ad-hoc tests do not verify App Group authorization.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result |
| :--- | :--- | :--- |
| Two months | Select two recorded months across years | Table and correct byte difference |
| Multiple months | Select three or more | Table for all selections; no pairwise difference |
| Empty / zero | Select a recorded zero or a year without records | Zero remains zero; absent data is not selectable |
| Current month | Select current local month | Month text is visually emphasized |
| Data changes | Update records, unit or clear isolated history | Totals update and stale selections disappear; unavailable remains distinct |
| Compact | Inspect signed isolated Debug preview at compact and normal sizes | Controls and values remain readable |

### C. Evidence To Capture

Record test/build results and isolated preview observations; use no production history. Network/auth checks are not applicable.

## 14. Execution Notes

- **Status:** In Progress
- **Started At:** Not started.
- **Completed At:** Not completed.
- **Blockers Encountered:** None known.
- **Notes:** Installed Release 3.0.0 (27) includes this implementation. Isolated previews were reviewed and the full release regression suite passed 232 tests; the post-clear visual transition remains unverified.
