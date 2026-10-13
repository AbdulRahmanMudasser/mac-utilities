# Mac Utilities - Product Requirements Document

## 1. Document Purpose

This document is the product source of truth for Mac Utilities. It defines what the product delivers, who it serves, what is in scope, and how success is judged.

Use this file for product goals, user needs, feature scope, acceptance expectations, and platform rules. Use `hl-docs/desktop/` for delivery sequencing and phase evidence. This file does not define repository layout, code-level tasks, or signing runbooks.

## 2. Executive Summary

* **Product Name:** Mac Utilities
* **One-Sentence Summary:** A native macOS menu bar utility that shows live device-wide network speeds and today's downloaded and uploaded data totals.
* **Problem Statement:** macOS does not provide the owner with a compact, persistent view of current network rates and local-day data use. The app makes those device-wide measurements available at a glance without changing network traffic.
* **Target Audience:** The owner of the target MacBook, using a personal developer-installed build.
* **Primary Outcome:** The user can see current inbound and outbound rates, understand today's observed device-wide traffic, and check current monitoring readiness in Settings.

## 3. Goals And Non-Goals

### Goals

- Show current device-wide download and upload rates in the menu bar and usage popover, refreshing about once per second.
- Accumulate today's device-wide download, upload, and combined byte totals using the MacBook's local calendar day.
- Preserve the current day's totals through an app restart and reset them at local midnight.
- Continue sampling while the popover is closed when monitoring is active.
- Identify current active, paused, and unavailable states in a dedicated Settings Readiness section.
- Store only local aggregate counters and allow network traffic through normally.

### Non-Goals

- Per-app usage, app identity collection, app ranking, or System/Unattributed flow totals in the initial release. The app does not show a deferred-attribution placeholder.
- Blocking, shaping, modifying, proxying, or inspecting the contents or destinations of network traffic.
- Process estimates from diagnostic tools such as `nettop` as a substitute for measured flow attribution.
- Historical analytics, exports, cloud sync, accounts, or remote telemetry.
- Cross-device, cross-Mac, or Windows/Linux support.
- Public App Store distribution or production deployment beyond the target MacBook.

## 4. Business Context

* **Why Now:** The project provides a focused personal utility for understanding live network activity and daily data use on the target MacBook.
* **Current Pain Points:** Built-in macOS views do not combine live interface rates, local-day device totals, and a persistent menu bar presentation. Counts can also mislead users if paused or missing collection periods are not disclosed.
* **Business Value:** Personal visibility into bandwidth use and a practical native macOS project foundation. No commercial or subscription outcome is targeted.
* **Constraints:** The target is this MacBook running macOS 26.6.2 on arm64. The first release uses device-level interface counters and local app storage. The user selected the lower-impact device-counter approach without a proxy, `nettop` estimates, or in-path payload sampling. macOS exposes flow-report and source-audit-token APIs, but the documented flow byte totals are nonzero only when a flow closes; live per-app rates would require sampling data as it passes through a content filter. That path has not been validated end to end on this MacBook and is deferred. The personal local build uses an ad-hoc signature; Developer ID signing and notarization are not release goals.

## 5. Target Users And Roles

### Primary Users

- **User Type:** MacBook Owner
  - **Needs:** Check current upload/download rates, understand how much data has moved today, and know whether collection has gaps.
  - **Pain Points:** Network activity and daily totals are not presented together in a persistent, compact surface.

### Secondary Users

- **User Type:** Developer Maintaining The Personal App
  - **Needs:** Build and run the app on the target MacBook, confirm device-counter availability, and verify persisted daily totals.
  - **Pain Points:** Interface counters can reset or change with network state, and local sampling can be interrupted by pause, app termination, sleep, or system changes.

## 6. User Journeys

### Journey 1: Check Current Activity

1. The user glances at the menu bar while working.
2. The menu bar item shows current device-wide download and upload rates, updated about once per second.
3. The user opens the item to see current rates and today's device download, upload, and combined totals.
4. The user closes the popover; sampling continues while monitoring remains active.

### Journey 2: Understand Collection Coverage

1. The user opens the popover or Settings.
2. The app shows whether device counters are available and whether monitoring is active or paused.
3. The app displays observed totals without a Partial badge or historical pause messages; current status and local time zone appear in Settings Readiness.

### Journey 3: Manage Monitoring And Display Preferences

1. The user opens Settings.
2. The user pauses or resumes device monitoring, changes speed and data units, or enables/disables start at login.
3. When the user resets today's counters, the app clears the current-day device totals and begins a new observed count.

## 7. Feature Scope

### In Scope

