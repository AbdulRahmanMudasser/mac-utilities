# Phase 02 - Flow Attribution Feasibility Decision

## 1. Phase Purpose

Close the first-release feasibility gate for per-app usage on the target MacBook. This phase records which macOS APIs are available, what is needed to produce the requested live per-app rates, and the approved first-release scope. It does not implement attribution.

## 2. Feature Objective

- **Phase Goal:** Determine whether the target supports a sufficiently low-impact, documented path for app identity, live rates, daily flow totals, and durable local handoff.
- **User Or System Outcome:** The first release uses device counters without a proxy, `nettop` estimate, Network Extension, or content-stream sampling. Per-app UI remains out of scope until an end-to-end low-impact path is proven.
- **In Scope:** Inspect the installed macOS SDK and Apple documentation; distinguish closed-flow totals from live per-app rates; record handoff and traffic-path constraints; confirm the first-release decision.
- **Out Of Scope:** Shipping a content-filter provider, privileged broker, per-app counters or UI, a `nettop` collector, a proxy, or any connection blocking/modification.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow Log](./execution-workflow.md)
- **Product Source:** [Mac Utilities PRD](../mac-utilities-prd.md)
- **Prerequisites (Blocked By):** None. The installed target SDK and current Apple documentation are available locally and online.
- **Downstream Tasks (Unlocks):** Phases 03 and 04 do not depend on app attribution. Phase 04 still depends on Phases 01 and 03. Reopen attribution only as a separately scoped phase after an approved low-impact measurement and handoff design is proven on the target MacBook.
- **Target Git Commit Prefix:** chore(desktop-scope): ...
- **Project Profile(s):** Native macOS desktop application; macOS Network Extension feasibility research.
- **Applicable Development Standards:** Codex fallback baseline `check-implementation/references/common-baseline.md`; no repository-specific native macOS standard was found.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** Medium
- **Target Window:** Completed 2026-10-13
- **Related PRD Section:** Sections 3, 7, 9, 10, 12, 13, 14, and 16.
- **Related Build Plan Section:** Not applicable; no separate build plan is maintained.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** None.
- **Database/Index Changes:** None. The first-release `UsageMonitor` continues to own device totals and local Application Support persistence.
- **Feature Flags / Config Switches:** None. This phase adds no provider or system configuration.
- **Seed / Fixture Requirements:** None; this phase is a target-SDK and platform-capability decision.
- **Required Reusable Utilities:** Reuse device interface counters as the first-release measurement source. Do not derive app values by subtracting flow totals from device totals.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** No app API or provider callback is implemented in this phase.
- **Request Schema:** Not applicable.
- **Response Schema:** Not applicable.
- **Local Contract:** No first-release model, storage, entitlement, app group, or Xcode target changes. Any later attribution phase must define flow identity, direction, byte-count semantics, handoff ownership, local-day behavior, and incomplete-state handling before implementation.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** No attribution section or deferral message appears in the first-release popover or Settings.
- **System Behavior Change:** None. The device-only app does not install or enable a content filter.
- **Error States To Support:** None in this feasibility phase. A future implementation must expose unavailable or incomplete attribution separately from device-counter status.
- **Accessibility / Platform Constraints:** The installed SDK makes `NEFilterControlProvider` and `NEFilterFlow.sourceAppIdentifier` unavailable on macOS. It provides `NEFilterProvider.handleReport(_:)`, `NEFilterDataVerdict.statisticsReportFrequency`, and `NEFilterFlow.sourceAppAuditToken`. Apple's `NEFilterReport.bytesInboundCount` and `bytesOutboundCount` documentation says these values are nonzero only for a flow-closed report. The report path can support completed-flow totals, but it does not provide the requested live per-app rates by itself.

## 8. Acceptance Criteria

- Confirm relevant API availability against the target MacBook's installed SDK and Apple documentation.
- Record that flow-closed reports provide byte totals and the macOS source audit token is available, while `sourceAppIdentifier` is unavailable.
- Record that live per-app rates require observing every inbound and outbound data chunk in a content-filter provider; returning allow verdicts preserves the bytes but puts a provider in the traffic path and its performance impact is unverified on this MacBook.
- Record that a system extension runs in the global system context. A durable handoff to the user app needs a tested system-context service or equivalent supported broker; the main app cannot be assumed to receive provider reports directly.
- Confirm the accepted first-release decision: keep device-level counters, omit attribution UI, and do not add a proxy, `nettop` estimate, or content-stream sampling.

