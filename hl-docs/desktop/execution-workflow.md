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
* **Architecture And Feature Scope:** [08 Shared Architecture Foundation](./phase-08-shared-architecture-foundation.md) implements the shared source/storage foundation; [09 Extended Stability Checks](./phase-09-extended-stability-checks.md) adds bounded manual stability sessions; [10 Wireless Link Quality](./phase-10-wireless-link-quality.md) is implemented and verified. [11 Configurable Usage Widget](./phase-11-configurable-usage-widget.md) is completed, with acceptance recorded in its execution notes. [12 Keep Awake Control](./phase-12-keep-awake-control.md) is completed and includes the outcome-aware transient Last Ran summary and Light/Dark layout verification. [13 Local Notification System](./phase-13-local-notification-system.md) has verified native delivery and accessibility inspection. The PRD records product requirements, and [Desktop Development Standards](./development-standards.md) owns current source boundaries and local build setup.

## 3. Platform Baseline

* **Platform Name:** Desktop
* **Primary Runtime:** SwiftUI with AppKit integration, local device interface counters, user-started system diagnostics and macOS system integrations
* **Target Environments:** Local development and use on macOS
* **Deployment Target:** Local macOS builds; public binary distribution is out of scope.
* **Branch Strategy:** Feature branches from `master`, reviewed through lowercase conventional commits and a pull request before merging into `master`.
* **Build And Verification:** Follow [Desktop Development Standards Section 5](./development-standards.md#5-reproducible-project-and-local-signing) for supported build, test and signing commands. Phase-specific checks remain in their owning phase documents.
* **Release Gates:**
  - Verify live device rates, current-day totals, restart persistence, local-midnight rollover, collection-state messaging, and normal network connectivity on a supported macOS installation. Ad-hoc tests use isolated storage; verify signed-app storage access using [Development Standards Section 5](./development-standards.md#5-reproducible-project-and-local-signing).
  - Run the signed Release build with verified group configuration. Preserve existing user data and prevent competing writers during installation.
  - Verify schema-3 daily history compatibility, reset-independent totals, calendar ranges, missing/zero states, chart interaction, storage protection and explicit clearing using the Phase 07 protocol.
  - Keep per-app usage explicitly deferred until a supported macOS report handoff and app-identity path are proven.
  - Verify manual diagnostic tools from the signed sandboxed app, including reply permissions, real metrics, impact disclosure, cancellation and child-process cleanup; diagnostic results remain transient. Retained usage history contains daily byte aggregates only.
  - Verify Transcribe history permissions and content-free logging as specified in [Speech Transcription Conventions](../conventions/speech-transcription.md); run Phase 17 separately for bounded quality and responsiveness evidence.

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

* **Current Phase:** None; Phase 21 is complete. Phases 19 and 20 have not started.
* **Status:** Phase 21 is complete with network-name/fallback presentation, top-of-module permission/recovery controls, isolated regressions and signed native checks. The current installed Release is 4.3.3 (41), with regular-weight network text at the original heading size and the emphasized icon preserved. Physical Ethernet switching remains an explicitly recorded hardware verification limitation.
* **Owner:** TBD
* **Linked Phase Doc:** [phase-21-connected-network-label.md](./phase-21-connected-network-label.md)
* **Immediate Goal:** No implementation is active. Preserve the independent Planned speech sequence for Phases 19 and 20.
* **Current Blockers:** None.

## 7. Ready Queue

Phases 13–18 are complete based on recorded implementation and verification evidence. Phase 17's completion is limited to the bounded public-corpus, synthetic, runner and basic smoke evidence in its linked document; natural-speech and gated-dataset evaluation remain optional future work. Phases 19 and 20 remain Planned. [Phase 21 Connected Network Label](./phase-21-connected-network-label.md) is Completed independently of that speech sequence; its current delivery evidence and physical Ethernet limitation are recorded in the linked phase document. Closed-lid overrides, automatic triggers, schedules, remote push, notification helpers and active-session restoration remain out of scope.

## 8. Phase Register

The approved speech series is Phase 18 → Phase 19 → Phase 20. Phase 21 is a Completed independent connection-label phase with no dependency on Phases 19–20. Phase 18 is complete; Phases 19 and 20 remain Planned. Each includes implementation, isolated regression coverage and signed native verification. Phase 17 is complete within its bounded scope; any future natural-speech or gated-dataset study requires a separate scope and suitable authorized data. Phase 18 passed its backup and migration gates before the signed host cutover; the host is unsandboxed and the widget retains sandboxing. Public binary distribution remains excluded.

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
| 12 | Keep Awake Control | Completed | TBD | TBD | Phases 06 and 08 | [phase-12-keep-awake-control.md](./phase-12-keep-awake-control.md) | Completed 2026-10-22 |
| 13 | Local Notification System | Completed | TBD | TBD | Phase 12; signed local UserNotifications verification | [phase-13-local-notification-system.md](./phase-13-local-notification-system.md) | Completed 2026-11-02; user confirmed final accessibility inspection |
| 14 | Monthly History Table | Completed | TBD | TBD | Phase 08 | [phase-14-monthly-history-table.md](./phase-14-monthly-history-table.md) | Completed 2026-11-02; user confirmed verification |
| 15 | Cross Usage Comparison | Completed | TBD | TBD | Phase 14 | [phase-15-cross-usage-comparison.md](./phase-15-cross-usage-comparison.md) | Completed 2026-11-02; user confirmed verification |
| 16 | Local Speech Transcription | Completed | 2026-10-31 | TBD | Post-fix live capture and integration verification; benchmark is Phase 17 | [phase-16-local-speech-transcription.md](./phase-16-local-speech-transcription.md) | Completed 2026-11-02; user confirmed English and Urdu capture and finalization |
| 17 | Speech Quality And Responsiveness Benchmark | Completed | TBD | TBD | Phase 16 complete; pinned models/runtime and eligible public corpus data | [phase-17-speech-benchmark.md](./phase-17-speech-benchmark.md) | Completed 2026-11-07; bounded evidence and limitations recorded |
| 18 | Unsandboxed Host And Safe Data Migration | Completed | TBD | TBD | Phase 16; verified storage/signing inventory and backup gate | [phase-18-host-storage-migration.md](./phase-18-host-storage-migration.md) | Completed 2026-11-08; final native gallery recheck passed |
| 19 | Hold-To-Record And Floating Transcription | Planned | TBD | TBD | Phase 18 completed | [phase-19-hold-recording-panel.md](./phase-19-hold-recording-panel.md) | TBD |
| 20 | Focused Text Delivery And Integrated Release | Planned | TBD | TBD | Phases 18 and 19 completed | [phase-20-focused-text-delivery.md](./phase-20-focused-text-delivery.md) | TBD |
| 21 | Connected Network Label | Completed | TBD | TBD | Phases 06, 08, 10 and 18 completed; independent of Phases 19–20 | [phase-21-connected-network-label.md](./phase-21-connected-network-label.md) | Completed 2026-11-09; Release 4.3.3 (41), hardware limitation recorded in phase |

## 9. Blockers And Risks

### Active Blockers

None. Natural-speech and gated-dataset evaluation are optional future work outside Phase 17 and require suitable authorized data with checked references.

### Execution Risks

- Interface membership changes, counter resets, app shutdown, sleep, and time-zone changes can leave gaps in observed totals.
- Earlier daily usage cannot be recovered beyond the legacy saved snapshot. History omits unknown dates and does not invent allocations across ambiguous day boundaries. Reset Today preserves history; Clear History is separately confirmed.
- Multiple active physical or virtual interfaces may have platform-specific coverage or duplicate-accounting behavior that needs macOS verification.
- App attribution remains deferred until both report handoff and app-identity resolution can be proven with documented macOS-supported behavior.
- Public distribution would require separately scoped signing and notarization work if it enters product scope.
- Manual diagnostic endpoints can filter probes or omit measurements. Under-load checks transfer variable amounts of data; precise results, disclosure and cancellation are required by the PRD.
- The ignored Xcode project is generated from tracked `project.yml`; local signing configuration remains untracked.
- Shared storage uses one writer and atomic updates; Clear History must not recover records from retained backups.
- Extended checks must classify sleep/path/scheduler gaps separately from validated missed replies, enforce a continuous deadline and clean up children/observers.
- CoreWLAN sentinel values and absent readings must remain unavailable; Wi-Fi identity and Location permission remain excluded from historical Phase 10; Phase 21 narrowly adds optional transient SSID display and explicit authorization, with signed native verification required.
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