- Native macOS menu bar item with current device-wide upload and download rates, refreshed approximately once per second.
- Compact popover with current device rates and today's downloaded, uploaded, and combined device totals.
- Local-day rollover and persistence of current-day aggregate counters across app restarts.
- Current active, paused, and unavailable status in Settings Readiness; collection completeness remains internal.
- Settings for start at login, pause/resume, Mbps or MB/s, MB/GB or MiB/GiB, and reset-today counters.
- Local-only measurement and persistence. The app observes interface byte counters and does not block or modify connections.
- User-visible section, metric, status, and control labels use Title Case.

### Out Of Scope

- Network Extension installation or activation for the initial device-only release.
- Per-app current rates, daily totals, icons, top-five ranking, or measured System/Unattributed flow totals.
- Packet payload capture, browsing history, domains, URLs, or traffic classification.
- Network controls such as firewall rules, parental controls, throttling, or blocking.
- Long-term history, charts, remote dashboards, syncing, sharing, or telemetry upload.
- A generalized installer, managed fleet deployment, or public app-store release.
- Support for Macs beyond the named MacBook and its installed macOS version/architecture.

### Delivery Phases

Detailed phase plans and execution evidence live under `hl-docs/desktop/`.

1. **Phase 00 - Root Project Foundation:** Establish the root-level Xcode app and local build workflow.
2. **Phase 01 - Device Usage Counters:** Read interface counters, calculate rates, persist daily totals, and handle local-day boundaries and gaps.
3. **Phase 02 - Flow Attribution Feasibility Decision:** Determine whether the target supports a sufficiently low-impact path for app identity, live rates, flow totals, and durable local handoff. The initial-release decision is to defer attribution until an end-to-end target proof exists.
4. **Phase 03 - Menu Controls Settings:** Present device rates/totals and the monitoring controls and states.
5. **Phase 04 - Target Install Verification:** Verify the device-only release on the target MacBook.

## 8. Platform Scope

Use the standard repository root folder names when describing platform surfaces:

- `web/` for the web application - not applicable.
- `backend/` for the backend service layer - not applicable; there is no backend.
- `mobile/` for the mobile application - not applicable.
- `desktop/` is the planning area for the macOS product surface, located at `hl-docs/desktop/`.
- The native macOS application source and Xcode project remain at the repository root in `MacUtilities/` and `MacUtilities.xcodeproj`.

* **Backend Service:** None. Monitoring and aggregation are local to the MacBook.
* **Web Application:** None.
* **Mobile Application:** None.
* **Other Surfaces:** The native macOS menu bar application, Settings window, device interface-counter sampler, and local current-day storage. No Network Extension is included in the initial release.

## 9. Functional Requirements

- **FR-1 Live Speed:** Show current total inbound and outbound rates in the menu bar and popover. Calculate rates from device byte-count deltas over elapsed time and refresh the visible rate about once per second. Inbound bytes are downloads; outbound bytes are uploads. The menu-bar item has no app icon and uses the compact format `↓ <download rate> / ↑ <upload rate> <selected unit>`, with the unit shown once.
- **FR-2 Background Collection:** Continue sampling while the popover is closed whenever monitoring is active.
- **FR-3 Daily Device Totals:** Accumulate downloaded, uploaded, and combined device-level bytes for the MacBook's current local calendar day. Use device interface counters for these totals.
- **FR-4 Local-Day Boundary:** Use the MacBook's local calendar and time zone. Begin a new day's totals at local midnight. Handle time-zone and daylight-saving changes using local calendar boundaries rather than a fixed 24-hour timer.
- **FR-5 Persistence:** Preserve the current day's device aggregate counters across app restarts using local storage on this MacBook. No network service, account, app group, or monitoring-provider handoff is required for this release.
- **FR-6 Collection State:** Settings contain a separate Readiness section with the Mac's current local time zone and active, paused, or unavailable monitoring status. Monitoring contains the collection switch. Do not display a Partial badge or historical pause/incomplete-collection messages. Keep completeness metadata internally; displayed totals represent observed traffic rather than guaranteed full-day coverage.
- **FR-7 Controls And Preferences:** Provide start-at-login on/off, monitoring pause/resume, Mbps or MB/s rate display, MB/GB or MiB/GiB data display, and reset-today control. Label the popover control `Settings` without an ellipsis; it must open Settings or bring the existing Settings window forward.
- **FR-8 App-Level Data Scope:** Do not display per-app rates, totals, rankings, icons, or System/Unattributed values in the initial release. Do not show an attribution placeholder or represent missing app data as zero. Reconsider this scope only after a low-impact, macOS-supported measurement and local handoff path is proven on the target machine.
- **FR-9 Traffic Behavior And Privacy:** Observe device counters locally without blocking, proxying, or modifying connections. Store only current-day aggregate counters and interface baselines locally; do not collect app identity, packet contents, destinations, or remote telemetry.
- **FR-10 Title Case Labels:** Use Title Case for all user-visible section, metric, status, and control labels.

## 10. Acceptance Criteria