## 9. Implementation Steps (Component Audit)

### A. Project And Data Layer

- No source, persistence, capability, entitlement, or app-group changes in this decision phase.

### B. Monitoring Layer

- Review the exact macOS declarations for report delivery, flow byte counts, source-app identity, and provider packaging.
- Distinguish completed-flow byte reports from the live data callbacks required for current per-app rates.
- Do not add the provider or a broker until the product owner approves the traffic-path and service requirements and the complete path is demonstrated on the target MacBook.

### C. Client / UI Layer

- No attribution UI is rendered. `MacUtilities/ContentView.swift` and `MacUtilities/Mac_UtilitiesApp.swift` contain no deferred-attribution placeholder.

### D. Tests And Configuration

- No test, provider target, privileged helper, entitlement, app group, or signing configuration is added by this phase.
- The decision is verified through installed SDK declarations and current Apple documentation; any later proof of concept defines its own test and installation gates.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Report byte totals at flow close do not satisfy live per-app rate requirements. Counting every data callback would put the provider in the traffic path; no latency or throughput proof has been performed on this MacBook.
- **Operational Risks:** A macOS content-filter system extension requires system configuration and approval. On this MacBook, no valid code-signing identities are currently available, so an installed-provider test cannot be performed in this phase.
- **Rollback Approach:** No filter or service is installed by this phase. If a later approved proof changes system configuration, disable/remove it and verify ordinary network access before continuing.

### Feasible Paths And Product Tradeoffs

1. **Device-Level First Release (Accepted):** Keep public interface counters, omit the app-attribution UI, and preserve normal network handling. Revisit only after a low-impact live measurement and handoff path is demonstrated.
2. **Best-Effort Process Sampling (Not Selected):** Use `nettop` process output. It is not a stable app API and can miss short-lived activity.
3. **Content-Filter Sampling (Deferred):** Observe flow data and return allow verdicts. This could provide live byte deltas, but it places a provider in the traffic path and requires a durable system-to-user handoff. Performance and end-to-end behavior are unverified on the target MacBook.
4. **Proxy-Based Collection (Not Selected):** Route traffic through a proxy. This changes traffic handling and conflicts with the no-proxy product decision.

**Accepted Product Decision (2026-10-13):** Ship device-wide counters only. Do not use a proxy, best-effort `nettop` estimates, or content-stream sampling in the first release. Keep per-app rows and deferral copy out of the UI.

## 11. Verification Protocol (Definition Of Done)

### A. Automated Suite

- **Exact Command:** Not applicable; this phase changes no executable code.
- **Targeted Tests:** None.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| SDK availability | Inspect target SDK declarations | Available and unavailable macOS symbols are accurately listed | Installed SDK header references |
| Byte semantics | Inspect `NEFilterReport` API documentation | Per-flow byte values are documented as nonzero at flow close; no live per-app rate is inferred from them | Direct Apple API links |
| Product decision | Compare requested accuracy and traffic constraints to supported paths | Device-only first release is recorded; no proxy, `nettop`, filter, or placeholder UI is introduced | PRD and workflow register |

### C. Evidence To Capture

- Installed SDK declarations for `handleReport`, `statisticsReportFrequency`, `bytesInboundCount`, `sourceAppAuditToken`, and unavailable macOS APIs.
- Direct Apple documentation links for report byte semantics and macOS system-extension deployment.
- Current product decision and first-release UI scope.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-13
- **Completed At:** 2026-10-13
- **Blockers Encountered:** No end-to-end content-filter sampling or system-to-user handoff was run. That work is outside this completed feasibility-decision phase and remains deferred by the accepted first-release scope.
- **Notes:** The installed SDK and Apple documentation confirm report and audit-token APIs exist, but flow-report byte totals do not provide live per-app rates. See [NEFilterReport byte counts](https://developer.apple.com/documentation/networkextension/nefilterreport/bytesinboundcount), [NEFilterFlow source audit token](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappaudittoken), [Network Extension deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment), and Apple's [system-extension XPC guidance](https://developer.apple.com/forums/thread/794483).
