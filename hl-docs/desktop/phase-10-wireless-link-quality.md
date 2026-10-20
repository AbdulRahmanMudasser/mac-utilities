# Phase 10 - Wireless Link Quality

## 1. Phase Purpose

Add read-only Wi-Fi link readings to the existing Connection section so the user can compare reception near the router and elsewhere. Keep Wi-Fi link measurements clearly labeled alongside the existing internet checks.

## 2. Feature Objective

- **Phase Goal:** Show current signal, noise, channel and Wi-Fi link rate through the supported CoreWLAN client API.
- **User Or System Outcome:** Inspect the local wireless link without running a speed test or requesting access to the Wi-Fi name.
- **In Scope:** A sandbox-safe reader, typed optional readings, visible-surface refresh, concise metric explanations, unavailable states, shared styling and tests.
- **Out Of Scope:** SSID/BSSID or location collection, Location permission, network scans, connection/adapter configuration, saved Wi-Fi history, router recommendations, channel changes, automatic quality scores, a new sidebar tab, new widget metrics and popover redesign.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md).
- **Product Source:** Current request and the [PRD](../mac-utilities-prd.md) Connection journey, shared UI and privacy constraints. Wi-Fi readings are new scope beyond the completed quick checks.
- **Prerequisites (Blocked By):** Completed [Phase 08](./phase-08-shared-architecture-foundation.md). Deliver after [Phase 09](./phase-09-extended-stability-checks.md) to keep one Connection UI integration sequence; Wi-Fi has no data dependency on stability results.
- **Downstream Tasks (Unlocks):** Not applicable; the [Phase 11 widget](./phase-11-configurable-usage-widget.md) shows usage history only.
- **Target Git Commit Prefix:** `feat(wifi): ...`.
- **Project Profile(s):** Native macOS SwiftUI/AppKit and read-only CoreWLAN adapter (high confidence).
- **Applicable Development Standards:** [Desktop Development Standards Sections 2–6](./development-standards.md), [Phase 06 Section 7](./phase-06-unified-utility-window.md), [Phase 07 Section 7](./phase-07-usage-history-chart.md) and `MacUtilities/UI/UtilityStyle.swift`.
- **Platform References:** [Core WLAN sandbox/client guidance](https://developer.apple.com/documentation/CoreWLAN), [CWInterface](https://developer.apple.com/documentation/corewlan/cwinterface), [RSSI](https://developer.apple.com/documentation/corewlan/cwinterface/rssivalue%28%29), [noise](https://developer.apple.com/documentation/corewlan/cwinterface/noisemeasurement%28%29), [channel](https://developer.apple.com/documentation/corewlan/cwinterface/wlanchannel%28%29), [transmit rate](https://developer.apple.com/documentation/corewlan/cwinterface/transmitrate%28%29) and [Apple DTS on SSID authorization](https://developer.apple.com/forums/thread/732431?answerId=758611022). Installed SDK headers corroborate the sentinel and permission rules.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Journey 5; FR-9 privacy; FR-13 diagnostic/window lifecycle; FR-16 Wireless Link Quality; Dependencies.
- **Related Build Plan Section:** Not applicable; the execution workflow owns delivery sequencing.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** None. Inject a reader and refresh clock/visibility source in tests.
- **Database/Index Changes:** Not applicable; Wi-Fi readings are transient and do not enter usage snapshots or shared storage.
- **Feature Flags / Config Switches:** Link/import Apple's CoreWLAN framework through the generated host target. Preserve App Sandbox; no new permission, network exception, helper process or package is required for the client-vended interface read path. Do not add location entitlements or usage descriptions.
- **Seed / Fixture Requirements:** Valid/mixed/sentinel readings, unavailable/empty discovery, no default interface, missing channel, changing interface and delayed refresh after hiding/closing. Do not infer a powered-off state from an ambiguous CoreWLAN error.
- **Required Reusable Utilities:** Use the app composition root and utility window's selection/visibility lifecycle; reuse `UtilityPanel`, `UtilityMetricRow`, `UtilityStyle`, `handPointer()` and existing injected dependency conventions.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** No network test endpoint. When Connection becomes visible, read the default Wi-Fi interface through one long-lived `CWWiFiClient`; refresh every five seconds while that surface remains visible. Stop refresh when hidden, another section is selected, the window closes or the app terminates. Re-entering performs one immediate fresh read. Coalesce overlapping refresh requests.
- **Request Schema:** No user-controlled interface/network identifier. Use the client's `interfaceNames()` result to distinguish unavailable discovery (`nil`) from a known empty list, then obtain its default interface with `interface()`; a nil default after successful nonempty discovery means no readable default interface, not proof that the hardware is absent. Obtain interface objects from that client; never initialize `CWInterface` directly. Use the client's default interface and label its BSD interface if needed. Its presence does not mean the internet's active route uses Wi-Fi; Ethernet/VPN paths can coexist.
- **Response Schema:** A Sendable value snapshot contains `sampledAt`, optional interface identifier, optional RSSI dBm, noise dBm, channel number/band/width and transmit Mbps, plus a typed availability state. Reading state is separate from the values. Preserve unknown future channel bands/widths as Unknown/Not Available rather than inventing mappings.
- **Validity Contract:** CoreWLAN documents zero RSSI/noise/transmit values as error/no-network sentinels; they are absent readings, never 0 dBm or 0 Mbps quality. Accept physically meaningful negative RSSI/noise and finite positive link rates without speculative score thresholds. Channel can be nil; preserve valid other readings. Interface discovery nil/error differs from a known empty interface list. The API cannot distinguish every disconnected/error case: use Wi-Fi Readings Unavailable when the cause is ambiguous. Clear the previous snapshot on a failed/disconnected refresh and during a new interface transition so stale values are not presented as current.
- **Concurrency Contract:** One serial worker owns the long-lived CWWiFiClient and all CWInterface references. Pass immutable values across that boundary to the MainActor presentation monitor. Do not create clients per poll, block the UI with overlapping reads, move CoreWLAN objects between detached tasks or invent unchecked Sendable conformances. Match the actual SDK annotations and the project's default actor isolation explicitly. Late results from an old visibility generation cannot republish after stop/hide/close.
- **Privacy And Read-Only Contract:** Never call `ssid`, `ssidData`, `bssid`, scanning, association, power/channel mutation or profile APIs. Do not infer the Wi-Fi name from other system stores. No location prompt is part of this feature. No reading leaves the app or is retained after app termination.
- **Measurement Boundary:** Label transmit rate Wi-Fi Link Rate in Mbps. It is the interface's current link transmit rate, separate from live byte-counter throughput and measured internet capacity. RSSI/noise/channel are local-link observations, not proof that a provider, router or internet service is healthy.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** Add a “Wi-Fi Signal And Link” panel in Connection with Signal (dBm), Noise (dBm), Channel (including available band/width) and Wi-Fi Link Rate (Mbps). State visibly that the readings help compare reception near the router and elsewhere. Use shared full-width aligned value rows. Keep the panel distinct from internet and stability results without introducing another sidebar section or a composite quality score.
- **Explanations:** Use the visible description card below the panel heading, without a heading info icon. Start with one short sentence about comparing Wi-Fi signal in different places and the five-second refresh, then give one short definition for Signal, Noise, Channel and Wi-Fi Link Rate. Describe Wi-Fi Link Rate as the connection speed between the Mac and router. Preserve any valid partial readings when another field or status is unavailable.
- **Status:** After the metric rows, show a shared timestamp row titled Last Updated, using the same appearance as Last Checked. Display Not Available for a missing metric when other readings exist. When all metrics are absent, render a short useful state instead of blank rows or an empty card. Refreshing this passive panel does not activate the diagnostic Cancel footer or block explicit internet/stability tests.
- **System Behavior Change:** One host-owned monitor manages passive visibility sampling independently of the diagnostic run task; it adds no persistent collection loop while the window is closed. Immediate refresh after wake/visibility recovery clears stale context.
- **Error States To Support:** No default Wi-Fi interface, Ethernet-only connectivity, missing channel, ambiguous API failures and sentinel metrics, interface replacement, hide/close during an in-flight read and unknown SDK enum values. Show unavailable readings when CoreWLAN cannot distinguish power-off from another failure.
- **Accessibility / Platform Constraints:** All metrics have explicit units and combined accessible labels/values. Use shared adaptive section layout, Title Case and light/dark styling at 620 × 420, 860 × 660 and 1100 × 800. Preserve current sidebar shortcuts, popover, Usage and diagnostic results.

## 8. Acceptance Criteria

- The signed sandboxed app reads supported CoreWLAN metrics on the target Mac without a Location prompt or a sandbox exception.
- Readings use client-vended interfaces, one client and one bounded visible refresh loop; hidden/closed/terminated surfaces stop work and suppress late updates.
- Sentinel, missing and unknown readings remain unavailable and cannot masquerade as real zeros or stale measurements.
- The Wi-Fi Link Rate label and Mac-to-router definition distinguish this local link reading from Internet Speed While Busy. Do not treat it as internet throughput or assume that Wi-Fi carries the active route when Ethernet/VPN may coexist.
- No network scan/configuration/identity call or persistence is introduced. Existing rate collection, history, quick/load checks and stability cancellation continue to work.

## 9. Implementation Steps (Component Audit)

### A. Platform Reader And State

- [NEW] `MacUtilities/Platform/Networking/WiFiQualityReader.swift`:
  - **Target Anchor:** No CoreWLAN adapter currently exists; `InterfaceCounterReader` and `NetworkInterfaceLabel` move beside it in Phase 08 but serve different measurement contracts.
  - [x] Implement serial client ownership, default-interface discovery, value-only capture and sentinel handling. Return typed unavailable states without calling identity or configuration APIs. Preserve partial valid readings and explicit unknown channel values.
- [NEW] `MacUtilities/Features/Connection/WiFiQualityMonitor.swift`, `Models/WiFiQualityModels.swift`:
  - [x] Implement visibility-driven immediate/five-second refresh, at most one in-flight read, generation-gated updates, state clearing, observer/task cleanup and injectable readers/clocks. Keep passive state independent from `ConnectionDiagnostics.Activity`.

### B. Composition And Shared Presentation

- [MODIFY] `MacUtilities/App/Mac_UtilitiesApp.swift`, `App/AppDelegate.swift`, `App/UtilityWindow.swift`:
  - **Target Anchor:** Existing app-lifetime StateObjects, environment injection, selected `UtilitySection`, window presentation/close and application shutdown.
  - [x] Own one Wi-Fi monitor and drive one explicit visibility predicate: Connection selected, utility window shown, app not hidden, window not miniaturized and its occlusion state contains visible. Observe window miniaturize/deminiaturize and occlusion-state notifications, app hide/unhide, selection and close, plus NSWorkspace.didWakeNotification. A false predicate stops/cancels the loop and invalidates its generation; a false→true transition performs one immediate read. Wake invalidates the old generation and performs a fresh read only if the predicate is true. Ignore notifications for other windows and unregister at teardown. View onAppear alone must not own polling. Stop passive refresh at close/quit while retaining existing diagnostic semantics.
- [NEW] `MacUtilities/Features/Connection/WiFiQualityView.swift`; [MODIFY] `ConnectionCheckView.swift` and `MacUtilities/UI/UtilityStyle.swift`:
  - [x] Render the distinct panel with its visible introduction and metric definitions, optional metric rows and meaningful empty state. Use shared styles without a heading info icon. Keep status/Cancel and explicit check actions independent from passive Wi-Fi refresh.

### C. Tests And Documentation

- [NEW] `Mac UtilitiesTests/Connection/WiFiQualityTests.swift`; [MODIFY] `Mac UtilitiesTests/Window/UtilityWindowTests.swift`:
  - [x] Test sentinel/partial/unknown formatting, interface errors, state clearing, one in-flight operation, visibility cadence and every predicate transition, unrelated-window events, stale callbacks after hide/wake, close/quit and independence from an active stability check. Use value fixtures rather than requiring a specific router or signal level in automated tests.
  - [x] Extend existing injected lifecycle tests for passive refresh without changing the host app's activation policy or real network settings.
- [MODIFY] `project.yml`, PRD, development standards and workflow during implementation:
  - [x] Register sources/CoreWLAN membership in the host only. Document privacy, metric limits, polling ownership and verified target behavior; keep Wi-Fi out of the usage-only widget contract.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Synchronous framework calls, sentinel zeros and stale interface handles can produce misleading readings; serialize the reader and validate before publishing. Avoid changing OS state to make a metric available.
- **Operational Risks:** Metrics vary by hardware/OS and may be unavailable even while internet access works. CoreWLAN does not provide a definitive explanation for every absent metric. Network/route changes need not imply the wireless interface itself changed.
- **Rollback Approach:** Remove the passive monitor/panel and generated CoreWLAN source membership. No persistent migration, network configuration or permission rollback is required.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-phase10-audit CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Targeted Tests:** WiFiQualityTests and UtilityWindowTests, followed by the existing suite once after integration. Tests use injected temporary storage from Phase 08 and a fake Wi-Fi reader.
- **Signed Build:** Same project/scheme/destination with `-configuration Release build` and Phase 08's verified local signing configuration; omit ad-hoc overrides for production group access. Inspect signature/entitlements and test the actual signed sandboxed app.
- **Result:** Full arm64 suite passed on macOS 26.6.2: 144 passed, 2 existing opt-in signed stability tests skipped, 0 failed. The final focused `UtilityWindowTests` run passed. Signed Debug preview and Release builds passed strict signature verification with App Sandbox and the configured App Group. Release contains no preview route or synthetic preview text, verification namespace, Location usage description or Location entitlement; CoreWLAN is linked. The later 1.3.0 (build 15) Release was installed and launched with the same team and App Group; the canonical usage ledger remained valid.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Connected Wi-Fi | Open Connection in the signed sandbox preview | Signal/noise, channel/band/width and link-rate values appear without a Location prompt; accessibility exposes metric labels and units | Signed native target inspection; raw readings are not retained here |
| Partial / Unavailable | Inject sentinels, missing fields and typed no-interface states | Missing readings remain unavailable; valid partial values survive; failed refreshes replace prior values | Snapshot/model and monitor tests |
| Visible / Hidden | Navigate, hide, miniaturize, close, wake, reopen and terminate | One loop; hidden/closed/terminating surfaces stop sampling; old results cannot republish; returning reads immediately | Monitor, window and delayed-termination tests |
| Concurrent Diagnostic | Run Stability Check with Wi-Fi visible, then navigate | Passive readings coexist while visible; navigation stops Wi-Fi polling while Stability Check continues | `stabilityNavigationKeepsSamplingAndCloseReopenRetainsPartialResults` |
| Link Comparison | Compare readings at two ordinary positions if practical | Values may change naturally; no health guarantee or internet-speed claim | Optional; not performed |
| Compact / Accessible | Inspect signed preview at minimum, default and expanded sizes; inspect AX labels | Wi-Fi panel remains visible with explicit units, a visible introduction and metric definitions at 620 × 420, 860 × 660 and 1100 × 800 | Signed light previews plus existing multi-size/light-dark layout test |

### C. Evidence To Capture

- Full arm64 suite passed (144 passed, 2 expected opt-in skips, 0 failed); the final focused `UtilityWindowTests` run passed. The signed Debug preview and isolated signed Release build passed strict codesign verification with App Sandbox and the configured group. Release bundle inspection found no preview route/text, verification namespace, Location usage description or entitlement; CoreWLAN is linked.
- The signed Debug preview was inspected in compact light mode. Wi-Fi readings appeared on one launch; another showed Wi-Fi Readings Unavailable. The panel showed its visible comparison sentence and metric definitions, and its timestamp was Last Updated. The Stability Check preview showed its synthetic-data notice, Reply Times description and chart before Last Checked, plus the standard Check Done footer with missed duration. No Location prompt appeared. No SSID/BSSID, raw reading values or location data were written to repository documentation.
- Compact, default and expanded light previews were inspected. Lifecycle tests cover hide/unhide, miniaturize/deminiaturize, occlusion, wake, close, termination, unrelated windows and active Stability Check coexistence.
- Source/dependency review confirms CoreWLAN is host-only and the usage widget target remains a read-only usage projection.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-20
- **Completed At:** 2026-10-20
- **Blockers Encountered:** None.
- **Notes:** The signed preview ran from `/tmp` with isolated temporary usage storage. Release 1.3.0 (build 15) was later installed at `~/Applications/Mac Utilities.app` after preserving the previous app bundle and canonical usage ledger. Wi-Fi identity and Location permission remain out of scope.
