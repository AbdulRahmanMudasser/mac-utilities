# Phase 01 - Device Usage Counters

## 1. Phase Purpose

Implement device-wide live-rate measurement and persistent current-local-day device totals for the first release.

## 2. Feature Objective

- **Phase Goal:** Read device interface byte counters, calculate live inbound/outbound rates, and preserve device totals across app restarts.
- **User Or System Outcome:** The app can report today's device download, upload, and combined bytes plus current total rates without depending on the popover being open.
- **In Scope:** One-second device-counter sampling while monitoring is active, local-day rollover, restart-safe local Application Support persistence, and focused persistence/state verification.
- **Out Of Scope:** Per-flow app attribution, filter activation, menu-bar formatting, settings controls, and multi-day history.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow Log](./execution-workflow.md)
- **Product Source:** [Mac Utilities PRD](../mac-utilities-prd.md)
- **Prerequisites (Blocked By):** Phase 00 must be Completed and the root-level Xcode project must build.
- **Downstream Tasks (Unlocks):** Phase 03. Phase 02 is deferred and is not a dependency.
- **Target Git Commit Prefix:** feat(desktop-scope): ...
- **Project Profile(s):** Native macOS desktop application; system network-interface counters; local host-app persistence.
- **Applicable Development Standards:** Codex fallback baseline `check-implementation/references/common-baseline.md`; no repository-specific standards or more-specific native desktop baseline were found.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Sections 3, 6, 7, 9, 10, 11, 12, 13, and 15.
- **Related Build Plan Section:** Not applicable; no build plan is maintained in this repository.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** Not applicable.
- **Database/Index Changes:** Extend the existing `PersistedUsage` model in `MacUtilities/Monitoring/UsageMonitor.swift`. It stores device totals and interface baselines as an atomic JSON file in this app's local Application Support directory.
- **Feature Flags / Config Switches:** Monitoring active/paused status comes from the device-counter sampler; do not report active collection when sampling is stopped or unavailable.
- **Seed / Fixture Requirements:** Unit tests need synthetic interface counter snapshots and timestamps for counter growth, reset, and rollover cases.
- **Required Reusable Utilities:**
  - Extend the existing `UsageMonitor`, `PersistedUsage`, and `InterfaceCounterReader`; do not introduce a second sampler or store.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** Not applicable; no network service API is introduced.
