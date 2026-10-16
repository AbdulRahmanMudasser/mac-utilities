# Phase 09 - Extended Stability Checks

## 1. Phase Purpose

Extend Connection with an explicitly started 5, 15 or 30 minute session that reveals changes in reply time, missed test replies and periods without observations. Preserve the existing quick reply check and speed test.

## 2. Feature Objective

- **Phase Goal:** Make intermittent connection behavior visible over a bounded observation period with accurate sampling and lifecycle accounting.
- **User Or System Outcome:** Start a low-traffic check during calls or gaming, inspect the resulting timeline, and distinguish missed endpoint replies from sleep, unavailable paths and cancelled probes.
- **In Scope:** Duration selection, bounded scheduling/probes, live per-endpoint timeline, summaries and gaps, cancellation, process cleanup, path/sleep observation, transient results and shared UI.
- **Out Of Scope:** Scheduled/automatic checks, diagnostic persistence/export, alerts, traffic interception, a load test throughout the session, new public providers, DNS/router diagnosis, guarantees about other services, and changes to usage accounting or the popover.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md).
- **Product Source:** Current request and [PRD](../mac-utilities-prd.md) FR-11–13. The longer duration extends the prior manual diagnostic scope; the one-minute limit remains specific to the existing speed test.
- **Prerequisites (Blocked By):** Completed [Phase 08](./phase-08-shared-architecture-foundation.md). Paths below are its planned destinations; current anchors are identified explicitly where needed.
- **Downstream Tasks (Unlocks):** [Phase 10](./phase-10-wireless-link-quality.md) follows in delivery order, although its code dependency is Phase 08. [Phase 11](./phase-11-configurable-usage-widget.md) also depends on the foundation rather than this diagnostic.
- **Target Git Commit Prefix:** `feat(connection): ...`.
- **Project Profile(s):** Native macOS SwiftUI/AppKit, bounded system-process diagnostics and Swift Charts (high confidence).
- **Applicable Development Standards:** Phase 08's future `hl-docs/desktop/development-standards.md` and current [Phase 06 Section 7](./phase-06-unified-utility-window.md)/[Phase 07 Section 7](./phase-07-usage-history-chart.md); `MacUtilities/UI/UtilityStyle.swift` after Phase 08. Fallback: `/Users/abdulrahman/.codex/skills/check-implementation/references/common-baseline.md`. No native desktop-specific fallback exists. Recheck the foundation's actual layout before implementation.
- **Platform References:** [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock) advances through sleep; [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor) observes available paths; [NSWorkspace sleep notifications](https://developer.apple.com/documentation/appkit/nsworkspace). Path availability is supporting context and does not prove internet endpoint reachability.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Journey 5; FR-11–13; diagnostic measurement boundaries and transient results.
- **Related Build Plan Section:** Not applicable; the execution workflow owns delivery sequencing.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** No new production variables. Inject clock, scheduler, path/sleep events and probe operations for deterministic tests.
- **Database/Index Changes:** Not applicable; session data stays in memory and is discarded at app termination.
- **Feature Flags / Config Switches:** Preserve existing fixed executables/network entitlements. Add a Debug-only synthetic stability preview route using the existing Connection preview approach; it must start no real probes or production collection.
- **Seed / Fixture Requirements:** Successful replies, valid no-reply summaries, launch/parser failures, delayed results, cancelled processes, network/sleep gaps, wall-clock jumps and all three durations.
- **Required Reusable Utilities:** `ConnectionDiagnostics` owns the overall activity; reuse `ProbeTarget.defaults`, existing ping parsing validation, `DiagnosticProcessRunner`, the singleton window/fixed status footer, Swift Charts and centralized tooltip/style helpers. No new package or helper app is required.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** User Start sends ICMP echo probes to existing `8.8.8.8` and `1.1.1.1` targets. Preserve target identity in results. Do not run the quick check's HTTPS fallback repeatedly within this session.
- **Request Schema:** Duration is a typed enum limited to 300/900/1800 seconds, default 300. Recommended fixed cadence: one probe per target every five seconds, with an immediate first eligible pair and no user cadence setting. This keeps traffic low while sampling more frequently than a ten-second check. Explain that events between samples may be missed; this is sampled evidence, not continuous proof of service quality.
- **Scheduling Contract:** One app-owned session has a unique ID, ContinuousClock start/deadline, wall-clock start for display and path epoch. Schedule slots at start + N × 5 seconds strictly before the deadline. Run at most two bounded single-probe children concurrently, one per target, with a three-second watchdog capped by remaining session time. Use fixed arguments, numeric output, `LC_ALL=C`, one echo and a bounded packet/reply lifetime; use `/sbin/ping` with the fixed argument array `-n -c 1 -i 1 -W 1500 -t 2 <existing-target>`, plus the three-second runner watchdog. Verify the installed man-page semantics and validate both reply and no-reply outputs in the signed integration gate; if the tool does not emit a valid transmitted summary before the watchdog, classify that attempt as unavailable rather than loss. No shell commands or arbitrary destinations. Maximum 60/180/360 slots per endpoint for 5/15/30 minutes; do not catch up missed slots or overlap old probes with a new slot. Wait for an initial path observation before dispatch; slots with pending, unsatisfied or requires-connection state are unobserved until a usable path is reported. Cancel at deadline and await cleanup before exposing idle state.
- **Measurement Contract:** Each result has session ID, target ID, slot/elapsed offset, wall timestamp, path epoch and outcome: received with finite nonnegative RTT, no reply with validated transmitted=1/received=0, unavailable with a reason, or interrupted. A process error, malformed/missing summary, skipped slot, cancelled operation or transition during the probe is not a missed reply. Reuse the existing parser's validation; add explicit expected-count validation at live call sites: the quick caller requests ten and the stability caller requests one. The current parser accepts sent counts 1…10, so enforcing the requested count is an intentional correction rather than an already-provided guarantee. Preserve existing summary/duplicate/exit-code checks. The installed ping manual states that replies arriving after -W can count in the summary without a printed RTT line; include that exact mismatch as unavailable, never infer a miss or invent its latency.
- **Summary Contract:** For each target, comparable completed probes = received + validated no-reply outcomes. Missed Test Replies = no-reply count, with percentage over comparable completed probes only; show Not Available if the denominator is zero. Compute reply count, median and minimum/maximum from all valid received RTTs in the session, independent of gaps. Only stability Reply Time Changes uses deltas between adjacent successful scheduled slots in the same path/coverage segment; a miss or unobserved slot breaks adjacency. Preserve the existing quick-check `ProbeStatistics.jitter` definition over adjacent successful reply samples, including its current 4-sent/3-reply fixture with expected jitter 15; do not apply the stability continuity rule to that existing metric. Mean stability Reply Time Changes equals the sum of eligible absolute adjacent RTT differences divided by the number of such pairs, or Not Available when no pair exists. Keep unobserved/skipped/interrupted counts and coverage durations separate. Coverage duration describes sampler availability, not proof of connectivity in the time between discrete probes. A cancelled in-flight echo may have been physically sent, so the UI must label the denominator as completed probes rather than claiming to count every packet sent.
- **Gap Contract:** Record elapsed start/end/reason for sleep, path unavailable, scheduler delay and observed network transition. Merge overlapping reasons into a union for total unobserved duration rather than summing overlapping intervals. A satisfied-path interface signature change starts a new segment and marker; create a gap only for an actual unobserved interval. NWPathMonitor does not identify every Wi-Fi access-point change; do not claim it does. Cancel in-flight observations on sleep/path epoch changes and suppress their late callbacks. Rebaseline on recovery without bursts. Each slot owns a structured pair of probe tasks tagged with operation IDs. A sleep/path interruption first advances the epoch and records its reason, then cancels those tasks, kills only their tagged child operations and awaits both runners reaping/returning before any resumed slot is started. Map that cancellation to interrupted, not a process error/no-reply. Global stopAll remains for full diagnostic shutdown; a bare kill without cancelling/joining its awaiting task is insufficient.
- **Clock Contract:** The chosen duration includes sleep and unavailable-network time. On waking after the deadline, finish with the recorded coverage gap and existing results. Continuous elapsed time owns ordering/deadlines; changes to Date/time zone affect displayed timestamps only. App suspension/scheduler stalls become gaps, never synthesized packets.
- **Session Lifecycle:** Extend `ConnectionDiagnostics.Activity` with stability and retain one top-level start/cancel/shutdown/run-ID gate. A focused `StabilityCheckSession` can own its schedule/events, but it is a child of that controller and cannot compete with quick or load checks. Section navigation preserves the session; closing the shared window and quitting cancel it, matching current behavior. Keep complete or cancelled results for the current app session, including after reopening the window. Dispose all monitor tasks, notifications and children at terminal states.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** Add a distinct Longer Stability Check panel inside Connection, using the existing `UtilityPanel` action/info pattern. A compact duration menu and Start Check action fit the adaptive heading. Before Start, the info tooltip explains low-rate probes, sample interval, endpoint limits, selected duration and closing-window cancellation. Starting does not require the speed-test disclosure because no bulk transfer runs.
- **Running State:** Keep elapsed/remaining time and Cancel in the existing fixed status area; retain the sidebar activity indicator. Disable other active test starts, including duplicate starts, while a diagnostic is running. Navigating to Usage/Settings does not lose progress. Keep collection independent from diagnostic view rendering.
- **Chart And Summary:** Use elapsed minutes, per-target distinguishable lines/markers and shared neutral styles; do not rely only on color. Break lines across gaps/misses; show confirmed misses in a labeled marker lane and coverage gaps as labeled spans. Reuse compact chart tooltips with timestamp, target, RTT or outcome; keyboard and accessibility descriptions must expose the same observations. A run without comparable samples shows its reason, without fake zeros or an empty decorated card.
- **Interruption Meaning:** Label inferred sequences as sampled periods without endpoint replies, not confirmed internet outages. Actual sleep/path gaps have their own reasons. Show completed/cancelled status, selected duration, actual observed span and completed-probe denominators. A successful task completion is not a connection quality score.
- **Error States To Support:** No replies, one target failing, launch/parser errors, blocked ICMP, sleep for the whole session, path loss/recovery, cancellation while stopping, late callbacks and near-deadline recovery. Completed earlier samples remain readable.
- **Accessibility / Platform Constraints:** Shared Title Case labels, scalable text, 620 × 420 minimum layout, matching scroll geometry, hand pointers and fixed Cancel. Preserve existing quick-check results and speed-test confirmation. No provider traffic begins merely by opening Connection.

## 8. Acceptance Criteria

- All three durations enforce the continuous deadline, sample cap and mutual exclusion; a default launch runs no checks.
- Missed replies require a validated completed transmitted probe; sleep, path changes, scheduler gaps and tool failures never inflate loss or create zero RTT.
- Live results arrive after each bounded slot, remain ordered by monotonic offsets, and retain correct per-target/segment statistics.
- Navigation retains work; close/quit/cancel stop and reap children and release path/sleep observers before another run starts. Prior run callbacks cannot change the next run.
- The chart distinguishes response variation, confirmed misses and unobserved periods, with concise accessible detail and retained cancelled results.
- Existing quick reply and speed tests preserve their contracts; observed usage continues independently and naturally includes diagnostic packet traffic.

## 9. Implementation Steps (Component Audit)

### A. Session And Sampling

- [MODIFY] `MacUtilities/Features/Connection/ConnectionDiagnostics.swift`:
  - **Target Anchor:** Current `Activity`, `startLatency`, `startLoad`, `cancel`, `shutdown`, `finish` and run-ID gating in `MacUtilities/Diagnostics/ConnectionDiagnostics.swift`.
  - [ ] Add duration/start/session state and delegate stability work to one owned session; preserve shared activity exclusion, retained results and terminal cleanup ordering. Inject session dependencies without creating a second app-level diagnostic owner.
- [NEW] `MacUtilities/Features/Connection/StabilityCheckSession.swift`, `Models/StabilityCheckModels.swift`:
  - [ ] Implement slots, monotonic deadlines, typed outcomes, per-endpoint summaries, gap union/segments and partial terminal results under Section 6. Bound arrays by the finite maximum slot count and coalesce UI updates once per completed observation rather than per timer tick.
- [MODIFY] `MacUtilities/Features/Connection/Models/DiagnosticModels.swift` and `MacUtilities/Platform/Processes/DiagnosticProcessRunner.swift`:
  - **Target Anchor:** Existing `ProbeStatistics.parse` (currently accepts sent ≤10) and runner's output caps/watchdogs/cancellation.
  - [ ] Add expected-count arguments to the live quick (10) and stability (1) call sites. Keep generic statistical parsing fixtures by passing their actual expected count where needed. Add a valid 1-sent/1-reply fixture accepted in stability mode and rejected in quick mode; the current malformed 1/1 fixture has no reply line and does not prove this distinction. Concurrent target failures must carry per-operation diagnostic detail rather than depending on the runner's shared `lastFailureDetail`; preserve current user error behavior. Keep output bounds, fixed argument arrays and child reaping. Add operation-ID-scoped stop/cancel support for a slot pair, with structured task joining before recovery; preserve global stopAll for close/quit.
- [NEW] `MacUtilities/Platform/Networking/ConnectionObservationEvents.swift`:
  - [ ] Adapt NWPathMonitor and NSWorkspace sleep/wake events into value-only session events. Register only during a run, serialize updates into the owning actor and invalidate observers/queues at every exit. Network monitoring is context, not a substitute for probes. An injected event source drives tests.

### B. Connection Presentation And Lifecycle

- [MODIFY] `MacUtilities/Features/Connection/ConnectionCheckView.swift`; [NEW] `StabilityCheckView.swift` beside it; [MODIFY] `MacUtilities/UI/UtilityStyle.swift`:
  - [ ] Add the duration/start panel, summary and chart using existing panel/info/tooltip patterns. Share new dimensions and accessible neutral series styling centrally. Keep status/Cancel in the existing fixed area and suppress empty containers.
- [MODIFY] `MacUtilities/App/UtilityWindow.swift` and `App/Mac_UtilitiesApp.swift` only where required:
  - **Target Anchor:** Existing one diagnostic StateObject, environment injection, `windowWillClose`, shutdown and Connection running indicator.
  - [ ] Wire owned session presentation/preview data; retain current navigation/close semantics without spawning view-scoped measurement loops.

### C. Tests And Delivery Documentation

- [NEW] `Mac UtilitiesTests/Connection/StabilityCheckTests.swift`; [MODIFY] reorganized `ConnectionDiagnosticsTests.swift` and `Mac UtilitiesTests/Window/UtilityWindowTests.swift`:
  - [ ] Cover duration caps/deadlines, delayed slots/no catch-up, concurrent target failures, expected count and output corruption, no-reply denominators, gap unions and stability-only continuity, preserved quick-check jitter, initial pending path, wall-clock change, sleep beyond expiry, path recovery, sleep/path interruption while both target children run, per-slot cancellation/reaping before resumed work, close/quit cancellation while a child runs, stale results, mutual exclusion and all observer/process cleanup.
  - [ ] Extend existing window tests for stability navigation/close/reopen/quit and retained partial results; preserve injected activation so tests do not add persistent Dock processes. Synthetic clock tests must not wait 30 minutes.
- [MODIFY] `project.yml`, PRD, current standards and execution workflow during implementation:
  - [ ] Register new files through the generated project, document the longer check's exact sampled semantics and retain the speed test's separate one-minute cap. Record actual native verification and cleanup evidence.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Endpoint filtering can resemble loss; time and path transitions can corrupt denominators; async cancellation can expose idle while children still run. Typed outcomes, generations and teardown gates address these boundaries.
- **Operational Risks:** Five-second probes can miss shorter interruptions and provide endpoint-specific evidence. Do not claim all call/game failures were measured. Bound CPU/process starts and verify signed-app energy/responsiveness during a real session.
- **Rollback Approach:** Remove the stability entry/session wiring and regenerate the app target. No persistent data migration is introduced; preserve usage history and existing short diagnostic behavior.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-stability CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Targeted Tests:** StabilityCheckTests, ConnectionDiagnosticsTests and UtilityWindowTests; run the complete existing suite once after targeted checks pass. Hosted tests use Phase 08 storage injection, so ad-hoc test signing does not stand in for group authorization.
- **Signed Build:** Use the Phase 08 verified local signing configuration with the same project/scheme/destination and `-configuration Release build`, omitting ad-hoc overrides. Check the resulting app signature before runtime verification.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Default / Durations | Open Connection, then explicitly run each synthetic duration | No automatic traffic; fixed selection and exact virtual deadline/caps | Tests and UI |
| Normal Run | Start a real five-minute session | Bounded live results, responsive UI, endpoint summaries and sample counts | Signed runtime |
| Missing Replies / Tool Error | Inject no replies and launch/parser failure separately | Only valid no-reply probes count as misses; tool error stays unavailable | Fixtures |
| Sleep / Recovery | Sleep and wake during a run, including beyond expiry | Gap, no bursts or fabricated loss, finish at selected continuous deadline | Clock tests and native check |
| Network Change | Interrupt/recover the network or inject path epochs | Separate gap/segment; late in-flight outcomes suppressed | Tests and native check |
| Navigation / Cancel / Close / Quit | Navigate and terminate at each active stage | Navigation retains; cancellation stops/reaps children and removes observers; partial results survive reopen | Window tests and process inspection |
| Compact Chart | Inspect complete, sparse and entirely unobserved sessions | Shared compact layout, readable tooltips, distinct gaps and accessible samples | Synthetic native previews |

### C. Evidence To Capture

- Exact build/test commands and results, synthetic sample-count/gap assertions and signed five-minute session observations.
- Real cancellation/close/quit process cleanup and no leftover runner temporary directories or extra app instances.
- Compact/default/expanded and light/dark timeline screenshots containing synthetic data; a real 15/30 minute run is optional after virtual-time duration gates and a real five-minute run pass, unless runtime defects justify more testing.

## 12. Execution Notes

- **Status:** Planned
- **Started At:** Not started
- **Completed At:** Not completed
- **Blockers Encountered:** Phase 08 must establish the source layout and shared ownership. The phase remains Planned until those prerequisites and its implementation gates are satisfied.
- **Notes:** Five-second cadence, sleep-inclusive duration, endpoint-specific results and existing cancel-on-close are the recommended planning defaults selected for the requested scope. No diagnostic code or tests were changed while creating this plan.
