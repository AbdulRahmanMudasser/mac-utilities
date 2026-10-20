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
* **Usage History Contract:** The [PRD](../mac-utilities-prd.md) owns the product requirements; [Phase 07](./phase-07-usage-history-chart.md), especially Sections 6–8, records the detailed storage, accounting, interface and verification contracts. Earlier completed phases retain their historical scope.
* **Architecture And Feature Scope:** [08 Shared Architecture Foundation](./phase-08-shared-architecture-foundation.md) implements the shared source/storage foundation; [09 Extended Stability Checks](./phase-09-extended-stability-checks.md) adds bounded manual stability sessions; [10 Wireless Link Quality](./phase-10-wireless-link-quality.md) is implemented and verified in a signed sandbox preview. [11 Configurable Usage Widget](./phase-11-configurable-usage-widget.md) is completed and was first included in installed Release 1.4.0 (16), with user acceptance recorded in its execution notes. The current installed Release is 1.4.1 (17), including the Usage chart accessibility update. The PRD records product behavior and release state, and [Desktop Development Standards](./development-standards.md) owns current source boundaries and local build setup.

## 3. Platform Baseline

* **Platform Name:** Desktop
* **Primary Runtime:** SwiftUI with AppKit integration, local device interface counters, user-started system diagnostics, and an Apple Development signed personal build with verified App Group access
* **Target Environments:** Local development and personal use on the target MacBook only
* **Deployment Target:** `~/Applications/Mac Utilities.app` on the target MacBook; installed version 1.4.1 (build 17), including configurable usage widgets, accessible Usage chart inspection, and the existing shared foundation, connection checks, Wi-Fi readings and expandable descriptions. No public binary distribution target.
* **Branch Strategy:** Feature branches from `master`, reviewed through lowercase conventional commits and a pull request before merging into `master`.
* **Required Verification Commands:**
  - `xcodegen generate --spec project.yml` using XcodeGen 2.46.0; configure ignored local signing before a signed build. See [Development Standards Section 5](./development-standards.md#5-reproducible-project-and-local-signing).
  - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-install CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build`
  - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-install CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
  - `codesign --verify --deep --strict "$HOME/Applications/Mac Utilities.app"`
  - Run the complete regression suite and opt-in signed five-minute/notification checks in [Phase 09 Section 11](./phase-09-extended-stability-checks.md#11-verification-protocol-definition-of-done) when changing stability scheduling or lifecycle behavior.
* **Release Gates:**
  - Verify live device rates, current-day totals, restart persistence, local-midnight rollover, collection-state messaging, and normal network connectivity on the target MacBook. Ad-hoc tests use injected storage; the installed app requires a verified matching development signature for group access.
  - Run the signed Release build with verified group configuration. The sole installation's history is already in the canonical ledger. Preserve it and prevent competing writers during installation.
  - Verify schema-3 daily history compatibility, reset-independent totals, calendar ranges, missing/zero states, chart interaction, storage protection and explicit clearing using the Phase 07 protocol.
  - Keep per-app usage explicitly deferred until a supported macOS report handoff and app-identity path are proven.
  - Verify manual diagnostic tools from the signed sandboxed app, including reply permissions, real metrics, impact disclosure, cancellation and child-process cleanup; diagnostic results remain transient. Retained usage history contains daily byte aggregates only.

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

* **Current Phase:** 11 - Configurable Usage Widget
* **Status:** Completed
* **Owner:** Product Developer
* **Linked Phase Doc:** [phase-11-configurable-usage-widget.md](./phase-11-configurable-usage-widget.md)
* **Immediate Goal:** All defined phases are closed. Select and approve the next improvement before starting another phase.
* **Current Blockers:** None for widget delivery. Final layout refinements and Light/Dark, clear and tinted rendering have been inspected. The Usage chart accessibility improvement is installed in signed Release 1.4.1 (17); existing widgets and both gallery families were verified. Per-app attribution remains deferred.

## 7. Ready Queue

The installed 1.4.1 (build 17) Release includes Wireless Link Quality, Configurable Usage Widget and the Usage chart accessibility improvement. Phase 11 is completed with user acceptance; installed gallery discovery and both family timelines work. No next phase is approved. The widget does not depend on Wi-Fi or stability measurement data.

## 8. Phase Register

| Phase | Name | Status | Priority | Owner | Depends On | Linked File | Target Window |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 00 | Root Project Foundation | Completed | High | TBD | None | [phase-00-project-layout-foundation.md](./phase-00-project-layout-foundation.md) | Completed 2026-10-13 |
| 01 | Device Usage Counters | Completed | High | Product Developer | Phase 00 | [phase-01-device-usage-counters.md](./phase-01-device-usage-counters.md) | Completed 2026-10-13 |
| 02 | Flow Attribution Feasibility Decision | Completed | Deferred | Product Developer | Apple API feasibility review | [phase-02-flow-app-attribution.md](./phase-02-flow-app-attribution.md) | Decision 2026-10-13 |
| 03 | Menu Controls Settings | Completed | High | Product Developer | Phases 00 and 01; Phase 02 is not required | [phase-03-menu-controls-settings.md](./phase-03-menu-controls-settings.md) | Updated And Completed 2026-10-13 |
| 04 | Target Install Verification | Completed | High | Product Developer | Phases 00, 01, and 03 | [phase-04-target-install-verification.md](./phase-04-target-install-verification.md) | Completed 2026-10-13 |
| 05 | Connection Quality Checks | Completed | TBD | TBD | Phases 01, 03, 04 | [phase-05-connection-quality-checks.md](./phase-05-connection-quality-checks.md) | Completed 2026-10-13 |
| 06 | Unified Utility Window | Completed | High | Product Developer | Phases 03, 05 | [phase-06-unified-utility-window.md](./phase-06-unified-utility-window.md) | Completed 2026-10-14 |
| 07 | Usage History Chart | Completed | TBD | TBD | Phases 01, 06 | [phase-07-usage-history-chart.md](./phase-07-usage-history-chart.md) | Completed 2026-10-15 |
| 08 | Shared Architecture Foundation | Completed | TBD | TBD | Phase 07; signed App Group access verified before data cutover | [phase-08-shared-architecture-foundation.md](./phase-08-shared-architecture-foundation.md) | Completed 2026-10-17 |
| 09 | Extended Stability Checks | Completed | TBD | TBD | Phase 08 | [phase-09-extended-stability-checks.md](./phase-09-extended-stability-checks.md) | Completed 2026-10-17 |
| 10 | Wireless Link Quality | Completed | TBD | TBD | Phase 08; delivery follows Phase 09 | [phase-10-wireless-link-quality.md](./phase-10-wireless-link-quality.md) | Completed 2026-10-20 |
| 11 | Configurable Usage Widget | Completed | TBD | Product Developer | Phase 08; delivery follows Phase 10; signed extension/group access | [phase-11-configurable-usage-widget.md](./phase-11-configurable-usage-widget.md) | Completed 2026-10-21 |

## 9. Blockers And Risks

### Active Blockers

- No active delivery blockers. Phase 11 is completed with user acceptance; verification limitations are recorded in its execution notes.
- Host and extension App Group access are verified; the sole installation retains the existing canonical container.

### Execution Risks

- Interface membership changes, counter resets, app shutdown, sleep, and time-zone changes can leave gaps in observed totals.
- Earlier daily usage cannot be recovered beyond the legacy saved snapshot. History omits unknown dates and does not invent allocations across ambiguous day boundaries. Reset Today preserves history; Clear History is separately confirmed.
- Multiple active physical or virtual interfaces may have platform-specific coverage or duplicate-accounting behavior that needs target-Mac verification.
- App attribution remains deferred until both report handoff and app-identity resolution can be proven with documented macOS-supported behavior.
- The verified Apple Development signature supports this local shared-container setup; public distribution requires a separately scoped signing and notarization plan.
- Manual diagnostic endpoints can filter probes or omit measurements. Under-load checks transfer variable amounts of data; precise results, disclosure and cancellation are required by the PRD.
- The ignored Xcode project is generated from tracked `project.yml`; personal signing values remain local.
- Shared storage uses one writer and atomic updates; Clear History must not recover records from retained backups.
- Extended checks must classify sleep/path/scheduler gaps separately from validated missed replies, enforce a continuous deadline and clean up children/observers.
- CoreWLAN sentinel values and absent readings must remain unavailable; Wi-Fi identity and Location permission are outside the new feature scope.
- WidgetKit schedules refreshes. The widget shows timestamped saved usage and must not start a second collector or imply live data while the host is closed.

## 10. Decision Log

See [Desktop Decision Log](./decision-log.md) for dated decisions, reasons and impacts. Current requirements and rules remain in their canonical documents.

## 11. Execution Log

See [Desktop Execution Log](./execution-log.md) for chronological delivery events and evidence. This workflow remains the authority for current phase status and sequencing.

## 12. Workflow Rules

- Every phase listed in the phase register must have a real linked file.
- If a phase becomes too large, split it into sub-phases such as phase-02a-* and phase-02b-*.
- Move a phase to Ready only when prerequisites, scope, and verification expectations are clear.
- Move a phase to Completed only after verification evidence exists in the linked phase document.
- Update this file during execution, not only at the end of work.
