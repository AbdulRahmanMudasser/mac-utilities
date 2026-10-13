# Mac Utilities - Product Requirements Document

## 1. Document Purpose

This document is the product source of truth for Mac Utilities. It defines what the product delivers, who it serves, what is in scope, and how success is judged.

Use this file for product goals, user needs, feature scope, acceptance expectations, and platform rules. Use `hl-docs/desktop/` for delivery sequencing and phase evidence. This file does not define repository layout, code-level tasks, or signing runbooks.

## 2. Executive Summary

* **Product Name:** Mac Utilities
* **One-Sentence Summary:** A native macOS menu bar utility that shows live device-wide network activity, today's data totals, and user-started connection quality checks.
* **Problem Statement:** macOS does not provide the owner with a compact, persistent view of current network rates and local-day data use. The app makes those device-wide measurements available at a glance without changing network traffic.
* **Target Audience:** The owner of the target MacBook, using a personal developer-installed build.
* **Primary Outcome:** The user can see current network activity and observed daily usage, check monitoring readiness, and measure endpoint latency, probe loss, and responsiveness while the connection is busy.

## 3. Goals And Non-Goals

### Goals

- Show current device-wide download and upload rates in the menu bar and usage popover, refreshing about once per second.
- Accumulate today's device-wide download, upload, and combined byte totals using the MacBook's local calendar day.
- Preserve the current day's totals through an app restart and reset them at local midnight.
- Continue sampling while the popover is closed when monitoring is active.
- Identify current active, paused, and unavailable states in a dedicated Settings Readiness section.
- Persist daily aggregates locally, keep diagnostic results in the current app session, and allow existing connections through normally.
- Offer manual endpoint latency/probe-loss and responsiveness-under-load checks with clear measurement boundaries and cancellation.

### Non-Goals

- Per-app usage, app identity collection, app ranking, or System/Unattributed flow totals in the initial release. The app does not show a deferred-attribution placeholder.
- Blocking, shaping, modifying, proxying, or inspecting the contents or destinations of other applications' network traffic.
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

### Journey 4: Check Connection Quality

1. The user selects Check in the popover's top Connection Health row to open or foreground Connection in the shared Mac Utilities window.
2. Check Now in Reply Time And Missed Replies sends ten probes to each named internet endpoint and displays endpoint-specific reply counts, missed test replies, typical reply time, fastest/slowest reply, and reply time changes. If probes fail or receive no replies, a separately labeled Web Check supplies additional evidence.
3. Run Speed Test in Internet Speed While Busy explains in simple English that it sends/receives data, can slow the connection, and contributes to observed usage. Only Start Test begins that traffic.
4. The window displays Apple's reported baseline latency, median HTTP delays during download/upload, directional RPM, and capacities. Cancel or closing the window stops a running check; results are not retained across an app restart.

## 7. Feature Scope

### In Scope

- Native macOS menu bar item with current device-wide upload and download rates, refreshed approximately once per second.
- Compact popover with current device rates and today's downloaded, uploaded, and combined device totals.
- Local-day rollover and persistence of current-day aggregate counters across app restarts.
- Current active, paused, and unavailable status in Settings Readiness; collection completeness remains internal.
- Settings for start at login, pause/resume, Mbps or MB/s, MB/GB or MiB/GiB, and reset-today counters.
- Local interface-counter measurement and persistence. Manual diagnostics contact named public test services using their own test traffic; existing connections are not intercepted.
- User-started latency/probe-loss checks for Google and Cloudflare, with separate HTTPS fallback results.
- Opt-in responsiveness-under-load checks, impact disclosure, cancellation, bounded runtime, and transient results in a compact monochrome window.
- User-visible section, metric, status, and control labels use Title Case.

### Out Of Scope

- Network Extension installation or activation for the initial device-only release.
- Per-app current rates, daily totals, icons, top-five ranking, or measured System/Unattributed flow totals.
- Packet payload capture, browsing history, destination/URL collection from other apps, or traffic classification. Explicit diagnostic target addresses are allowed.
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
6. **Phase 05 - Connection Quality Checks:** Deliver and verify user-started endpoint latency/probe loss and responsiveness under load.
7. **Phase 06 - Unified Utility Window:** Combine Connection and Settings in one responsive sidebar window with shared UI conventions.

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
* **Other Surfaces:** The native macOS menu bar application, shared Mac Utilities window with Connection and Settings sidebar sections, device interface-counter sampler, system diagnostic tools, and local current-day storage. Manual checks use public endpoint services; the project operates no backend and installs no Network Extension.

