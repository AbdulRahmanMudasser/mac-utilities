# Mac Utilities - Product Requirements Document

## 1. Document Purpose

This document is the product source of truth for Mac Utilities. It defines the product goals, intended users, scope, requirements, and acceptance expectations for its macOS network-usage monitor.

Use this file for product goals, user needs, feature scope, acceptance expectations, and platform rules. It does not define repository structure, code-level tasks, or signing and deployment runbooks.

## 2. Executive Summary

* **Product Name:** Mac Utilities
* **One-Sentence Summary:** A native macOS menu bar app that reports live network speeds, today's device-wide data use, and the five apps that have transferred the most data today.
* **Problem Statement:** macOS does not provide a compact, at-a-glance view that combines current network rates with daily totals and per-app usage. Users need to understand what is using the network and how much data has moved without interrupting their work.
* **Target Audience:** The owner of the target MacBook, using a personal developer-installed build.
* **Primary Outcome:** The user can see accurate observed upload and download activity, daily totals, and the leading app-level contributors from the menu bar, with clear collection status and limitations.

## 3. Goals And Non-Goals

### Goals

- Show current device-wide download and upload rates in the macOS menu bar and usage popover.
- Accumulate device-wide and per-app download and upload bytes for the MacBook's current local calendar day.
- Rank the top five apps by combined observed bytes, with stable ordering when usage is tied or nearly tied.
- Persist the current day's aggregate counters across app and monitoring-extension restarts and reset them at local midnight.
- Make active, paused, setup-required, and incomplete-collection states visible so users can interpret totals correctly.
- Allow traffic through normally while observing it locally.

### Non-Goals

- Blocking, shaping, modifying, proxying, or inspecting the contents of network traffic.
- Historical reports, multi-day analytics, exports, cloud sync, or account-based features.
- Cross-device, cross-Mac, or Windows/Linux support.
- Identifying every device byte as belonging to an app; system-level and app-flow measurements may differ.
- App-store distribution or production deployment to unsupervised devices unless platform requirements permit it.

## 4. Business Context

