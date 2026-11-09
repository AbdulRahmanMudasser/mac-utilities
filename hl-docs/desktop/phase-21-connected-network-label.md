# Phase 21 - Connected Network Label

## 1. Phase Purpose

This document owns the current requirements, implementation and verification for the network identity presentation approved in the November 9, 2026 conversation: replace Current Speed with the Wi-Fi name or a compact fallback, keeping permission explanation and recovery in Connection. Execution evidence belongs in §14; document creation alone is not completion evidence.

## 2. Feature Objective

- **Phase Goal:** Show useful current connection context without adding a popover row.
- **User Or System Outcome:** The user sees their Wi-Fi name above the existing download/upload card, or a short truthful fallback.
- **In Scope:** Active-path classification, optional transient SSID access, explicit Location authorization from Connection, coordinated visible-surface updates, accessible compact presentation and isolated regression coverage. Subsequent user instructions also authorized signed local installation and version/build updates.
- **Out Of Scope:** Per-network traffic accounting/history, BSSID, coordinates, scanning, association/configuration, VPN management or guaranteed VPN identification, internet reachability probes, widget functionality changes, menu-bar label changes, automatic permission prompts, public distribution and notarization.

## 3. Current State And Implementation Delta

- **Verified Current Behavior:** `ContentView.ratesSection` shows a network name or compact fallback above unchanged device-wide rates. One `WiFiQualityMonitor` owns visible-surface path observation, five-second serial CoreWLAN sampling and generation guards for the Connection/popover visibility union. Optional SSID access is explicitly authorized in Connection. `NetworkNameCapabilityView` is the first item in `ConnectionCheckView`, above the Wi-Fi panel; an allowed grant remains a one-line green permission message even when Wi-Fi is off. Interface candidates are a set because native path readings may repeat the same BSD interface. `NetworkInterfaceLabel` remains a diagnostic interface-label resolver. Stability keeps its separate run-scoped observer. The signed host is unsandboxed and the widget remains sandboxed with the existing App Group.
- **Verified Gap:** The misleading authorized-but-no-name explanation has been removed. There is no remaining identified source gap in this scope; physical Ethernet switching remains unverified because the available adapters have no active link.
- **Delivered Implementation Delta:** Extended the existing monitor/reader with injected path and permission adapters, shared presentation and isolated fixtures/tests. No second CoreWLAN client or usage collector was added. Native duplicate-interface readings, top-of-module capability placement, permission lifecycle/recovery and request guards have regression coverage.
- **Preserved Or Excluded Behavior:** Rates and totals remain device-wide; no storage migration or per-network attribution. Preserve diagnostic cancellation, singleton-window behavior, quality metric normalization, usage collection and App Group identities.
- **Approved Contract Exception:** The conversation approved optional transient SSID display and explicit Location authorization. AGENTS.md and Standards §§3/6 now reflect that narrow exception, preserving the exclusions for coordinates, BSSID, scans, association/configuration and identity persistence. The older PRD identity exclusion remains baseline text outside this documentation update scope; current approved intent is recorded here and in the technical standards. Completed historical phases remain unchanged.

## 4. Project Topology & Dependencies

- **Local Tracker:** [Desktop Execution Workflow](./execution-workflow.md).
- **Prerequisites (Blocked By):** Phases 06, 08, 10 and 18 are Completed. Phase 21 is independent of the Planned speech Phases 19–20; it does not reorder their existing dependency chain.
- **Downstream Tasks (Unlocks):** Not applicable; no dependent phase is approved.
- **Target Git Commit Prefix:** `feat(connection): ...`.
- **Project Profile(s):** Native macOS desktop, SwiftUI/AppKit, arm64, macOS 26.6+, confirmed by `project.yml` and `Mac_UtilitiesApp`.
- **Applicable Development Standards:** [Desktop Development Standards](./development-standards.md) §§2–3 architecture/ownership/storage, §§4.1–4.4 shared presentation and truthful state, §5 project/signing and §6 isolated tests/previews/privacy. Apply the explicit exception above to SSID/permission/visibility rules. No fallback platform standards are needed.

## 5. Ownership And Delivery Notes

- **Owner:** TBD.
- **Priority:** TBD.
- **Target Window:** TBD.
- **Related PRD Section:** [Mac Utilities PRD](../mac-utilities-prd.md), FR-9 Traffic Behavior And Privacy, FR-16 Wireless Link Quality and the older identity exclusion are baseline context. The approved exception in §3 governs this phase; a PRD revision requires separate explicit scope.
- **Related Build Plan Section:** Not applicable; no separate build plan is maintained for this scope.