## 9. Functional Requirements

- **FR-1 Live Speed:** Show current total inbound and outbound rates in the menu bar and popover. Calculate rates from device byte-count deltas over elapsed time and refresh the visible rate about once per second. Inbound bytes are downloads; outbound bytes are uploads. The menu-bar item has no app icon and uses the compact format `↓ <download rate> / ↑ <upload rate> <selected unit>`, with the unit shown once.
- **FR-2 Background Collection:** Continue sampling while the popover is closed whenever monitoring is active.
- **FR-3 Daily Device Totals:** Accumulate downloaded, uploaded, and combined device-level bytes for the MacBook's current local calendar day. Use device interface counters for these totals.
- **FR-4 Local-Day Boundary:** Use the MacBook's local calendar and time zone. Begin a new day's totals at local midnight. Handle time-zone and daylight-saving changes using local calendar boundaries rather than a fixed 24-hour timer.
- **FR-5 Persistence:** Preserve the current day's device aggregate counters across app restarts using local storage on this MacBook. Daily aggregation requires no network service, account, app group, or monitoring-provider handoff.
- **FR-6 Collection State:** Settings contain a separate Readiness section with the Mac's current local time zone and active, paused, or unavailable monitoring status. Monitoring contains the collection switch. Do not display a Partial badge or historical pause/incomplete-collection messages. Keep completeness metadata internally; displayed totals represent observed traffic rather than guaranteed full-day coverage.
- **FR-7 Controls And Preferences:** Provide start-at-login on/off, monitoring pause/resume, Mbps or MB/s rate display, MB/GB or MiB/GiB data display, and reset-today control. Settings places Reset Today's Counters right-aligned below the totals card within Today's Usage. About is one icon/name/version row; remove the Privacy section and Network Activity subtitle. Label the popover control `Settings` without an ellipsis; it must open Settings or bring the shared Mac Utilities window on Settings forward.
- **FR-8 App-Level Data Scope:** Do not display per-app rates, totals, rankings, icons, or System/Unattributed values in the initial release. Do not show an attribution placeholder or represent missing app data as zero. Reconsider this scope only after a low-impact, macOS-supported measurement and local handoff path is proven on the target machine.
- **FR-9 Traffic Behavior And Privacy:** Observe device counters locally without blocking, proxying, or modifying other connections. Persist current-day aggregates, interface baselines and preferences locally. Manual connection checks send synthetic traffic to named test services and keep results in the app session; temporary tool output is removed after processing. Do not collect app identity, browsing payloads, destinations of other apps, or remote telemetry. Test bytes contribute to device usage while collection is active.
- **FR-10 Title Case Labels:** Use Title Case for all user-visible section, metric, status, and control labels.
- **FR-11 Endpoint Latency And Probe Loss:** Run ten ICMP probes per endpoint, one second apart, against Google 8.8.8.8 and Cloudflare 1.1.1.1. Use simple labels: Replies, Missed Test Replies, Typical Reply Time (median RTT), Fastest / Slowest Reply (minimum/maximum RTT), and Reply Time Changes (mean absolute change between adjacent successful RTT samples). No replies must say This Server Did Not Reply; never infer universal internet loss from one destination. When no replies or an ICMP failure occurs, show Web Check and Web Reply Time separately for HTTPS reachability and total request timing.
- **FR-12 Responsiveness Under Load:** Start Apple's networkQuality check only after the user accepts the simple-English data-use/slowdown disclosure. Show Reply Time Before The Test, Reply Time While Downloading/Uploading (median loaded HTTP samples with reading counts), Download/Upload Response Score in RPM, Download/Upload Speed in Mbps, and Network Used. Explain RPM as replies per minute. Keep loaded reply times and reading counts on one line, with counts in smaller secondary text. Resolve Network Used through macOS interface display names; retain `Network Interface (<identifier>)` for unknown identifiers and Not Reported for an absent identifier. Omit generic post-result explanation paragraphs. Unreported metrics remain Not Available; failed measurements never become zero or a success state.
- **FR-13 Diagnostic Lifecycle:** In the popover, place Connection Health and the right-aligned Check button first, followed by Current Speed, Today's Usage and the footer controls. Quit is a power icon with a Quit tooltip and accessibility label. Open or foreground one shared Mac Utilities window on Connection. Settings selects Settings in the same window. The left sidebar contains Connection and Settings; a future Usage section is deferred. Switching sections preserves diagnostic results and running checks, with a running indicator beside Connection. Closing the shared window stops checks and clears transient presentation state; reopening reuses the same window. Keep the Mac Utilities title only in the window bar; place status, running indicator and Cancel in a fixed bottom row outside the scrolling results. Use simple English for explanations, results, progress and errors. Use flowing explanatory paragraphs within a 440-point text column, wrapping naturally in narrower windows without forced sentence breaks. Omit promotional local-storage wording from the interface. Run only one check at a time, show progress and a compact Last Checked label/date row for each check, and stop subprocesses when cancelled, timed out, the window closes, or the app quits. Both sections resize without clipping, use shared fonts/card spacing, and place page padding inside the shared scroll viewport. Section headers adapt when their button cannot fit alongside the title. Under-load process runtime is limited to one minute. Diagnostic results have no history or persistence across app restarts; no checks run automatically.