* **Why Now:** The project is intended to provide a focused, personal utility for understanding live network activity and daily data use on the target MacBook.
* **Current Pain Points:** Built-in macOS views do not combine live interface rates, local-day totals, and a ranked per-app breakdown in a persistent menu bar surface. Existing counts can also be misleading when monitoring is not active or app attribution is incomplete.
* **Business Value:** Personal visibility into bandwidth use and a practical native macOS project foundation. No commercial or subscription outcome is targeted.
* **Constraints:** The target is this MacBook running macOS 26.6.2 on arm64. The design uses SwiftUI with AppKit integration, a Network Extension content filter with data and control providers, and shared app-group storage. Apple documents production Network Content Filter restrictions in [NEFilterManager](https://developer.apple.com/documentation/networkextension/nefiltermanager) and setup guidance in [Configuring Network Extensions](https://developer.apple.com/documentation/xcode/configuring-network-extensions): production configurations are restricted to supervised devices, while development and testing builds may use a `get-task-allow` entitlement override. Developer signing, capabilities, installation, and the feasibility of that override on this MacBook must be confirmed before treating full monitoring as available.

## 5. Target Users And Roles

### Primary Users

- **User Type:** MacBook owner
  - **Needs:** Check live upload/download rates, understand how much data has moved today, see which apps account for the most observed traffic, and know whether collection is complete.
  - **Pain Points:** Network usage is spread across system views, and app-level attribution can be unavailable or incomplete without a clear monitoring status.

### Secondary Users

- **User Type:** Developer maintaining the personal app
  - **Needs:** Confirm the Network Extension is enabled, start or pause collection, manage local preferences, and validate the app's behavior on the target Mac.
  - **Pain Points:** Network Extension signing and device restrictions may prevent the intended monitoring flow from being enabled in a local build.

## 6. User Journeys

### Journey 1: Check current activity

1. The user glances at the menu bar while working.
2. The menu bar item shows current download and upload rates, updated about once per second.
3. The user opens the item to see total rates, today's totals, and the leading apps.
4. The user closes the popover; collection continues in the background while monitoring remains active.

### Journey 2: Investigate daily app usage

1. The user opens the usage popover.
2. The app shows today's device download, upload, and combined totals.
3. The app lists up to five apps ranked by combined bytes observed since local midnight, including each app's icon, current rates, and daily byte totals.
4. Any traffic without a usable displayed-app identity appears under System/Unattributed.
5. When counts are incomplete, paused, or awaiting setup, the app communicates that state alongside the totals.

### Journey 3: Manage monitoring and display preferences

1. The user opens settings.
2. The user checks whether macOS has enabled the monitoring component and sees the current collection state.
3. The user pauses or resumes monitoring, changes speed and data units, or enables/disables start at login.
4. When the user resets today's counters, the app clears the current-day device and app aggregates and begins counting observed bytes again.

## 7. Feature Scope

### In Scope

- Native macOS menu bar item with current upload and download rates, refreshed approximately once per second.
- Compact popover showing device-wide current rates, today's downloaded/uploaded/combined totals, and up to five ranked apps.
- Per-app name and icon, current download/upload rates, and daily download/upload/combined totals.
- System/Unattributed category for observed flow bytes without a displayed app identity.
- Device-level network counters for overall activity and Network Extension flow reports for app attribution.
- Local calendar-day rollover, local persistence of the current day's aggregates, and stable top-five tie handling.
- Active, paused, setup-required, and incomplete-collection status indicators.
- Settings for start at login, pause/resume, rate units, data units, today's counter reset, and monitoring-component status.
- Local-only collection of app identity and byte counts; traffic is allowed through without modification.

### Out Of Scope

- Packet payload capture, browsing history, domains, URLs, content inspection, or traffic classification.
- Network controls such as firewall rules, parental controls, throttling, or blocking.
- Long-term history, charts, remote dashboards, syncing, sharing, or telemetry upload.
- A generalized installer, managed fleet deployment, or public app-store release in the initial version.
- Supporting Macs beyond the named MacBook and its installed macOS version/architecture.

## 8. Platform Scope

Use the standard repository root folder names when describing platform surfaces:

- `web/` for the web application — not applicable.
- `backend/` for the backend service layer — not applicable; there is no backend.
- `mobile/` for the mobile application — not applicable.

* **Backend Service:** None. All monitoring and aggregation are local to the MacBook.
* **Web Application:** None.
* **Mobile Application:** None.
* **Other Surfaces:** A native macOS menu bar application and settings window, implemented with SwiftUI and AppKit integration, plus Network Extension data and control providers. Current-day aggregate counters are shared locally through app-group storage.

## 9. Functional Requirements

- **FR-1 Live speed:** Show current total inbound and outbound rates in the menu bar and popover. Calculate rates from byte-count deltas over elapsed time and refresh the visible rate about once per second. Inbound bytes are downloads; outbound bytes are uploads.
- **FR-2 Background collection:** Continue collecting while the popover is closed whenever monitoring is active.
- **FR-3 Daily device totals:** Accumulate downloaded, uploaded, and combined device-level bytes for the MacBook's current local calendar day. Use device counters for these totals.
- **FR-4 App attribution:** Use macOS Network Extension per-flow reports and the [source app identifier](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappidentifier) to attribute inbound and outbound observed bytes to apps, using the [flow byte reports](https://developer.apple.com/documentation/networkextension/nefilterreport). Count flows without a usable app identity as System/Unattributed.
- **FR-5 Ranked apps:** Show up to five apps with the largest combined observed bytes for the current day. Each row includes app name and icon, current download and upload rates, and today's download, upload, and combined totals. Keep ordering stable when app totals are tied or close enough that rate/report timing would otherwise cause unnecessary visual movement; use a deterministic tie-breaker and retain prior order for ties where possible.
- **FR-6 Measurement distinction:** Keep device-level totals and per-flow attribution totals distinct. The interface must not imply that all device bytes have been attributed to displayed apps. Show System/Unattributed app-flow bytes separately.
- **FR-7 Local-day boundary:** Use the MacBook's local calendar and time zone. On local midnight, begin a new day's totals. Handle time-zone and daylight-saving changes using local calendar boundaries rather than a fixed 24-hour timer.
- **FR-8 Persistence:** Preserve the current day's device and app aggregate counters across app and extension restarts using local shared app-group storage. Do not require a network service or account.
- **FR-9 Collection state:** Clearly identify whether monitoring is active, paused, needs setup, or has an incomplete collection interval. Paused or unavailable intervals must not be presented as fully observed usage.
- **FR-10 Controls and preferences:** Provide start-at-login on/off, monitoring pause/resume, Mbps or MB/s rate display, MB/GB or MiB/GiB data display, reset-today control, and a visible indication of whether macOS enabled the monitoring component.
- **FR-11 Traffic behavior and privacy:** Allow observed traffic through unchanged. Collect app identity and byte counts needed for usage totals, and store current-day aggregates locally on this MacBook.

## 10. Acceptance Criteria

- The menu bar displays both current download and upload rates and updates approximately once per second while active.
- Closing the popover does not stop collection; total rates and counters continue to advance while monitoring remains active.
- The popover displays device-wide current rates and today's download, upload, and combined totals.
- The app list contains no more than five apps and is ordered by current-day combined per-flow bytes; each row has the required identity, icon, live rates, and totals.
- Unidentified flow bytes are counted under System/Unattributed, and app-attributed totals are not presented as equal to device totals by implication.
- Equal usage totals do not cause repeated arbitrary reorderings of the top-five list.
- Counters are scoped to the local calendar day, survive app and extension restarts, and roll over at local midnight.
- Paused, setup-required, and interrupted collection states are visible, with totals identified as incomplete when collection was not continuous.
- Settings expose all specified controls and show whether macOS has enabled the monitoring component.
- Observed traffic continues to pass without the app blocking or modifying connections.
- The developer-installed build runs on the target MacBook. Full monitoring is considered verified only after signing, capability, installation, and device policy requirements are confirmed and the component reports enabled.

## 11. Success Metrics

* **Primary Metric:** The target MacBook displays live device rates and a correctly updated current-day usage summary during an active monitoring session.
* **Secondary Metrics:**
  - Top-five app ranking matches accumulated observed per-flow byte counts.
  - Current-day counters survive app and extension restarts and reset at local midnight.
  - The app visibly distinguishes active collection from paused, setup-required, or incomplete periods.
  - Network traffic continues to pass normally while monitoring is active.
* **Measurement Window:** Functional verification during local development and personal use on the target MacBook. No analytics telemetry is collected.

## 12. Assumptions

- The app is for one user's personal use on one target MacBook.
- The supported target is this MacBook on macOS 26.6.2 and arm64; no other Mac compatibility target is required.
- The user can install and run a developer-signed local build and grant the required macOS approval for its monitoring component.
- System network counters are available to the app for overall activity, while the content filter supplies per-flow app attribution where macOS provides an app identifier.
- Current-day aggregates are sufficient; historical daily records are not required.
- The selected display units affect presentation only, not stored byte counts or ranking.

## 13. Dependencies

- Xcode and a compatible macOS SDK installed on the target MacBook.
- Apple developer signing and Network Extension capability setup for both app and extension targets.
- A shared app group configured consistently for the app and extension.
- macOS approval and policy support for enabling the Network Content Filter on the target MacBook.
- Network Extension reports that provide per-flow source app identifiers and inbound/outbound byte counts.
- Device-level interface counters for total network activity.

## 14. Risks And Open Questions

### Risks

- Production Network Content Filter configurations are restricted to supervised devices; development/testing overrides and entitlement behavior may vary by Xcode, signing identity, macOS version, and installation path. The target MacBook's exact setup must be validated before relying on full collection.
- Device-level counters and per-flow reports represent different measurement sources and may not reconcile exactly.
- Some traffic may have no app identifier, so app attribution is inherently incomplete.
- Extension restart, system sleep, interface changes, local clock changes, or permission changes can create unobserved intervals; these must be reflected in collection status and totals.
- Resolving source app identifiers to stable app names and icons may fail for deleted, sandboxed, system, or otherwise unavailable apps.

### Open Questions

- Does the target MacBook accept a developer-signed Network Content Filter under its current macOS policy, and which signing workflow will be needed?
- Which signing identity and provisioning setup will be used, and can the development/testing entitlement override enable the filter on this MacBook?
- Should the app show decimal MB/GB and binary MiB/GiB with clearly labeled units (default), or provide another default preference?
- What tolerance should be used to reconcile device-level counters with per-flow totals for diagnostic purposes?

## 15. Cross-Platform Contracts

* **Shared Data Models:** No cross-platform models are required. Within the app, counters are byte-based and include a local calendar-day key, direction (inbound/download or outbound/upload), source category (device, identified app, or unattributed flow), and collection status metadata.
* **Sync Model:** None. The app and extension share current-day aggregates locally through the configured app group. Updates must tolerate app or extension restarts and avoid treating a partially written snapshot as valid.
* **Identity Model:** App identity is the source application identifier supplied by macOS for a flow, resolved locally to a display name and icon when possible. Missing or unresolved identities map to System/Unattributed.
* **Failure Expectations:** If the extension is disabled, permission is missing, or collection is interrupted, show a setup-required or incomplete status and do not imply full-day coverage. Device-wide and flow-attributed totals remain visibly separate if they differ.

## 16. Security And Compliance

* **Access Rules:** Only the local Mac user and the app's authorized Network Extension may access the monitoring aggregates through the app-group container.
* **Sensitive Data Handling:** Store only the app identity and byte aggregates required for current-day usage. Keep data on this MacBook; do not upload or sync it. Do not collect packet payloads, destinations, or browsing content.
* **Legal Or Policy Requirements:** Follow Apple's Network Extension entitlements, signing, supervision, and installation requirements for the target build. The app must permit traffic to pass without blocking or modification and must clearly indicate when monitoring is unavailable.

## 17. Release And Rollout Notes

* **Release Strategy:** Begin with a developer-installed local build on the target MacBook. Enable full monitoring only after confirming signing, capability, user approval, and device policy support. No public distribution is planned for the initial version.
* **Rollback Strategy:** The user can pause monitoring, disable/remove the monitoring component through the app or macOS settings, and quit or remove the local app. Any removal flow should make the effect on ongoing monitoring clear.
* **Support Readiness:** Before relying on daily totals, verify menu bar rates, popover totals and ranking, restart persistence, midnight rollover, incomplete-collection messaging, and normal traffic passage on the target MacBook. Document the local signing and component-approval steps for this personal installation.