## 6. Infrastructure & Environment Requirements

- **Environment Variables:** Existing `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and ignored local signing configuration only. No server, credentials or lifecycle scripts are required.
- **Database/Index Changes:** Not applicable; all identity and permission-derived presentation is transient. No new persisted opt-in preference is required: explicit authorization is the opt-in, and revocation is handled through macOS settings.
- **Feature Flags / Config Switches:** No release flag. Fake adapters/fixtures are injected for tests and Debug previews only.
- **Seed / Fixture Requirements:** Synthetic SSIDs (short, long, mixed Unicode and control characters), permission/path states and deferred reads. Tests must never request real permissions, enumerate real SSIDs or access production history/preferences.
- **Required Reusable Utilities:** `WiFiQualityMonitor`, `CoreWLANWiFiQualityReader`, shared `UtilityPanel`, `UtilityCapabilityCard`, `UtilityValueRow`, `UtilityStyle` and `handPointer`. Reuse the injectable adapter pattern illustrated by `MicrophonePermissionChecking`; do not couple Location authorization to the microphone implementation.

## 7. API & Data Contract Specifications

HTTP endpoints and JSON request/response schemas are not applicable; this is local native state.

Feature-local Sendable values live under `MacUtilities/Features/Connection/Models/`:

- Path: pending, unavailable, or available with used transport types and a set of Wi-Fi interface candidates. Map .unsatisfied/.requiresConnection to unavailable, .satisfied to available and unknown future status to pending/Checking…. The monitor owns observation generations. Deduplicate repeated BSD interface names before deciding whether association is ambiguous. Match an SSID only for an unambiguous Wi-Fi path with one distinct candidate matching the CoreWLAN interface. A mismatch or several distinct Wi-Fi candidates uses Wi-Fi; ambiguous transport types use Network. An unambiguous wired path uses Ethernet even if unused Wi-Fi candidates exist. Never choose availableInterfaces.first or hard-code en0.
- Permission: not determined, requesting, authorized, denied, restricted, services disabled and unknown. On macOS, map the platform authorizedAlways status to authorized while requesting access only through requestWhenInUseAuthorization(); do not request an upgrade or coordinates. Services-disabled overrides a grant. Query state on visible acquisition, activation and visible refreshes. Ineligible/no-op requests return their queried state without awaiting a callback. Deduplicate an issued native request; initial not-determined callbacks do not cancel a live prompt. Foreground return reconciles unresolved requests without automatically reissuing them. Shutdown rejects later callbacks.
- Wi-Fi identity: an optional current SSID, associated BSD interface and sampledAt timestamp. The monitor captures and checks its generation around each read rather than storing a generation in the snapshot. Name availability is independent of quality metrics. Preserve original identity in transient memory and sanitize display controls without forcing capitalization. Empty or undecodable names are unavailable.
- Presentation: label, semantic icon and accessible full value. Path pending → Checking…; unavailable → Offline; Wi-Fi path with matching authorized SSID → name; Wi-Fi without name → Wi-Fi; unambiguous wired path → Ethernet; other/ambiguous path → Network. A VPN or ambiguous multi-interface path must not fabricate an underlying transport or associate a default Wi-Fi SSID with an unrelated interface.

Use `CWInterface.ssid()` only after authorization and with Location Services enabled. The installed Xcode SDK’s `CWInterface.h` documents that requirement and nil outcomes. `CLLocationManager.h` supports `requestWhenInUseAuthorization()` on macOS and requires `NSLocationWhenInUseUsageDescription`. Request from the foreground Connection action, retain the manager/delegate, and process authorization callbacks. Do not start location updates or request coordinates, background access or Always authorization. Validate this foreground/menu-bar behavior with the signed target build; permission is not a guarantee that SSID is available.

Source references: [Apple SSID API](https://developer.apple.com/documentation/corewlan/cwinterface/ssid()) and [When In Use authorization](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization()). The installed SDK header contracts are the version-local reference; signed macOS 26.6+ behavior remains a verification gate.

One extended `WiFiQualityMonitor` owns path observation plus one existing serial CoreWLAN reader. Platform callbacks publish reduced Sendable values through MainActor with generation guards. A new visible-surface path source must be separate from stability’s run-scoped `ConnectionObservationEvents`; preserve that source’s cancellation and timing contracts. NWPath interface membership cannot detect every access-point change, so retain five-second sampling while either consumer is visible. This is observation-based freshness, not an atomic route/association snapshot: same-interface network changes become visible at the next successful sample (normally five seconds plus read/scheduling latency). On detected changes, invalidate old state before publishing the replacement. Do not promise immediate detection of every access-point change. Keep unchanged path callbacks from repeatedly clearing a valid label or restarting polling.

## 8. UX / Behavioral Expectations

- Replace only the Current Speed heading with one icon/text line at its existing position and spacing. Keep the existing speed card and Connection Health heading/action. No extra popover row or permission message.
- Use the label mapping in §7. On an available Wi-Fi path, a missing SSID uses Wi-Fi without inferring a disconnect. Offline describes an unavailable path, not a verified internet failure. Checking… is an initial/pending reading; no Connecting… association-progress state is implemented. Fast switches need not display an intermediate state. Do not use green health styling based only on association/path satisfaction.
- Limit the label to one line with tail truncation, full sanitized text in a tooltip and VoiceOver value; icon semantics distinguish a Wi-Fi name from Ethernet. Never force user network names into Title Case.
- `NetworkNameCapabilityView` renders the shared permission/recovery card at the top of Connection, before `WiFiQualityView`. Follow Standards §4.4 for permission-versus-connectivity semantics and compact labels. The allowed state has no missing-name explanation. Wi-Fi quality content retains the associated-name row, metrics and timestamp. First authorization uses Show Wi-Fi Name; denied/services-disabled recovery uses Open Settings with a System Settings fallback. Failure to open settings is titled Could Not Open Settings with manual navigation detail. Restricted/unknown states offer no ineffective action. Requesting uses the shared progress accessory. Synthetic preview actions are disabled and identified as simulated.
- Show the associated Wi-Fi name separately in Connection when Ethernet carries the current path. Do not label associated Wi-Fi as the active route. Explain that the speed values cover device-wide traffic.
- Show Wi-Fi readings without requiring name permission. An authorized but unavailable name does not disable signal/link metrics or diagnostics.
- On either surface opening: publish pending/current transport truthfully and refresh immediately. Track popover and Connection visibility separately; use their union for sampling. Closing/hiding one releases only that consumer; closing/hiding both stops polling/path observation and clears transient SSID state. The permission delegate may remain owned until shutdown, without hidden polling. Use actual window visibility/occlusion notifications rather than relying solely on SwiftUI appearance callbacks.
- On wake, active-path change, permission change/revocation or surface reacquisition: invalidate obsolete identity and in-flight work before refreshing. Recheck authorization on app activation/return from Settings. Keep asynchronous reads serialized; repeated events coalesce instead of overlapping. Replacing an observer or shutting down invalidates callbacks. Clear identity on observed revocation and whenever both consumers become hidden, so delayed OS callbacks cannot leave a retained hidden name. Never reuse hidden cached identity on reopen before revalidation. On sleep, invalidate identity and suspend work until wake; do not rely solely on a wake callback to reject a result completed across sleep.

## 9. Acceptance Criteria

- **AC1:** Current Speed is replaced in place by the correct compact label/icon, without added popover rows, width changes or changed speed/usage accounting.
- **AC2:** Wi-Fi names appear only with authorization and matching association; every fallback in §7 is deterministic and truthful, including unknown/VPN/multi-interface paths.
- **AC3:** Only the explicit Connection action requests permission; denied, restricted, disabled, requesting, revoked and authorized-but-nil states remain usable and recover appropriately.
- **AC4:** One CoreWLAN reader/poll loop serves both consumers; undetected same-interface changes have the bounded observation semantics in §7, not an instantaneous freshness guarantee. Visibility, wake, detected path/identity changes, authorization callbacks and shutdown reject obsolete-generation names and leave no unused path observers/polling active. The owned permission delegate is exempt from the visible-only path-observer rule.
- **AC5:** Names are transient and absent from usage/widget storage, preferences, logs and diagnostic exports; no BSSID, scans or coordinates are collected.
- **AC6:** Light/Dark, long/Unicode names, keyboard, tooltip and VoiceOver checks pass at existing popover width and Connection sizes 620 × 420, 860 × 660 and 1100 × 800.
- **AC7:** Existing Wi-Fi, window and startup regressions remain passing, and signed macOS authorization/route-switch checks establish native behavior with documented limitations. Release contains no synthetic routes or verification namespace.

## 10. Requirement Traceability

| Requirement | Planned Implementation | Affected Files / Symbols | Acceptance Criteria | Verification Evidence |
| :--- | :--- | :--- | :--- | :--- |
| Replace heading; no added line | Compact icon/name above unchanged rates | `ContentView.ratesSection`, feature-local presentation model | AC1, AC6 | Layout captures and label mapping tests |
| Name with short fallbacks | Match path and optional association; deterministic precedence | New path source/models; extended reader/monitor | AC2 | Injected path/identity table and signed switches |
| Permissions in Connection | Explicit authorization and state-specific recovery | New Location adapter, `WiFiQualityView`, Info.plist | AC3 | Fake permission transitions and signed native prompt/recovery |
| Robust shared lifecycle | Consumer visibility union, serial reads, invalidation | `WiFiQualityMonitor`, `UtilityWindowCoordinator`, composition/delegate | AC4, AC7 | Deferred-reader, ownership and teardown tests |
| Transient private identity | No persistence/logs; narrow canonical rule update | Connection models/adapters, AGENTS.md, Standards, PRD | AC5 | Data-flow inspection and isolated regression evidence |
| Device-wide rates remain | Keep `UsageMonitor` and totals unchanged | `ContentView.ratesSection` | AC1 | UI/data-flow regression check |
| Isolated verification | Explicit Debug fixture/native modifiers with validated isolated bootstrap | `HostRuntime`, `HostStartupController`, `HostStartupTests`, proposed fixtures | AC3, AC5, AC6, AC7 | Modifier validation, synthetic layout and signed native evidence |
| Per-network history / widget identity | Explicitly excluded | No changes to `Shared/`, usage stores or widget | AC5 | Diff and storage-contract inspection |

## 11. Implementation Steps (Component Audit)

### A. Platform Adapters And Feature State

- [NEW] `MacUtilities/Platform/Networking/NetworkPathReader.swift`: injectable path observation protocol and NWPathMonitor adapter owned by the existing transient monitor. Emit path availability and used types, not inferred internet health; stop/recreate safely with observation generations. A cancelled NWPathMonitor is discarded, not restarted. Define a callback-based start/stop protocol with fake emit/startCount/stopCount controls; no host-test initializer may silently create a native path source.
- [NEW] `MacUtilities/Platform/Networking/NetworkNamePermission.swift`: retained MainActor CLLocationManager/delegate adapter with injectable protocol, authorization/services-state queries, deduplicated explicit request and injected Settings recovery. Include state-change delivery and idempotent shutdown that clears delegate/callback ownership; marshal delegate callbacks safely to MainActor. Bound asynchronous requesting presentation as specified in §7; do not wait forever for a no-op API call. Do not request live location updates.
- [NEW] `MacUtilities/Features/Connection/Models/ConnectedNetworkModels.swift`: pure path/permission/label values and the mapping in §7; keep them outside `Shared/`.
- [MODIFY] `MacUtilities/Platform/Networking/WiFiQualityReader.swift`, anchor `CoreWLANWiFiQualityReader.read(allowNetworkName:)`: gate optional SSID access through the retained client and return identity alongside the existing quality snapshot. The owning monitor captures and revalidates generation, permission and path on return; the reader does not need a duplicate generation field. Preserve metric normalization and timestamps independently of identity. A default interface that does not match the unique path candidate produces the Wi-Fi fallback without scans or guessed routing.
- [MODIFY] `MacUtilities/Features/Connection/WiFiQualityMonitor.swift`, anchors `setVisible`, `refreshAfterWake`, `poll`, `shutdown`: replace the single consumer Boolean API with named consumer visibility, owned path observation and permission subscription. Centralize invalidation, refresh coalescing and generation checks. Keep only one polling task and one active read, including transitions while a read is suspended. Preserve the existing safe coalescing pattern: invalidate/cancel, retain task ownership until the in-flight read drains, then start exactly one fresh generation. Named consumer updates must be idempotent; unrelated window notifications must not restart reads.
- [MODIFY] `Configuration/Info.plist`: add the when-in-use purpose string explaining Wi-Fi name access. `project.yml`: declare CoreLocation.framework alongside CoreWLAN; regenerate the ignored project when changed. Preserve signing identities, sandbox configuration and entitlements; do not add unrelated location/background capabilities.

### B. Composition And Presentation

- [MODIFY] `MacUtilities/App/HostRuntime.swift`: construct/inject the path and permission adapters into the existing monitor; provide the same monitor to utility and popover presentation. Construct fake path/permission adapters for every hosted-test and ordinary preview runtime; current previews otherwise use a live Wi-Fi reader, so explicitly suppress SSID access even if the app already has authorization. Inject a fully synthetic reader for network-label fixtures. Live name/permission adapters are enabled only in production or the explicit isolated native-check modifier below. Existing previews may retain passive quality-only readings. Do not introduce native defaults into direct test-created monitors.
- [MODIFY] `MacUtilities/App/Mac_UtilitiesApp.swift`: inject the monitor into `ContentView`; preserve menu-bar status behavior.
- [MODIFY] `MacUtilities/App/UtilityWindow.swift`: extend `MenuBarPopoverWindowAccessor` and `UtilityWindowCoordinator` visibility observation to track both windows, replace direct popover property assignment with an idempotent registration/unregistration method shared by accessor make/update/viewDidMoveToWindow and dismantling. On detachment, unregister only the matching window so a late callback cannot detach a replacement. Observe the popover without replacing its framework-owned delegate. Handle orderOut/dismissal, willClose and occlusion updates; detach old notification tokens and release only the correct consumer. Add an owned willSleep observer beside the current wake observer; invalidate/suspend at sleep, then recompute and refresh the union at wake. Remove both on shutdown. Preserve diagnostics cancellation on utility-window close.
- [MODIFY] `MacUtilities/App/AppDelegate.swift`, anchor applicationDidBecomeActive: refresh network-name authorization/services state through the existing monitor, as the app already does for microphone/notification authorization. Both termination paths already call shutdown correctly: preserve those calls, and extend tests to establish cleanup of the monitor’s newly owned adapters; no second delegate or termination flow is needed.
- [MODIFY] `MacUtilities/Features/Popover/ContentView.swift`, anchor `ratesSection`: replace heading with the shared state-derived single-line label/icon, tooltip and accessibility value.
- [MODIFY] `MacUtilities/Features/Connection/WiFiQualityView.swift`: keep the associated-name row and quality content in WiFiQualityView; its sibling NetworkNameCapabilityView owns the shared permission/recovery card. ConnectionCheckView places that card first. Preserve description overflow, timestamp and single-line allowed-permission behavior.

### C. Isolated Preview And Native Check Composition

- [MODIFY] `MacUtilities/App/HostRuntime.swift`, anchors previewMode, previewMonitor and WiFiQualityMonitor construction: add Debug-only `--network-label-preview=<state>` as a modifier requiring `--usage-preview=history`. Supported synthetic states are checking, named, long-name, wifi, ethernet, network, offline, denied, requesting and unavailable. Inject fake identity/path/permission values, disable real permission actions and identify the simulation in the Connection capability card. The existing usage route supplies temporary storage, fake other feature owners and disabled collection. Never resolve production storage to render these fixtures.
- Add Debug-only `--network-label-native-check` with the same mandatory `--usage-preview=history` argument. It uses real path/CoreWLAN/Location adapters but retains the existing isolated usage/preferences/transcript composition and disabled collection. Reject a missing companion argument before production bootstrap; reject conflicting fixture/native modifiers and unknown fixture values. Do not enable live adapters by accepting an arbitrary unvalidated prefix.
- [MODIFY] `MacUtilities/App/HostStartupController.swift`, anchor bootstrap: validate these modifier combinations before the existing preview bypass/production storage path. [MODIFY] `MacUtilities/App/AppDelegate.swift`, anchor presentRequestedPreview: preserve the existing usage-preview launch; inspect the popover by closing that isolated utility window and opening its menu-bar item, then use its existing Connection action. No standalone unisolated preview route is needed. `MacUtilities/App/UtilityWindow.swift` may identify the network fixture in the preview window title. All modifier parsing and fake/native composition are excluded from Release.

### D. Tests And Canonical Documentation

- [MODIFY] `Mac UtilitiesTests/Connection/WiFiQualityTests.swift`: reuse Immediate/Deferred reader fakes; cover consumer interleavings, maximum one active read, obsolete completion, hide/reopen, wake, authorization changes, SSID changes on the same interface, partial metrics, valid SSID with no quality readings, sleep and shutdown. Existing sentinel-normalization and read-serialization tests already cover baseline behavior: extend their fixtures/protocols rather than duplicating equivalent cases. Supply fake path/permission dependencies at every current WiFiQualityMonitor test construction site.
- [NEW] `Mac UtilitiesTests/Connection/ConnectedNetworkTests.swift`: injected path/permission adapters and table-driven presentation tests for all §7 outcomes, wrong-interface SSID, authorized nil, Unicode/control characters, repeated request suppression, no-op request completion, foreground loss, Settings-open failure, stale path callbacks, cancelled-observer replacement and late permission callback rejection. Include path .requiresConnection/unknown, unique versus multiple candidate interfaces, loopback/other transports and simultaneous used types. No real TCC prompts or network changes in hosted tests.
- [MODIFY] `Mac UtilitiesTests/Window/UtilityWindowTests.swift`: verify popover-to-Connection handoff, actual visibility/hide/minimize, independent consumer release and observer cleanup. Keep stability ownership unchanged. Explicitly test accessor detachment/replacement, unrelated-window events and sleep-before-read-completion.
- [MODIFY] `Mac UtilitiesTests/Window/HostStartupTests.swift`, anchor HostStartupTests, and NetworkLabelLaunchModeTests in `Mac UtilitiesTests/Connection/ConnectedNetworkTests.swift`: verify valid/invalid Debug modifier combinations, isolated runtime composition and rejection before bootstrap. Hosted tests use injected factories and never request native permission or reset TCC. Shutdown the constructed utility-window coordinator to release its observers.
- [MODIFY] `AGENTS.md` and `hl-docs/desktop/development-standards.md` §§3/4.4/6: record the approved transient-identity/authorization contract, capability placement, permission-versus-connectivity semantics and preview modifiers. The PRD and completed historical Phase 10 remain unchanged. Current phase evidence belongs in §14 and its live tracker row; chronological logs are outside this update.

## 12. Risks And Rollback Notes

- **Implementation Risks:** NWPath cannot prove all physical/VPN routing details; use Network rather than inventing certainty. SSID reads may be nil despite authorization. SwiftUI appearance alone can miss menu-bar window closure. Shared consumer ownership and suspended reads require explicit lifecycle tests.
- **Operational Risks:** Native authorization depends on stable signed identity and app activation; a Debug fixture cannot prove production TCC behavior. Do not reset the user’s permissions, change production network settings automatically or expose personal SSIDs in evidence.
- **Rollback Approach:** Revert the connection-label extension without changing data stores. The user-authorized release workflow installs signed Release builds at ~/Applications/Mac Utilities.app and archives replaced bundles outside Git. Reverting code does not revoke an OS authorization grant; macOS Settings controls it.

## 13. Verification Protocol (Definition of Done)

### A. Automated Suite

The following commands remain the supported reproduction protocol. Execution evidence is recorded in §14. If the speech framework is absent, follow Standards §5’s build-whisper-runtime.sh prerequisite. Generate the project when absent or configuration changes; use separate task-specific derived-data roots for ad-hoc tests and signed builds to avoid cached signature mismatches.

```sh
xcodegen generate --spec project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-network-label-tests CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-network-label build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-network-label build
codesign --verify --deep --strict '/tmp/mac-utilities-network-label/Build/Products/Release/Mac Utilities.app'
open -n '/tmp/mac-utilities-network-label/Build/Products/Debug/Mac Utilities.app' --args --usage-preview=history --network-label-preview=long-name
# After quitting the task-owned fixture, run the signed native check separately:
open -n '/tmp/mac-utilities-network-label/Build/Products/Debug/Mac Utilities.app' --args --usage-preview=history --network-label-native-check
git diff --check
```

The test command runs the complete hosted suite, including WiFiQualityTests, ConnectedNetworkPresentationTests, ConnectedNetworkMonitorTests, NetworkLabelLaunchModeTests, NetworkNamePermissionTests, UtilityCapabilityCardTests, UtilityWindowTests and HostStartupTests. Ad-hoc tests do not establish native authorization or App Group access. Debug/Release builds use the existing local signature. The documented Debug modifiers in §11C are implemented; supported usage appearance/size modifiers can accompany them. Close the initial isolated Usage window and use the menu-bar item for popover checks. Ordinary fixtures never request Location. The native-check modifier preserves isolated stores while permitting an explicit Connection authorization action; OS authorization itself belongs to the stable app identity and is not isolated. Do not reset TCC, capture personal SSIDs in evidence or launch another production writer. Stability signed gates remain conditional on changes to that separate run-scoped lifecycle.

### B. Functional Verification Matrix

All response codes are Not applicable: no HTTP API is added.

| State | Trigger Action | Expected Result |
| :--- | :--- | :--- |
| Initial / long name | Open checking and long-name fixtures in Light/Dark; emit a resolved path in an injected transition test | Pending stays Checking… until a path event; long name fits one line with full accessible value and unchanged rates layout |
| First authorization | Explicit Show Wi-Fi Name in signed foreground Connection | One native prompt; granting refreshes name; ordinary opening never prompts |
| Denied / restricted / disabled | Inject each state; signed recovery where user permits | Popover Wi-Fi fallback; state-specific Connection guidance, no prompt loop |
| Authorized but nil | Return nil/error/empty SSID | Wi-Fi fallback; valid link readings preserved |
| Name switch / interface mismatch | Inject same-interface SSID change, different interface and delayed old result | Next successful sample replaces same-interface name; detected changes reject obsolete results; wrong interface uses Wi-Fi fallback |
| Ethernet plus associated Wi-Fi | Inject wired active path and Wi-Fi association; signed hardware check if available | Ethernet heading; associated name separately in Connection |
| VPN / ambiguous path | Inject ambiguity; signed existing VPN if available | Truthful verified transport or Network; no invented VPN/underlying name |
| Path unavailable / captive portal | Inject path loss versus satisfied path without internet | Offline only for unavailable path; no internet-health claim |
| Visibility / wake / teardown | Alternate both windows, hide/minimize, deliver wake, quit during read | Consumer union, one reader, no unused polling or post-shutdown publication |
| Revocation / Settings return | Change fake permission; user-controlled native Settings recovery | Old name cleared, status rechecked, fallback or new name |
| Fixture isolation / invalid flags | Test every valid state, conflicting modifiers and missing companion argument | Fake adapters for fixtures; isolated usage in native mode; invalid combinations rejected before bootstrap |
| Privacy / Release | Inspect data flow, built plist/signature and Release binary/routes | No identity persistence/logs; correct purpose key; no Debug fixtures/namespace |

### C. Evidence To Capture

- Actual selected test counts/results and build/signature output; built Info.plist purpose string, version/build and unchanged group/sandbox contract.
- Redacted/synthetic screenshots for compact popover and Connection in Light/Dark and supported sizes; keyboard/VoiceOver observations.
- Signed target-macOS authorization from Connection, menu-bar name access after closing Connection, revocation/recovery, active-route and sleep/wake/close observations; explicitly mark unavailable Ethernet/VPN hardware scenarios as skipped rather than passed.
- Diff/data-flow inspection showing no identity reaches stores/widgets/logging; follow Standards §6 final temporary-bundle/widget-discovery cleanup after the last build or test. Installation remains a separate user request.

## 14. Execution Notes

- **Status:** Completed
- **Started At:** 2026-11-09
- **Completed At:** 2026-11-09
- **Blockers Encountered:** None. Physical Ethernet switching is a verification limitation because no active wired link is available; injected Ethernet/mixed-route cases passed. WARP connect/disconnect was verified and its initial disconnected state restored. No permission escalation was needed.
- **Notes:** Source implementation, the build-39 installed popover/name and its single-line layout were directly verified. The full audit suite succeeded with 415 tests reported; two opt-in signed stability checks were skipped because that separate lifecycle is unchanged. The final permission-copy correction passed 10 targeted capability/presentation/monitor tests, including an allowed-permission card with no name/offline in Light/Dark at supported capability widths. Signed Debug and Release builds succeeded. Release 4.3.2 (40) was installed and its version, one-line permission card, existing history, signatures, host/widget group identity, sandbox split and absence of Debug routes were verified. Only the installed widget extension remains registered; the user confirmed widgets working. No source migration, network configuration change, commit, push or historical log entry was part of this correction.
- **Follow-up (2026-11-09):** The popover now uses the network name in place of the Current Speed heading, with the icon emphasized and text regular at the same size. The full macOS 26.6.2 arm64 suite passed 414 tests; 2 opt-in signed stability checks were skipped. The signed Release build and signature passed, and its Info.plist confirms version 4.3.3 (41). The installed app is 4.3.3 (41).
