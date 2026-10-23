# Phase 09 - Extended Stability Checks

## 1. Phase Purpose

Extend Connection with an explicitly started five-minute session that reveals changes in reply time, missed test replies and periods without observations. Preserve the existing quick reply check and speed test.

## 2. Feature Objective

- **Phase Goal:** Make intermittent connection behavior visible over a bounded observation period with accurate sampling and lifecycle accounting.
- **User Or System Outcome:** Start a low-traffic check during calls or gaming, inspect the resulting timeline, and distinguish missed endpoint replies from sleep, unavailable paths and cancelled probes.
- **In Scope:** A fixed five-minute limit, bounded scheduling/probes, live per-endpoint timeline, summaries and gaps, cancellation, process cleanup, path/sleep observation, transient results and shared UI.
- **Out Of Scope:** Scheduled/automatic checks, diagnostic persistence/export, alerts, traffic interception, a load test throughout the session, new public providers, DNS/router diagnosis, guarantees about other services, and changes to usage accounting or the popover.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md).
- **Product Source:** Current request and [PRD](../mac-utilities-prd.md) FR-11–13 and FR-15. The one-minute limit remains specific to the existing speed test.
- **Prerequisites (Blocked By):** Completed [Phase 08](./phase-08-shared-architecture-foundation.md); its source layout and shared ownership are verified.
- **Downstream Tasks (Unlocks):** [Phase 10](./phase-10-wireless-link-quality.md) follows in delivery order, although its code dependency is Phase 08. [Phase 11](./phase-11-configurable-usage-widget.md) also depends on the foundation rather than this diagnostic.
- **Target Git Commit Prefix:** `feat(connection): ...`.
- **Project Profile(s):** Native macOS SwiftUI/AppKit, bounded system-process diagnostics and Swift Charts (high confidence).
- **Applicable Development Standards:** [Desktop Development Standards](./development-standards.md), shared `MacUtilities/UI/UtilityStyle.swift`, and the existing window/chart contracts in [Phase 06 Section 7](./phase-06-unified-utility-window.md)/[Phase 07 Section 7](./phase-07-usage-history-chart.md).
- **Platform References:** [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock) advances through sleep; [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor) observes available paths; [NSWorkspace sleep notifications](https://developer.apple.com/documentation/appkit/nsworkspace). Path availability is supporting context and does not prove internet endpoint reachability.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Journey 5; FR-11–13 and FR-15; diagnostic measurement boundaries and transient results.
- **Related Build Plan Section:** Not applicable; the execution workflow owns delivery sequencing.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** No new production variables. Inject clock, scheduler, path/sleep events and probe operations for deterministic tests.
- **Database/Index Changes:** Not applicable; session data stays in memory and is discarded at app termination.
- **Feature Flags / Config Switches:** Preserve existing fixed executables/network entitlements. Add a Debug-only synthetic stability preview route using the existing Connection preview approach; `--stability-preview=<state>` supports **five** states: `complete`, `sparse`, `unobserved`, `running` and `cancelled`, and must start no real probes or production collection. The sparse/unobserved aliases and appearance flags are modifiers, not additional Connection states.
- **Seed / Fixture Requirements:** Successful replies, valid no-reply summaries, launch/parser failures, delayed results, cancelled processes, network/sleep gaps, wall-clock jumps and the five-minute deadline.
- **Required Reusable Utilities:** `ConnectionDiagnostics` owns the overall activity; reuse `ProbeTarget.defaults`, existing ping parsing validation, `DiagnosticProcessRunner`, the singleton window/fixed status footer, Swift Charts and centralized tooltip/style helpers. No new package or helper app is required.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** User Start sends ICMP echo probes to existing `8.8.8.8` and `1.1.1.1` targets. Preserve target identity in results. Do not run the quick check's HTTPS fallback repeatedly within this session.
- **Request Schema:** Duration is fixed at 300 seconds in `StabilityCheckLimits`, with 60 slots and no duration selector, cases or run parameter. Fixed cadence: one probe per target every five seconds, with an immediate first eligible pair and no user cadence setting. This keeps traffic low while sampling more frequently than a ten-second check. Explain that events between samples may be missed; this is sampled evidence, not continuous proof of service quality.
- **Scheduling Contract:** One app-owned session has a unique ID, ContinuousClock start/deadline, wall-clock start for display and path epoch. Schedule slots at start + N × 5 seconds strictly before the deadline. Run at most two bounded single-probe children concurrently, one per target, with a three-second watchdog capped by remaining session time. Use fixed arguments, numeric output, `LC_ALL=C`, one echo and a bounded packet/reply lifetime; use `/sbin/ping` with the fixed argument array `-n -c 1 -i 1 -W 1500 -t 2 <existing-target>`, plus the three-second runner watchdog. Verify the installed man-page semantics and validate both reply and no-reply outputs in the signed integration gate; if the tool does not emit a valid transmitted summary before the watchdog, classify that attempt as unavailable rather than loss. No shell commands or arbitrary destinations. Maximum 60 slots per endpoint for five minutes; do not catch up missed slots or overlap old probes with a new slot. Wait for an initial path observation before dispatch; slots with pending, unsatisfied or requires-connection state are unobserved until a usable path is reported. Cancel at deadline and await cleanup before exposing idle state.
- **Measurement Contract:** Each result has session ID, target ID, slot/elapsed offset, wall timestamp, path epoch and outcome: received with finite nonnegative RTT, no reply with validated transmitted=1/received=0, unavailable with a reason, or interrupted. A process error, malformed/missing summary, skipped slot, cancelled operation or transition during the probe is not a missed reply. Reuse the existing parser's validation; add explicit expected-count validation at live call sites: the quick caller requests ten and the stability caller requests one. The current parser accepts sent counts 1…10, so enforcing the requested count is an intentional correction rather than an already-provided guarantee. Preserve existing summary/duplicate/exit-code checks. The installed ping manual states that replies arriving after -W can count in the summary without a printed RTT line; include that exact mismatch as unavailable, never infer a miss or invent its latency.
- **Summary Contract:** For each target, comparable completed probes = received + validated no-reply outcomes. Missed Test Replies = no-reply count, with percentage over comparable completed probes only; show Not Available if the denominator is zero. Compute reply count, median and minimum/maximum from all valid received RTTs in the session, independent of gaps. Only stability Reply Time Changes uses deltas between adjacent successful scheduled slots in the same path/coverage segment; a miss or unobserved slot breaks adjacency. Preserve the existing quick-check `ProbeStatistics.jitter` definition over adjacent successful reply samples, including its current 4-sent/3-reply fixture with expected jitter 15; do not apply the stability continuity rule to that existing metric. Mean stability Reply Time Changes equals the sum of eligible absolute adjacent RTT differences divided by the number of such pairs, or Not Available when no pair exists. Keep unobserved/skipped/interrupted counts and coverage durations separate. Coverage duration describes sampler availability, not proof of connectivity in the time between discrete probes. A cancelled in-flight echo may have been physically sent. The Replies row presents received and missed counts together as `n of n received · n missed (n%)`; show checks with no result and stopped checks as separate rows when present, and do not claim to count every packet sent.
- **Gap Contract:** Record elapsed start/end/reason for sleep, path unavailable, scheduler delay and observed network transition. Merge overlapping reasons into a union for total unobserved duration rather than summing overlapping intervals. A satisfied-path interface signature change starts a new segment and marker; create a gap only for an actual unobserved interval. NWPathMonitor does not identify every Wi-Fi access-point change; do not claim it does. Cancel in-flight observations on sleep/path epoch changes and suppress their late callbacks. Rebaseline on recovery without bursts. Each slot owns a structured pair of probe tasks tagged with operation IDs. A sleep/path interruption first advances the epoch and records its reason, then cancels those tasks, kills only their tagged child operations and awaits both runners reaping/returning before any resumed slot is started. Map that cancellation to interrupted, not a process error/no-reply. Global stopAll remains for full diagnostic shutdown; a bare kill without cancelling/joining its awaiting task is insufficient.
- **Clock Contract:** The fixed five-minute limit includes sleep and unavailable-network time. On waking after the deadline, finish with the recorded coverage gap and existing results. Continuous elapsed time owns ordering/deadlines; changes to Date/time zone affect displayed timestamps only. App suspension/scheduler stalls become gaps, never synthesized packets.
- **Timing And Storage Bounds:** An independent continuous-clock deadline task interrupts in-flight probes; results returning at or after expiry are interrupted rather than accepted. Scheduler delays of at least 100 ms break continuity; smaller dispatch jitter is below the runner's observation resolution. Coverage union totals are integrated independently of bounded detail arrays. Gap details are capped at four times the fixed slot count and transition markers at twice that count; the interface reports when detail is limited while retaining accurate aggregate coverage.
- **Session Lifecycle:** Extend `ConnectionDiagnostics.Activity` with stability and retain one top-level start/cancel/shutdown/run-ID gate. A focused `StabilityCheckSession` can own its schedule/events, but it is a child of that controller and cannot compete with quick or load checks. Section navigation preserves the session; closing the shared window and quitting cancel it, matching current behavior. Keep complete or cancelled results for the current app session, including after reopening the window. Dispose all monitor tasks, notifications and children at terminal states.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** Use a 5-Minute Connection Check panel inside Connection with the existing `UtilityPanel` action/info pattern and one Start Check button. Match the quick-check presentation: one separate card per server, equal columns when they fit and identical stacked cards on narrow windows, with no shared outer result card or divider. Reuse the shared reply-metric rows and order: Replies combines received and missed counts, followed by Typical Reply Time, Fastest / Slowest and Reply Time Changes. Explain missing or stopped checks in inline information tooltips. Put Reply Times in its own panel like the Usage chart. After completion use the shared Last Checked row. Before Start, the info tooltip explains low-rate probes, sample interval, server limits, the five-minute limit and closing-window cancellation. Starting does not require the speed-test disclosure because no bulk transfer runs.
- **Running State:** Keep elapsed/remaining time and Cancel in the existing fixed status area; retain the sidebar activity indicator. Disable other active test starts, including duplicate starts, while a diagnostic is running. Navigating to Usage/Settings does not lose progress. Keep collection independent from diagnostic view rendering.
- **Chart And Summary:** Use elapsed minutes, per-target distinguishable lines/markers and shared neutral styles; do not rely only on color. Break lines across gaps/misses; show confirmed misses in a labeled marker lane and coverage gaps as labeled spans. Clickable legend controls toggle endpoints, unobserved gaps and observed network changes; dim hidden controls and exclude hidden data from the plot, scale and inspection. If all series are hidden, keep the legend and show the empty-state message without axes behind it. Reuse compact chart tooltips with timestamp, target, RTT or outcome; keyboard and accessibility descriptions must expose the same observations. Keep unobserved reasons in the relevant endpoint detail or chart gap; do not repeat “Waiting For Network” as a separate summary row. A run without comparable samples shows its reason, without fake zeros or an empty decorated card.
- **Interruption Meaning:** Label inferred sequences as sampled periods without endpoint replies, not confirmed internet outages. Actual sleep/path gaps have their own reasons. Show completed/cancelled status and completed-check denominators. Keep elapsed, remaining and missed time together in the fixed footer; do not add a second elapsed/time-passed label below the chart. Hide zero missing/stopped counts; show no-result and stopped counts as separate metric rows when present. A successful task completion is not a connection quality score.
- **Error States To Support:** No replies, one target failing, launch/parser errors, blocked ICMP, sleep for the whole session, path loss/recovery, cancellation while stopping, late callbacks and near-deadline recovery. Completed earlier samples remain readable.
- **Accessibility / Platform Constraints:** Shared Title Case labels, scalable text, 620 × 420 minimum layout, matching scroll geometry, hand pointers and fixed Cancel. Preserve existing quick-check results and speed-test confirmation. No provider traffic begins merely by opening Connection.

## 8. Acceptance Criteria

- The fixed five-minute check enforces the continuous deadline, sample cap and mutual exclusion; a default launch runs no checks.
- Missed replies require a validated completed transmitted probe; sleep, path changes, scheduler gaps and tool failures never inflate loss or create zero RTT.
- Live results arrive after each bounded slot, remain ordered by monotonic offsets, and retain correct per-target/segment statistics.
- Navigation retains work; close/quit/cancel stop and reap children and release path/sleep observers before another run starts. Prior run callbacks cannot change the next run.
- The chart distinguishes response variation, confirmed misses and unobserved periods, with concise accessible detail and retained cancelled results.
- Existing quick reply and speed tests preserve their contracts; observed usage continues independently and naturally includes diagnostic packet traffic.

## 9. Implementation Steps (Component Audit)

### A. Session And Sampling

- [MODIFY] `MacUtilities/Features/Connection/ConnectionDiagnostics.swift`:
  - **Target Anchor:** `Activity`, `startLatency`, `startLoad`, `startStability`, `cancel`, `shutdown`, `finish` and run-ID gating in this file.
  - [x] Add fixed-limit start/session state and delegate stability work to one owned session; preserve shared activity exclusion, retained results and terminal cleanup ordering. Inject session dependencies without creating a second app-level diagnostic owner.
- [NEW] `MacUtilities/Features/Connection/StabilityCheckSession.swift`, `Models/StabilityCheckModels.swift`:
  - [x] Implement slots, monotonic deadlines, typed outcomes, per-endpoint summaries, gap union/segments and partial terminal results under Section 6. Bound arrays by the finite maximum slot count and coalesce UI updates once per completed observation rather than per timer tick.
- [MODIFY] `MacUtilities/Features/Connection/Models/DiagnosticModels.swift` and `MacUtilities/Platform/Processes/DiagnosticProcessRunner.swift`:
  - **Target Anchor:** Existing `ProbeStatistics.parse` (currently accepts sent ≤10) and runner's output caps/watchdogs/cancellation.
  - [x] Add expected-count arguments to the live quick (10) and stability (1) call sites. Keep generic statistical parsing fixtures by passing their actual expected count where needed. Add a valid 1-sent/1-reply fixture accepted in stability mode and rejected in quick mode; the current malformed 1/1 fixture has no reply line and does not prove this distinction. Concurrent target failures must carry per-operation diagnostic detail rather than depending on the runner's shared `lastFailureDetail`; preserve current user error behavior. Keep output bounds, fixed argument arrays and child reaping. Add operation-ID-scoped stop/cancel support for a slot pair, with structured task joining before recovery; preserve global stopAll for close/quit.
- [NEW] `MacUtilities/Platform/Networking/ConnectionObservationEvents.swift`:
  - [x] Adapt NWPathMonitor and NSWorkspace sleep/wake events into value-only session events. Register only during a run, serialize updates into the owning actor and invalidate observers/queues at every exit. Network monitoring is context, not a substitute for probes. An injected event source drives tests.

### B. Connection Presentation And Lifecycle

- [MODIFY] `MacUtilities/Features/Connection/ConnectionCheckView.swift`; [NEW] `StabilityCheckView.swift` beside it; [MODIFY] `MacUtilities/UI/UtilityStyle.swift`:
  - [x] Add the fixed five-minute start panel, summary and chart using existing panel/info/tooltip patterns. Share new dimensions and accessible neutral series styling centrally. Keep status/Cancel in the existing fixed area and suppress empty containers.
- [MODIFY] `MacUtilities/App/UtilityWindow.swift`, `MacUtilities/App/Mac_UtilitiesApp.swift` and `MacUtilities/App/AppDelegate.swift` only where required:
  - **Target Anchor:** Existing one diagnostic StateObject, environment injection, `windowWillClose`, shutdown and Connection running indicator.
  - [x] Wire owned session presentation/preview data; retain current navigation/close semantics without spawning view-scoped measurement loops.

### C. Tests And Delivery Documentation

- [NEW] `Mac UtilitiesTests/Connection/StabilityCheckTests.swift` and `StabilitySignedIntegrationTests.swift`; [MODIFY] reorganized `ConnectionDiagnosticsTests.swift` and `Mac UtilitiesTests/Window/UtilityWindowTests.swift`:
  - [x] Cover the five-minute cap/deadline, delayed slots/no catch-up, concurrent target failures, expected count and output corruption, no-reply denominators, gap unions and stability-only continuity, preserved quick-check jitter, initial pending path, wall-clock change, sleep beyond expiry, path recovery, sleep/path interruption while both target children run, per-slot cancellation/reaping before resumed work, close/quit cancellation while a child runs, stale results, mutual exclusion and all observer/process cleanup.
  - [x] Extend existing window tests for stability navigation/close/reopen/quit and retained partial results; preserve injected activation so tests do not add persistent Dock processes. Synthetic clock tests must not wait 30 minutes.
- [MODIFY] `project.yml`, PRD, current standards and execution workflow during implementation:
  - [x] Register new files through the generated project, document the longer check's exact sampled semantics and retain the speed test's separate one-minute cap. Record actual native verification and cleanup evidence.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Endpoint filtering can resemble loss; time and path transitions can corrupt denominators; async cancellation can expose idle while children still run. Typed outcomes, generations and teardown gates address these boundaries.
- **Operational Risks:** Five-second probes can miss shorter interruptions and provide endpoint-specific evidence. Do not claim all call/game failures were measured. Bound CPU/process starts and verify signed-app energy/responsiveness during a real session.
- **Rollback Approach:** Remove the stability entry/session wiring and regenerate the app target. No persistent data migration is introduced; preserve usage history and existing short diagnostic behavior.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-stability CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Targeted Tests:** StabilityCheckTests, ConnectionDiagnosticsTests and UtilityWindowTests; run the complete existing suite once after targeted checks pass. Hosted tests use Phase 08 storage injection, so ad-hoc test signing does not stand in for group authorization.
- **Signed Build:** Use the Phase 08 verified local signing configuration with the same project/scheme/destination and `-configuration Release build`, omitting ad-hoc overrides. Check the resulting app signature before runtime verification.
- **Signed Integration Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-stability-signed MACUTILITIES_SIGNED_STABILITY_CHECK=1 test -only-testing:'Mac UtilitiesTests/StabilitySignedIntegrationTests'`. These opt-in tests run a real five-minute check, validate a real no-reply summary using a reserved test address, cancel live child processes and post process-local workspace sleep/wake notifications. They do not put the Mac to sleep or change its network configuration.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Default / Fixed Duration | Open Connection, then explicitly run the five-minute check in virtual time | No automatic traffic or duration selector; exactly 300 seconds and at most 60 slots per server | Tests and UI |
| Normal Run | Start a real five-minute session | Bounded live results, responsive UI, endpoint summaries and sample counts | Signed runtime |
| Missing Replies / Tool Error | Inject no replies and launch/parser failure separately | Only valid no-reply probes count as misses; tool error stays unavailable | Fixtures |
| Sleep / Recovery | Inject sleep/wake, including beyond expiry; post native workspace notifications | Gap, no bursts or fabricated loss, finish at the fixed continuous deadline | Virtual-clock tests and signed process-local notification check; physical sleep was not triggered |
| Network Change | Inject unavailable/recovered paths and satisfied interface signatures | Separate gap/segment; late in-flight outcomes suppressed | Injected event tests plus real NWPathMonitor during signed runs; system network settings were not changed |
| Navigation / Cancel / Close / Quit | Navigate and terminate at each active stage | Navigation retains; cancellation stops/reaps children and removes observers; partial results survive reopen | Window tests and process inspection |
| Compact Chart | Inspect complete, sparse and entirely unobserved sessions | Shared compact layout, readable tooltips, distinct gaps and accessible samples | Synthetic native previews |

### C. Evidence To Capture

- The exact automated command passed 131 tests across eight suites. Virtual time covered the 300-second/60-slot cap, expiry while both probes run, scheduler delays, clock changes, overlapping gaps, bounded event details, per-operation failures and cancellation joining. Existing quick-check statistics and usage/window regressions passed.
- The final signed suite passed both tests in 307.619 seconds. Its five-minute session completed 60 probes per endpoint: 60 replies for each server, with at most two children. It also validated the reserved-address no-reply fixture and cancellation cleanup. The signed workspace test interrupted two real children, reaped them, removed observers and rejected stale notifications. Only the installed app remained afterward; no diagnostic child or runner output directory remained. One pre-existing October 13 output folder was moved into private rollback storage. These process-local notifications do not establish physical sleep timing or every possible network transition.
- Native synthetic previews covered compact/default/expanded sizing, light/dark appearance, complete/sparse/entirely unobserved results, chart labels and keyboard/accessibility tooltips. Actual-view bounds tests cover all three sizes, both appearances and missing-data states. Native checks confirmed that the selector and technical labels are absent and simultaneous missed replies remain separately visible.
- The signed Release build and strict code-signature verification passed. Version 1.0.7 (build 9) was installed with the previous app and canonical ledger retained privately for rollback. All historical dates/totals survived installation, one installed collector remained active, and sampling advanced with all views closed. XcodeGen regeneration is idempotent; current documentation links resolve and `git diff --check` passes.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-17
- **Completed At:** 2026-10-17
- **Blockers Encountered:** None remaining. Review corrected shutdown start rejection, synchronous workspace event handoff, independent deadline cancellation and compact chart-label spacing. Final regression and signed runtime gates passed.
- **Notes:** Implemented only Phase 09 using the Phase 08 layout and one diagnostic owner. Results remain transient; no usage migration, new package, Wi-Fi panel or widget target was introduced. Phases 10 and 11 remain Planned.
