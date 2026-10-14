# Phase 05 - Connection Quality Checks

## 1. Phase Purpose

Deliver the approved user-started latency/probe-loss and responsiveness-under-load checks, with target-Mac evidence and explicit unavailable results.

## 2. Feature Objective

- **Phase Goal:** Measure endpoint-specific ICMP round trips and missed replies, then optionally measure responsiveness under upload/download load with Apple's system tool.
- **User Or System Outcome:** Explain connection delays with measured results, named endpoints, sample sizes, and clear failure reasons.
- **In Scope:** Ten probes at one-second intervals to Google 8.8.8.8 and Cloudflare 1.1.1.1; min/median/max RTT, defined jitter, reply count and probe loss; HTTPS reachability fallback; sequential JSON networkQuality results; cancellation, bounded processes, Connection section of the unified utility window (Phase 06), hand cursors, local transient results, network client/server entitlements, tests and signed runtime verification. A Debug-only `--connection-check` launch argument opens the shared window on Connection for visual verification; it starts no traffic.
- **Out Of Scope:** Passive loss inference, app attribution, traffic inspection, proxying, diagnostic history, telemetry, server hosting, automatic recurring tests, and changes to daily-counter semantics.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md)
- **Prerequisites (Blocked By):** Completed Phases 01, 03, and 04.
- **Downstream Tasks (Unlocks):** Not applicable; standalone approved capability.
- **Target Git Commit Prefix:** `feat(diagnostics): ...`
- **Project Profile(s):** Native macOS SwiftUI/AppKit desktop application (high confidence). No matching platform-specific fallback exists.
- **Applicable Development Standards:** `/Users/abdulrahman/.codex/skills/check-implementation/references/common-baseline.md`: explicit async lifecycle, validated external results, useful failures, scoped tests. Existing SwiftUI environment objects, single AppKit window ownership, and `handPointer()` govern UI integration. No AGENTS.md or repository development standards were found.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Functional Requirements, Privacy, Acceptance Criteria; update after implementation to describe user-started endpoint traffic.
- **Related Build Plan Section:** Not applicable; execution workflow is authoritative.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** Set child-process `LC_ALL=C` for deterministic ping text. No credentials.
- **Database/Index Changes:** Not applicable; diagnostic results remain in memory.
- **Feature Flags / Config Switches:** Add `ENABLE_OUTGOING_NETWORK_CONNECTIONS=YES` and `ENABLE_INCOMING_NETWORK_CONNECTIONS=YES` in Debug and Release, preserving App Sandbox. Use system executables at fixed absolute paths; no shell interpolation.
- **Seed / Fixture Requirements:** Ping response/summary fixtures, networkQuality success/error/missing-field fixtures, controlled process cancellation/timeout fixtures.
- **Required Reusable Utilities:** Reuse `handPointer()` in `MacUtilities/Mac_UtilitiesApp.swift`; use `UtilityWindowCoordinator` routing from Phase 06. UsageMonitor owns device counters and remains independent.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** ICMP echo to named public addresses; HTTPS reachability to provider HTTPS endpoints when no ICMP replies; system networkQuality default test service. No backend API.
- **Request Schema:** Fixed executable + argument array. Ping uses numeric output, ten requests, one-second interval, bounded reply wait and overall watchdog. networkQuality uses sequential tests and JSON (`-s -c`) with a bounded runtime/watchdog. Keep TLS verification enabled.
- **Response Schema:** Typed in-memory endpoint result contains target identity, sent/received count, finite nonnegative RTT samples, derived statistics and optional failure; HTTPS fallback is labeled separately. Quality result contains optional finite nonnegative baseline RTT, download/upload capacities, directional RPM and the median of loaded HTTP request-response latency arrays, with sample counts. Missing metrics remain absent, never zero. Resolve the reported interface identifier using SCNetworkInterfaceGetLocalizedDisplayName; unknown identifiers retain a labeled raw fallback, and absent identifiers show Not Reported. JSON error_domain/error_code must prevent a success claim. ICMP no-reply is a measurement outcome, not proof that Internet connectivity failed.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** Connection Health and Check share the first popover row above Current Speed. Check selects Connection in the shared Mac Utilities window and dismisses the popover; current ownership, shared typography and verification belong to [Phase 06](./phase-06-unified-utility-window.md). Keep the window title in the bar and status/Cancel outside the scroll area. Use Check Now and Run Speed Test. Short introductory paragraphs omit provider names while results retain endpoint identity. Explain variable data use, possible slowdown, monitoring-dependent usage totals, time limit and cancellation in simple English before a load test. Both checks use the same body-sized Last Checked status row; failed probe/web fallback or speed-test operations show an orange warning. Keep loaded reading counts inline, omit generic post-result explanations, and preserve accessible Title Case controls and hand cursors.
- **System Behavior Change:** Manual external test traffic; child process execution outside main actor blocking work. One diagnostic run at a time; cancellation invalidates late results. Monitoring continues while windows are closed.
- **Error States To Support:** No replies, nonzero exits, launch denial/missing tool, malformed output, incomplete metrics, offline/network changes, timeout and user cancellation. No fake zeros or broad diagnoses from one endpoint.
- **Accessibility / Platform Constraints:** Existing macOS 26.6 arm64 target; child sandbox is inherited. Verify entitlement and both tool launches in the real signed build. Closing diagnostics cancels any running test.