## 10. Acceptance Criteria

- The menu bar displays current download and upload rates and updates approximately once per second while active.
- The menu-bar item has no app icon and displays rates as `↓ <download rate> / ↑ <upload rate> <selected unit>` with a single unit suffix.
- Closing the popover does not stop sampling; rates and totals continue to advance while monitoring remains active.
- The popover orders Connection Health / Check, device-wide Current Speed, Today's Usage with downloaded/uploaded/combined totals, then footer controls; Quit is an accessible power icon.
- Current-day counters survive an app restart on the same local day and reset when the local calendar day changes.
- Settings Readiness shows the current monitoring state and local time zone separately from the Monitoring switch. Neither surface shows Partial or historical pause messages.
- The popover contains no per-app section or deferred-attribution placeholder; device totals are identified as device-wide.
- Settings expose start-at-login, pause/resume, speed units, data units, and Reset Today's Counters outside the totals card but inside Today's Usage; About is compact and Privacy is absent.
- The popover Settings control is labeled `Settings` without trailing dots and opens or foregrounds the shared Mac Utilities window on Settings.
- All user-visible section, metric, status, and control labels use Title Case.
- Observed traffic continues normally because the app reads device counters and does not interpose on connections.
- The developer-installed build runs on the target MacBook and correctly reports when device counters cannot be read.
- Both public endpoints can return observed reply counts, RTT statistics and jitter in the signed sandboxed target build; endpoint silence and tool failures remain distinct outcomes.
- The signed app runs a real sequential load test and displays reported metrics, including loaded latency sample arrays, without fabricating absent values.
- Load-test disclosure precedes transfer. Cancellation and closing the window stop the process and prevent late results from replacing cancelled state.
- Diagnostics use consistent Last Checked rows, retain separate timestamps and do not interrupt device-counter sampling; test traffic is included in observed totals while monitoring is active.

## 11. Success Metrics

* **Primary Metric:** The target MacBook displays live device rates and a correctly updated current-day device-usage summary during active monitoring.
* **Secondary Metrics:**
  - Current-day counters survive app restarts and reset at the local calendar boundary.
  - Readiness distinguishes current active, paused, and unavailable monitoring; completeness metadata is retained internally.
  - Rates respond to inbound and outbound byte-counter deltas with no fabricated app attribution.
  - Manual checks expose interpretable endpoint results and measured responsiveness with working cancellation and explicit unavailable measurements.
* **Measurement Window:** Functional verification during local development and personal use on the target MacBook. No analytics telemetry is collected.

## 12. Assumptions

- The app is for one user's personal use on one target MacBook.
- The supported target is this MacBook on macOS 26.6.2 and arm64; no other Mac compatibility target is required.
- Device-level interface counters are available to the app for overall activity.
- The first release does not depend on a Network Extension, app-group container, or app identity data.
- Current-day aggregates are sufficient; historical daily records are not required.
- Selected display units affect presentation only, not stored byte counts.
- The target provides ping and networkQuality. Diagnostic results depend on endpoint policy and the test path; no result guarantees behavior for every service or application.