- The menu bar displays current download and upload rates and updates approximately once per second while active.
- The menu-bar item has no app icon and displays rates as `↓ <download rate> / ↑ <upload rate> <selected unit>` with a single unit suffix.
- Closing the popover does not stop sampling; rates and totals continue to advance while monitoring remains active.
- The popover displays device-wide current rates and today's download, upload, and combined totals.
- Current-day counters survive an app restart on the same local day and reset when the local calendar day changes.
- Settings Readiness shows the current monitoring state and local time zone separately from the Monitoring switch. Neither surface shows Partial or historical pause messages.
- The popover contains no per-app section or deferred-attribution placeholder; device totals are identified as device-wide.
- Settings expose start-at-login, pause/resume, speed units, data units, and reset-today controls.
- The popover Settings control is labeled `Settings` without trailing dots and opens or foregrounds the existing Settings window.
- All user-visible section, metric, status, and control labels use Title Case.
- Observed traffic continues normally because the app reads device counters and does not interpose on connections.
- The developer-installed build runs on the target MacBook and correctly reports when device counters cannot be read.

## 11. Success Metrics

* **Primary Metric:** The target MacBook displays live device rates and a correctly updated current-day device-usage summary during active monitoring.
* **Secondary Metrics:**
  - Current-day counters survive app restarts and reset at the local calendar boundary.
  - Readiness distinguishes current active, paused, and unavailable monitoring; completeness metadata is retained internally.
  - Rates respond to inbound and outbound byte-counter deltas with no fabricated app attribution.
* **Measurement Window:** Functional verification during local development and personal use on the target MacBook. No analytics telemetry is collected.

## 12. Assumptions

- The app is for one user's personal use on one target MacBook.
- The supported target is this MacBook on macOS 26.6.2 and arm64; no other Mac compatibility target is required.
- Device-level interface counters are available to the app for overall activity.
- The first release does not depend on a Network Extension, app-group container, or app identity data.
- Current-day aggregates are sufficient; historical daily records are not required.
- Selected display units affect presentation only, not stored byte counts.

## 13. Dependencies

- Xcode and a compatible macOS SDK installed on the target MacBook.
- Device-level interface counters accessible to the app on the target macOS version.
- Local writable Application Support storage for the current-day snapshot.
- A macOS-supported flow-report handoff and source-app identity method are future prerequisites only if app attribution is reconsidered.

## 14. Risks And Open Questions

### Risks

- Interface membership changes, counter resets, system sleep, app termination, pause intervals, or local clock/time-zone changes can create incomplete intervals. Retain this metadata internally; displayed totals are observed usage and may omit unobserved intervals.
- Device interface counters can have platform-specific coverage boundaries, particularly when multiple physical or virtual interfaces are active. The target MacBook's selected interface behavior must be observed and documented.
- App restarts can recover totals from persistent interface baselines only while the source counters remain monotonic and comparable.
- macOS flow reports expose closed-flow byte totals and a source audit token, but they do not provide live per-app rates without sampling data in the filter path. The first-release decision is to defer that capability until a low-impact end-to-end path is proven on the target MacBook.

### Open Questions

- Does the selected interface-counter set accurately cover the target MacBook's common Wi-Fi and Ethernet configurations without duplicate accounting?
- Should per-app attribution be reconsidered if Apple documents or provides a supported report handoff in a later macOS release?

## 15. Cross-Platform Contracts

* **Shared Data Models:** No cross-platform models are required. The local snapshot stores byte-based device download/upload totals, a local calendar-day key, interface baselines, the latest sample time, and collection-status metadata.
* **Sync Model:** None. The host app stores current-day aggregates locally in Application Support using atomic updates. There is no app/provider synchronization in the initial release.
* **Identity Model:** No app identity is collected or persisted in the initial release. A future attribution phase must use a supported macOS source identity and must not persist raw audit tokens.
* **Failure Expectations:** Readiness reports current paused or unavailable monitoring. Retain incomplete-collection metadata internally without showing historical warnings; totals represent observed traffic.

## 16. Security And Compliance

* **Access Rules:** The app reads system interface counters and writes only its own local aggregate snapshot and preferences.
* **Sensitive Data Handling:** Keep data on this MacBook. Do not upload or sync it. Do not collect app identity, packet payloads, destinations, URLs, or browsing content.
* **Legal Or Policy Requirements:** Follow macOS sandbox and signing requirements applicable to the local build. Network connections must continue without the app blocking, proxying, or modifying them.

## 17. Release And Rollout Notes

* **Release Strategy:** Begin with a developer-installed local build on the target MacBook. No public distribution is planned for the initial version.
* **Rollback Strategy:** The user can pause monitoring, quit or remove the local app, or restore a previous build. The app does not install a network filter or change system traffic configuration.
* **Support Readiness:** Verify menu bar rates, observed popover totals, restart persistence, local-midnight rollover, the Settings Readiness section, and absence of Partial and historical pause messages. The first-release UI omits app-attribution rows and placeholder copy.