## 8. Acceptance Criteria

- Both public endpoint results retain their identities and sample counts; min/median/max and jitter (mean absolute difference between adjacent successful RTT samples) are correctly computed.
- Zero replies displays This Server Did Not Reply. Missed Test Replies describes endpoint-specific probe loss; Web Check and Web Reply Time never masquerade as packet loss.
- Sequential networkQuality exposes reported baseline/loaded delays, capacities and directional RPM; absent fields and errors are visible.
- Tests require deliberate user action; under-load disclosure appears before transfer; Cancel and timeout leave no orphan process.
- Signed sandboxed target-Mac runtime proves both tools function with network client/server entitlements.
- Unit tests, build, signature verification, visual interaction and relevant docs pass; device counter behavior remains intact.

## 9. Implementation Steps (Component Audit)

### A. Diagnostic Models And Runner

- [x] [NEW] `MacUtilities/Diagnostics/ConnectionDiagnostics.swift`: `ProbeStatistics`, `QualityResult`, `DiagnosticProcessRunner` and `ConnectionDiagnostics` own typed results, validated parsers, statistics, bounded asynchronous process execution with promptly deleted output, cancellation/run identity, separately labeled HTTPS fallback and sequential quality results. NetworkInterfaceLabel resolves interface names through SystemConfiguration when a result completes, preserving the raw reported identifier. Injectable operations support controller tests without external traffic. This owner is independent of `UsageMonitor`.
- [x] [MODIFY] `MacUtilities.xcodeproj/project.pbxproj`: Debug/Release retain App Sandbox and add network client/server capabilities. Generated signed entitlements were inspected.

### B. Diagnostic Window And Entry Point

- [x] [NEW] `MacUtilities/Diagnostics/ConnectionCheckView.swift`: controls, impact sheet, result rows, per-check timestamps, accessibility and all pointer modifiers.
- [x] [MODIFY] `MacUtilities/Mac_UtilitiesApp.swift`: Shared diagnostic StateObject and close/quit cleanup; unified window ownership and activation now live in [Phase 06](./phase-06-unified-utility-window.md). Debug-only launch flags open Connection or Settings in that shared window for verification.
- [x] [MODIFY] `MacUtilities/ContentView.swift`: Connection Health and the right-aligned Check button share a row; the button presents/foregrounds the shared window on Connection and existing compact controls remain operational.

### C. Verification And Product Contract

- [x] [NEW] `Mac UtilitiesTests/ConnectionDiagnosticsTests.swift`: statistics/response parsing, real system latency-array shape, missing/invalid metrics, documented exit statuses, process cancellation/timeout/output bounds, and controller fallback/mutual-exclusion/stale-result behavior.
- [x] [MODIFY] `hl-docs/mac-utilities-prd.md`: approved diagnostics, privacy boundary, transient results and test-traffic inclusion reconciled in their canonical sections after implementation.
- [x] Update this phase and the execution workflow's current register with actual evidence outside implementation skill stages.