## 13. Dependencies

- Xcode and a compatible macOS SDK installed on the target MacBook.
- Device-level interface counters accessible to the app on the target macOS version.
- Local writable Application Support storage for the current-day snapshot.
- System ping/networkQuality tools, the app's network client/server sandbox entitlements for sending tests and receiving datagram replies, and reachable public test services. The app opens no listening service.
- A macOS-supported flow-report handoff and source-app identity method are future prerequisites only if app attribution is reconsidered.

## 14. Risks And Open Questions

### Risks

- Interface membership changes, counter resets, system sleep, app termination, pause intervals, or local clock/time-zone changes can create incomplete intervals. Retain this metadata internally; displayed totals are observed usage and may omit unobserved intervals.
- Device interface counters can have platform-specific coverage boundaries, particularly when multiple physical or virtual interfaces are active. The target MacBook's selected interface behavior must be observed and documented.
- App restarts can recover totals from persistent interface baselines only while the source counters remain monotonic and comparable.
- macOS flow reports expose closed-flow byte totals and a source audit token, but they do not provide live per-app rates without sampling data in the filter path. The first-release decision is to defer that capability until a low-impact end-to-end path is proven on the target MacBook.
- Public endpoints can filter or deprioritize ICMP, and the system tool may omit measurements or return errors. Report the precise outcome and sample size rather than inferring broader failure or inventing a value.
- Active load testing uses a variable amount of data and can affect other users of the connection. It requires explicit user action, disclosure, and cancellation.

### Open Questions

- Does the selected interface-counter set accurately cover the target MacBook's common Wi-Fi and Ethernet configurations without duplicate accounting?
- Should per-app attribution be reconsidered if Apple documents or provides a supported report handoff in a later macOS release?

## 15. Cross-Platform Contracts

* **Shared Data Models:** No cross-platform models are required. The local snapshot stores byte-based device download/upload totals, a local calendar-day key, interface baselines, the latest sample time, and collection-status metadata.
* **Sync Model:** None. The host app stores current-day aggregates locally in Application Support using atomic updates. There is no app/provider synchronization in the initial release.
* **Identity Model:** No app identity is collected or persisted in the initial release. A future attribution phase must use a supported macOS source identity and must not persist raw audit tokens.
* **Failure Expectations:** Readiness reports current paused or unavailable monitoring. Retain incomplete-collection metadata internally without showing historical warnings; totals represent observed traffic. Diagnostics distinguish endpoint silence, tool errors, absent metrics, timeout and cancellation, and discard late results after cancellation.

## 16. Security And Compliance

* **Access Rules:** The sandboxed app reads system interface counters, stores its own local aggregates/preferences, and runs bounded system diagnostic tools. Network client/server entitlements permit test connections and datagram replies; no listener, proxy, filter, or system network configuration is installed.
* **Sensitive Data Handling:** Keep user measurements on this MacBook. Manual checks send synthetic test traffic to named public endpoints, which necessarily receive that traffic and the connecting address. Store diagnostic results only in the current app session and promptly remove temporary tool output. Do not upload aggregate counters, diagnostic telemetry, app identity, browsing payloads, or other applications' destinations.
* **Legal Or Policy Requirements:** Follow macOS sandbox and signing requirements applicable to the local build. Network connections must continue without the app blocking, proxying, or modifying them.

## 17. Release And Rollout Notes

* **Release Strategy:** Current installed personal release: 1.0.1 (build 3). Use a developer-installed local build on the target MacBook; public binary distribution is not in scope.
* **Rollback Strategy:** The user can pause monitoring, quit or remove the local app, or restore a previous build. The app does not install a network filter or change system traffic configuration.
* **Support Readiness:** Verify menu bar rates, observed totals, persistence, local-day rollover, Settings Readiness and diagnostic controls/results in the signed app. Check sandbox entitlement behavior, public endpoint responses, system-tool output, cancellation, close/quit cleanup and absent/error measurements. Verify the monochrome icon-free diagnostic layout and hand cursors. The UI omits app-attribution rows, Partial badges and historical pause messages.
