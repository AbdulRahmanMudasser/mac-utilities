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
- **Applicable Development Standards:** Future `hl-docs/desktop/development-standards.md` from Phase 08; [Phase 06 Section 7](./phase-06-unified-utility-window.md), [Phase 07 Section 7](./phase-07-usage-history-chart.md) and relocated `MacUtilities/UI/UtilityStyle.swift`. Fallback: `/Users/abdulrahman/.codex/skills/check-implementation/references/common-baseline.md`; no matching native desktop baseline exists.
- **Platform References:** [Core WLAN sandbox/client guidance](https://developer.apple.com/documentation/CoreWLAN), [CWInterface](https://developer.apple.com/documentation/corewlan/cwinterface), [RSSI](https://developer.apple.com/documentation/corewlan/cwinterface/rssivalue%28%29), [noise](https://developer.apple.com/documentation/corewlan/cwinterface/noisemeasurement%28%29), [channel](https://developer.apple.com/documentation/corewlan/cwinterface/wlanchannel%28%29), [transmit rate](https://developer.apple.com/documentation/corewlan/cwinterface/transmitrate%28%29) and [Apple DTS on SSID authorization](https://developer.apple.com/forums/thread/732431?answerId=758611022). Installed SDK headers corroborate the sentinel and permission rules.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Journey 5; FR-13 shared window; Dependencies and measurement boundaries. Add the Wi-Fi requirement during implementation.
- **Related Build Plan Section:** Not applicable; the execution workflow owns delivery sequencing.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** None. Inject a reader and refresh clock/visibility source in tests.
- **Database/Index Changes:** Not applicable; Wi-Fi readings are transient and do not enter usage snapshots or shared storage.
- **Feature Flags / Config Switches:** Link/import Apple's CoreWLAN framework through the generated host target. Preserve App Sandbox; no new permission, network exception, helper process or package is required for the client-vended interface read path. Do not add location entitlements or usage descriptions.
- **Seed / Fixture Requirements:** Valid/mixed/sentinel readings, no interfaces, nil/error discovery, powered-off state where reliably reported, missing channel, changing interface and delayed refresh after hiding/closing.
- **Required Reusable Utilities:** Use the app composition root and utility window's selection/visibility lifecycle; reuse `UtilityPanel`, `UtilityValueRow`, `UtilityInfoTooltip`, `UtilityStyle`, `handPointer()` and existing injected dependency conventions.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** No network test endpoint. When Connection becomes visible, read the default Wi-Fi interface through one long-lived `CWWiFiClient`; refresh every five seconds while that surface remains visible. Stop refresh when hidden, another section is selected, the window closes or the app terminates. Re-entering performs one immediate fresh read. Coalesce overlapping refresh requests.
- **Request Schema:** No user-controlled interface/network identifier. Use the client instance’s `interfaceNames()` (macOS 13+) or `interfaces()` to distinguish discovery nil/error from a known empty list, then obtain its default interface with `interface()`; a nil default after successful nonempty discovery means no readable default interface, not proof that the hardware is absent. Obtain all interface objects from that client; never initialize `CWInterface` directly. Use the client's default interface and label its BSD interface if needed. Its presence does not mean the internet's active route uses Wi-Fi; Ethernet/VPN paths can coexist.
- **Response Schema:** A Sendable value snapshot contains `sampledAt`, optional interface identifier, optional RSSI dBm, noise dBm, channel number/band/width and transmit Mbps, plus a typed availability state. Reading state is separate from the values. Preserve unknown future channel bands/widths as Unknown/Not Available rather than inventing mappings.
- **Validity Contract:** CoreWLAN documents zero RSSI/noise/transmit values as error/no-network sentinels; they are absent readings, never 0 dBm or 0 Mbps quality. Accept physically meaningful negative RSSI/noise and finite positive link rates without speculative score thresholds. Channel can be nil; preserve valid other readings. Interface discovery nil/error differs from a known empty interface list. The API cannot distinguish every disconnected/error case: use Wi-Fi Readings Unavailable when the cause is ambiguous. Clear the previous snapshot on a failed/disconnected refresh and during a new interface transition so stale values are not presented as current.
- **Concurrency Contract:** One serial worker owns the long-lived CWWiFiClient and all CWInterface references. Pass immutable values across that boundary to the MainActor presentation monitor. Do not create clients per poll, block the UI with overlapping reads, move CoreWLAN objects between detached tasks or invent unchecked Sendable conformances. Match the actual SDK annotations and the project's default actor isolation explicitly. Late results from an old visibility generation cannot republish after stop/hide/close.
- **Privacy And Read-Only Contract:** Never call `ssid`, `ssidData`, `bssid`, scanning, association, power/channel mutation or profile APIs. Do not infer the Wi-Fi name from other system stores. No location prompt is part of this feature. No reading leaves the app or is retained after app termination.
- **Measurement Boundary:** Label transmit rate Wi-Fi Link Rate in Mbps. It is the interface's current link transmit rate, separate from live byte-counter throughput and measured internet capacity. RSSI/noise/channel are local-link observations, not proof that a provider, router or internet service is healthy.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** Add a Wi-Fi Quality panel in Connection with Signal (dBm), Noise (dBm), Channel (including available band/width) and Wi-Fi Link Rate (Mbps). Use shared full-width aligned value rows. Keep the panel distinct from internet and stability results without introducing another sidebar section.
- **Explanations:** Place a compact info icon after the heading, following the current diagnostic info-tooltip convention. In simple English explain that stronger signal is closer to zero, lower noise is quieter, and the link rate describes Wi-Fi rather than a measured internet transfer. State that readings can still describe Wi-Fi while the internet uses another interface. Avoid a large explanatory container or invented percentage/quality rating.
- **Status:** Show a concise observation timestamp and meaningful unavailable/adapter state. Display Not Available for a missing metric when other readings exist. When all metrics are absent, render a short useful state instead of blank rows or an empty card. Refreshing this passive panel does not activate the diagnostic Cancel footer or block explicit internet/stability tests.
- **System Behavior Change:** One host-owned monitor manages passive visibility sampling independently of the diagnostic run task; it adds no persistent collection loop while the window is closed. Immediate refresh after wake/visibility recovery clears stale context.
- **Error States To Support:** No default Wi-Fi interface, Ethernet-only connectivity, Wi-Fi power off if positively known, missing channel, API failure/sentinel metrics, interface replacement, hide/close during an in-flight read and unknown SDK enum values.
- **Accessibility / Platform Constraints:** All metrics have explicit units and combined accessible labels/values. Use shared adaptive section layout, Title Case, tooltips and light/dark styling at 620 × 420, default and expanded sizes. Preserve current sidebar shortcuts, popover, Usage and diagnostic results.

## 8. Acceptance Criteria

- The signed sandboxed app reads supported CoreWLAN metrics on the target Mac without a Location prompt or a sandbox exception.
- Readings use client-vended interfaces, one client and one bounded visible refresh loop; hidden/closed/terminated surfaces stop work and suppress late updates.
- Sentinel, missing and unknown readings remain unavailable and cannot masquerade as real zeros or stale measurements.
- Wi-Fi Link Rate and internet speed remain distinguishable; coexistence with Ethernet/VPN is described without assuming the Wi-Fi interface carries internet traffic.
- No network scan/configuration/identity call or persistence is introduced. Existing rate collection, history, quick/load checks and stability cancellation continue to work.

## 9. Implementation Steps (Component Audit)

### A. Platform Reader And State

- [NEW] `MacUtilities/Platform/Networking/WiFiQualityReader.swift`:
  - **Target Anchor:** No CoreWLAN adapter currently exists; `InterfaceCounterReader` and `NetworkInterfaceLabel` move beside it in Phase 08 but serve different measurement contracts.
  - [ ] Implement serial client ownership, default-interface discovery, value-only capture and sentinel handling. Return typed unavailable states without calling identity or configuration APIs. Preserve partial valid readings and explicit unknown channel values.
- [NEW] `MacUtilities/Features/Connection/WiFiQualityMonitor.swift`, `Models/WiFiQualityModels.swift`:
  - [ ] Implement visibility-driven immediate/five-second refresh, at most one in-flight read, generation-gated updates, state clearing, observer/task cleanup and injectable readers/clocks. Keep passive state independent from `ConnectionDiagnostics.Activity`.

### B. Composition And Shared Presentation

- [MODIFY] `MacUtilities/App/Mac_UtilitiesApp.swift`, `App/AppDelegate.swift`, `App/UtilityWindow.swift`:
  - **Target Anchor:** Existing app-lifetime StateObjects, environment injection, selected `UtilitySection`, window presentation/close and application shutdown.
  - [ ] Own one Wi-Fi monitor and drive one explicit visibility predicate: Connection selected, utility window shown, app not hidden, window not miniaturized and its occlusion state contains visible. Observe window miniaturize/deminiaturize and occlusion-state notifications, app hide/unhide, selection and close, plus NSWorkspace.didWakeNotification. A false predicate stops/cancels the loop and invalidates its generation; a false→true transition performs one immediate read. Wake invalidates the old generation and performs a fresh read only if the predicate is true. Ignore notifications for other windows and unregister at teardown. View onAppear alone must not own polling. Stop passive refresh at close/quit while retaining existing diagnostic semantics.
- [NEW] `MacUtilities/Features/Connection/WiFiQualityView.swift`; [MODIFY] `ConnectionCheckView.swift` and `MacUtilities/UI/UtilityStyle.swift`:
  - [ ] Render the distinct panel/tooltip, optional metric rows and meaningful empty state. Put new style constants centrally only when required. Keep status/Cancel and explicit check actions independent from passive Wi-Fi refresh.

### C. Tests And Documentation

- [NEW] `Mac UtilitiesTests/Connection/WiFiQualityTests.swift`; [MODIFY] `Mac UtilitiesTests/Window/UtilityWindowTests.swift`:
  - [ ] Test sentinel/partial/unknown formatting, interface errors, state clearing, one in-flight operation, visibility cadence and every predicate transition, unrelated-window events, stale callbacks after hide/wake, close/quit and independence from an active stability/load check. Use value fixtures rather than requiring a specific router or signal level in automated tests.
  - [ ] Extend existing injected lifecycle tests for passive refresh without changing the host app's activation policy or real network settings.
- [MODIFY] `project.yml`, PRD, development standards and workflow during implementation:
  - [ ] Register sources/CoreWLAN membership in the host only. Document privacy, metric limits, polling ownership and verified target behavior; do not add Wi-Fi readings to the usage-only widget contract.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Synchronous framework calls, sentinel zeros and stale interface handles can produce misleading readings; serialize the reader and validate before publishing. Avoid changing OS state to make a metric available.
- **Operational Risks:** Metrics vary by hardware/OS and may be unavailable even while internet access works. CoreWLAN does not provide a definitive explanation for every absent metric. Network/route changes need not imply the wireless interface itself changed.
- **Rollback Approach:** Remove the passive monitor/panel and generated CoreWLAN source membership. No persistent migration, network configuration or permission rollback is required.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-wifi CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Targeted Tests:** WiFiQualityTests and UtilityWindowTests, followed by the existing suite once after integration. Tests use injected temporary storage from Phase 08 and a fake Wi-Fi reader.
- **Signed Build:** Same project/scheme/destination with `-configuration Release build` and Phase 08's verified local signing configuration; omit ad-hoc overrides for production group access. Inspect signature/entitlements and test the actual signed sandboxed app.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Connected Wi-Fi | Open Connection on the target Mac | Available metrics/units update without permission prompt or diagnostic traffic | Signed native inspection |
| Partial / Unavailable | Inject sentinel/missing/no-interface cases | Correct optional/state UI; previous values clear | Reader/model tests |
| Visible / Hidden | Navigate, hide, close, wake and reopen | One refresh loop; no hidden polling; immediate fresh read on return | Lifecycle tests/native check |
| Concurrent Diagnostic | Run quick/load/stability work with Wi-Fi visible | Passive readings coexist; diagnostic activity and Cancel remain correct | Controller/window tests |
| Link Comparison | Compare readings at two ordinary positions if practical | Values change naturally; no health guarantee or internet-speed claim | Optional target observation |
| Compact / Accessible | Render fixtures at supported sizes and appearances | No clipping/empty containers; units and unavailable states accessible | Native fixture inspection |

### C. Evidence To Capture

- Tests/build and SDK API/entitlement evidence, including absence of location permission requests and identity API calls.
- Signed target readings, optional unavailable behavior and passive-task cleanup. Do not commit network identifiers or personal location data.
- Source/dependency review proving CoreWLAN is host-only and widget source membership remains read-only usage code.

## 12. Execution Notes

- **Status:** Planned
- **Started At:** Not started
- **Completed At:** Not completed
- **Blockers Encountered:** Phase 08 source layout/ownership must be complete; runtime CoreWLAN visibility/privacy checks remain implementation gates.
- **Notes:** A five-second visible-only refresh and omission of Wi-Fi identity are the recommended defaults. No Wi-Fi API, permission, app source or test was changed during plan creation.