## 10. Risks And Rollback Notes

- **Implementation Risks:** System output variations, inherited sandbox permissions, external service filtering and process cleanup. Verify current target, reject invalid data, separate endpoint silence from process failures and terminate subprocesses on cancellation.
- **Operational Risks:** Under-load checks consume variable data and affect other users of the connection. Always opt-in; timeout/cancel; disclose test bytes counted in device usage.
- **Rollback Approach:** Remove diagnostic entry point/service/capability while preserving UsageMonitor and current-day storage. No data migration.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-diagnostics CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Build Command:** Same arguments with `build` instead of `test`.
- **Signature Command:** `codesign --verify --deep --strict "$HOME/Applications/Mac Utilities.app"`
- **Targeted Tests:** New diagnostic tests plus all existing UsageMonitorTests.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Response Code |
| :--- | :--- | :--- | :--- |
| Latency | Run Check in signed app | Named endpoint replies/statistics or precise no-reply outcome | N/A |
| Under Load | Deliberately start test after disclosure | Real JSON metrics from installed macOS tool; live counters continue | N/A |
| Failed Measurement | Controlled malformed/error output | Error shown; no zero metrics | N/A |
| Cancel/Close | Cancel or close during run | Running process exits; stale callbacks cannot overwrite state | N/A |
| Existing Window | Open while covered by another app | Existing singleton diagnostic window comes forward | N/A |

### C. Evidence To Capture

- `xcodebuild test` passed 33 tests / 46 parameterized executions with zero failures or skips after removing the duplicate heading, shortening copy and moving status/Cancel to the fixed footer. Result: `/tmp/mac-utilities-diagnostics/Logs/Test/Test-Mac Utilities-2026.10.13_22-04-43-+0500.xcresult`; logs remain outside Git. Computer-use inspection confirmed the revised layout, running status and successful footer cancellation.
- Signed Debug and Release builds succeeded. Strict signature verification passed for the runtime-verified Debug app and final installed Release app. Both retain sandbox, network-client and network-server entitlements. The installed Release app is `~/Applications/Mac Utilities.app` on macOS 26.6.2 arm64; the Debug-only launch flag is absent from its binary.
- Computer-use inspection of the signed app showed 10/10 replies for each public endpoint, RTT statistics and jitter. A real networkQuality run displayed baseline latency, both loaded median/sample-count rows, directional RPM, capacities and en0 interface. The impact sheet appeared before transfer.
- Actual Cancel stopped ping and restored idle state; closing the window during networkQuality stopped that process. Quit during a probe also stopped the child and terminated the original app. Process inspection found no remaining ping/networkQuality child. The final Release install has one active app process; local aggregate timestamps/totals continue advancing, preserving observed totals with monitoring active.
- The identified Connection Check window was reused through its Window menu entry. Settings remained functional, showed the revised privacy copy, and closing Settings left the diagnostic window available. The simplified check window, real 10/10 endpoint result labels, speed-test confirmation and Cancel were visually verified. The same 390-point popover ContentView was inspected in a temporary native preview: Connection Health and the right-aligned Check button fit on one line without clipping, and the button opened the real diagnostic window. The preview was removed before the final build. Visual screenshots and local usage values were not committed.
- Parser/runner/controller tests cover no replies with separate HTTPS success, malformed/missing results, tool-error exits, timeout, cancellation, child reaping, and stale-result suppression. HTTPS fallback also returned HTTP 200 for both providers during the initial sandbox receive-denial investigation.
- Documentation links and `git diff --check` validated. Historical phase logs remain historical evidence; current requirements live in the PRD and this phase.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-13
- **Completed At:** 2026-10-13
- **Blockers Encountered:** Resolved ICMP recvmsg denial by enabling network-server permission while retaining App Sandbox; resolved real networkQuality latency arrays by parsing and displaying their median/sample count.
- **Notes:** Context and plan checked against current code before implementation. A read-only implementation review found output allocation, setup cleanup and nonzero-exit classification defects; all were corrected and verified. Tools and real signed-app behavior are proven on the target macOS. Public endpoint silence remains a valid measured outcome. No listening service, Network Extension, diagnostic history, branch, commit or PR was created.