- **Request Schema:** Not applicable; no network service request is introduced.
- **Response Schema:** Not applicable; no network service response is introduced.
- **Local Contract:** Persist a schema version, local calendar day key and time-zone identifier, device inbound/download and outbound/upload byte totals, per-interface 64-bit baselines, latest sample time, monitoring state, and incomplete-collection marker. Combined bytes are derived. The app stores this state atomically in local Application Support; no provider shares the store in the first release.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** Device totals and total upload/download rates become available to the menu-bar surfaces in Phase 03.
- **System Behavior Change:** Sampling continues while the menu popover is closed whenever monitoring is active.
- **Error States To Support:** Unavailable interface counters, non-monotonic wall-clock timestamps, interface changes, counter decreases, sleep/wake gaps, and local-date changes must not create negative or duplicated byte increments. A missing legacy time-zone identifier is established from the Mac's autoupdating system zone; only a known identifier change marks the same-day collection partial. Both obsolete time-zone uncertainty messages migrate to `Today's Usage Includes An Incomplete Previous Collection.` without changing byte totals or claiming current detection failed. The stored partial marker describes coverage of today's count, independently of current time-zone detection.
- **Accessibility / Platform Constraints:** Use local calendar boundaries and current system time zone, including daylight-saving changes; do not assume a fixed 24-hour day.

## 8. Acceptance Criteria

- Inbound and outbound interface-byte deltas accumulate as device downloads and uploads respectively.
- Rates are computed from byte deltas divided by measured elapsed time, with the visible sample refreshed about once per second.
- Interface selection avoids loopback and duplicate accounting across a physical interface and its virtual/tunnel representation.
- Current-day device counters persist in local Application Support and reset when the local calendar day key changes.
- Atomic local snapshot writes do not expose partially written state.
- A reset, unavailable sample source, or monitoring interruption cannot be shown as a complete count.

## 9. Implementation Steps (Component Audit)

### A. Project And Data Layer

- [MODIFY] MacUtilities/Monitoring/UsageMonitor.swift:
  - **Target Anchor:** Existing `PersistedUsage`, `UsageMonitor.init()`, `InterfaceCounterReader.read()`, `UsageMonitor.sample()`, `UsageMonitor.applyDelta(from:to:in:)`, and `UsageMonitor.saveState(force:)`.
  - [x] Persist the local time-zone identifier in the current-day state.
  - [x] Verify that a known time-zone change with the same local-day key marks the count incomplete; establish a missing legacy identifier without reporting a change, and migrate the prior ambiguous warning while preserving the partial marker.
  - [x] Use monotonic system uptime for live-rate elapsed time; wall-clock time remains responsible for local-day keys and persisted timestamps.
  - [x] Keep the reader limited to physical `enN` interfaces; exclude loopback and virtual/tunnel interfaces, and retain 64-bit baselines.
  - [x] Keep one-second live sampling while limiting durable writes; count restart catch-up only when persisted interface counters remain monotonic.
- [NEW] `Mac UtilitiesTests/UsageMonitorTests.swift` and a macOS test target:
  - **Target Anchor:** Existing `UsageMonitor` counter and persistence behavior.
  - [x] Cover download/upload direction, elapsed-time rates, interface-counter decrease/set changes, atomic snapshot persistence, local midnight/DST rollover, known same-day time-zone changes, missing legacy identifiers, and migration of the prior ambiguous warning.

### B. Monitoring Layer

- [MODIFY] MacUtilities/Monitoring/UsageMonitor.swift:
  - **Target Anchor:** Existing `UsageMonitor.startSampling()`, `UsageMonitor.sample()`, `UsageMonitor.setPaused(_:)`, and local-day key calculation.
  - [x] Keep sampling tied to app lifetime rather than popover visibility; rebaseline after pause and mark the current day partial.
  - [x] Reset at the Mac's local calendar boundary without a fixed 24-hour timer; cover time-zone changes and daylight-saving transitions.

### C. Client / UI Layer

- Not applicable: Phase 03 owns visible menu-bar and popover changes; this phase exposes a snapshot API only.

### D. Tests And Configuration

- [MODIFY] MacUtilities.xcodeproj/project.pbxproj:
  - **Target Anchor:** Existing app scheme and target list.
  - [x] Add a macOS unit-test target for counter/store tests without changing the app target's existing scheme identity.
- [NEW] MacUtilities.xcodeproj/xcshareddata/xcschemes/Mac Utilities.xcscheme:
  - **Target Anchor:** Shared Xcode scheme required for repeatable command-line test selection after the test target is added.
  - [x] Include the app and macOS test target in the shared scheme so the documented build/test commands resolve consistently.
- No Network Extension or app-group target configuration is required for the device-only release.

## 10. Risks And Rollback Notes

- **Implementation Risks:** macOS interface statistics may include multiple interface layers; an incorrect set can double count, miss a route change, or include loopback traffic.
- **Operational Risks:** A failed local store write or sampler gap must not erase already persisted totals.
- **Rollback Approach:** Stop the sampler and retain the last valid current-day snapshot; do not delete local counter data automatically during rollback.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-final CODE_SIGNING_ALLOWED=NO test`.
- **Targeted Tests:** Thirteen passing `UsageMonitorTests` cases for byte direction, rates, reset and interface changes, local-day/DST rollover, known and missing time-zone identifiers, both legacy-warning migrations, idempotence and counter preservation, persistence, invalid snapshots, and display units.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Traffic increase | Generate known inbound and outbound traffic while monitoring is active | Device byte counters advance in the matching directions and rates reflect elapsed-time deltas | Test output and target-Mac snapshot |
| App restart | Relaunch the app on the same local day | Previously stored device totals remain and collection resumes with a fresh rate baseline | Before/after snapshot |
| Local midnight | Apply a sample across the local day boundary | The current snapshot rolls to the new local day with zero totals and a fresh interface baseline; the product does not retain historical daily analytics | Rollover test output |
| Legacy time-zone state | Load same-day snapshots containing either obsolete time-zone warning | The Mac's current zone is used; old warnings become a collection-coverage explanation and repeated migration preserves totals and partial state | Thirteen-test suite passed; installed Settings displayed Asia/Karachi (GMT+5), matching the laptop's system time zone |
| Sampling gap | Disable the source, sleep/wake, or change the active interface | Rates rebaseline without negative spikes and the snapshot indicates incomplete collection | State test output |
| Interface overlap | Exercise physical plus virtual/tunnel interfaces | The selected device total does not count the same traffic twice | Recorded interface-counter comparison |

### C. Evidence To Capture

- Thirteen-test `xcodebuild test` result.
- Target-Mac app launch with live rates and persisted interface/day counters.
- The documented interface selection rule and known system-counter limitations.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-13
- **Completed At:** 2026-10-13
- **Blockers Encountered:** None for the device-counter implementation scope. Target install/signing and broader real-transfer validation are tracked in Phase 04.
- **Notes:** `MacUtilities/Monitoring/UsageMonitor.swift` reads 64-bit physical `enN` interface counters, samples on a one-second timer, computes rates from monotonic elapsed time, and stores current-day device totals plus interface baselines in an atomic local JSON file. Schema version 2 records the local time-zone identifier and marks a known same-day time-zone change incomplete. Missing legacy metadata no longer counts as evidence of a change. Both obsolete warnings migrate to a collection-coverage explanation without erasing totals or claiming full-day coverage. Thirteen tests cover rollover, real time-zone transitions, and repeated legacy migration. The installed app displayed the Mac's Asia/Karachi (GMT+5) system zone and preserved today's counters across rebuilds and restarts. App-group storage is intentionally out of scope for this release.
