# Desktop Development Standards

## 1. Scope And Platform

Mac Utilities is a native SwiftUI/AppKit application for this arm64 MacBook, targeting macOS 26.6 and later. The [PRD](../mac-utilities-prd.md) owns product behavior. [Phase 08](./phase-08-shared-architecture-foundation.md) records the shared architecture and canonical storage contract. Completed earlier phases remain historical implementation evidence.

## 2. Source Ownership

| Directory | Responsibility |
| :--- | :--- |
| `MacUtilities/App/` | App composition, delegate and singleton utility-window lifecycle |
| `MacUtilities/Features/Popover/` | Menu-bar label and popover |
| `MacUtilities/Features/Usage/` | Sampling/accounting coordination, history UI and projection publication |
| `MacUtilities/Features/Connection/` | User-started diagnostics, transient Wi-Fi quality presentation, and their models and monitors |
| `MacUtilities/Features/KeepAwake/` | Keep Awake session state, validated presets, preferences and utility presentation |
| `MacUtilities/Features/Notifications/` | Local notification preference, authorization, delivery and utility presentation |
| `MacUtilities/Features/Settings/` | Settings presentation |
| `MacUtilities/Platform/` | AppKit resources, network counters, read-only CoreWLAN access, native power assertions, processes, login items and canonical storage |
| `MacUtilities/UI/` | Shared host typography, cards, controls, spacing and tooltips |
| `MacUtilitiesWidgets/` | WidgetKit configuration, read-only timelines and family-adaptive saved-usage presentation |
| `Shared/` | Value types, calendar/range calculations, byte formatting, bounded projection reader and chart presentation |
| `Mac UtilitiesTests/` | Usage, Connection, Keep Awake, Notifications and Window regression suites |

Dependencies flow from app/features into platform adapters and shared values. `Shared/` must not import AppKit, ServiceManagement, collection code, process execution or canonical writers. Its presentation file may import SwiftUI; storage/model files use Foundation. Explicitly isolate pure types from the host's default MainActor and use valid Sendable value contracts. No framework/package target is needed for these local sources.

## 3. Runtime Ownership And Storage

- One `UsageMonitor` owns collection while the app is open, including when all views are closed. One `ConnectionDiagnostics` owns manual checks; the singleton window owns presentation and close-time diagnostic cleanup.
- One `WiFiQualityMonitor` owns transient CoreWLAN sampling. Its serial reader actor retains one `CWWiFiClient` and uses only interfaces vended by that client. Refresh every five seconds only while the Connection surface is visible; hide, close, wake and termination invalidate old results. Never write Wi-Fi values to `Shared/`, `UsageStateStore` or the widget projection.
- One app-lifetime `KeepAwakeController` owns the selected preset, active session, last ended session and its outcome, deadline/timer, validated preferences and all power-assertion identifiers. UI surfaces bind to that controller and never own assertions or timeout tasks. Closing the popover or utility window does not stop a session. Stop, replacement, finite expiration and both application-termination paths cancel stale tasks and release each successful assertion exactly once. Relaunch starts inactive; never persist active state, last-session details or outcomes, deadlines, assertion IDs or errors.
- Keep Awake always owns a native idle-system assertion while active and may own a separate idle-display assertion when the saved Keep Display On preference is enabled. Create them through one `MacUtilities/Platform/Power/` adapter; do not spawn `caffeinate`, install a helper, request user activity, or claim to override lid closure, explicit/system sleep, low power or thermal decisions. A display-only failure must not terminate a valid base session. Keep Awake preferences use isolated standard preferences and never enter usage storage, the App Group ledger, `Shared/`, or widget data.
- `StabilityCheckSession` is an owned child of that diagnostic controller, not another app-level service. Its continuous clock controls the fixed five-minute deadline; `ConnectionObservationEvents` supplies run-scoped path and sleep context. Tag each probe operation, cancel and join interrupted pairs before recovery, and stop/release observers before returning idle. Terminal shutdown is one-way and rejects subsequent starts; AppKit termination waits for cleanup. Ordinary window closing cancels without retiring the controller.
- `UsageStateStore` owns canonical decoding, validation and atomic writes. `UsageWriterLease` holds a stable nonblocking lock until shutdown. A second writer must fail before collecting.
- Resolve the group using the built `MacUtilitiesAppGroupIdentifier` key and `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. Do not construct a production container path manually or fall back to legacy writes.
- Canonical data is `Library/Application Support/MacUtilities/today-usage.json` beneath that group. Schema 3 retains independent Today counters, daily history, checkpoints and timestamps. The optional schema-1 `widgetSnapshot` is derived from canonical history and committed in the same atomic replacement; there is no sidecar ledger.
- Shared limits are 9 MiB per envelope, 64 KiB per projection and 31 local-day projection records. Preserve valid core state if the optional projection is invalid; regenerate derived data. Protect unsupported/corrupt core data. A size/write failure preserves the last file and exposes a saving error without pruning history.
- The sole installation's usage history was copied into the shared canonical file before this implementation. Startup reads only that file; it does not resolve or import data from another location. An absent canonical file starts a new ledger. Retained backup files are never automatic recovery sources; restoring one requires an explicit recovery action with collection stopped.
- Reset Today preserves history. Clear History preserves Today and atomically clears the projection. Missing days are unknown, recorded zeroes are measured zero, and all totals remain observed traffic. `savedAt` is distinct from `lastObservedAt`.
- Publish commit callbacks only after a successful canonical write. The host owns one `WidgetReloadCoordinator`: ordinary observation changes coalesce to at most one targeted usage-widget reload per 30 minutes; successful clear, unit and local-day/time-zone commits request an immediate reload. WidgetKit controls when requests appear on screen. Shut down pending reload work with the app.
- The widget reads only the bounded embedded projection through `UsageWidgetSnapshotReader`; it never collects, writes, repairs, starts diagnostics or falls back to legacy storage. Saved and last-observed timestamps remain separate. Keep extension source membership explicit and extension API checks enabled; share only extension-safe values, readers and presentation calculations.

## 4. UI Conventions

### 4.1 Shared utility-module system

All utility-window modules use the shared shell and controls:

- `UtilityScrollContent` owns the 20-point page padding, 24-point section spacing and 10-point content spacing.
- `UtilityPanel` owns one Title Case heading, an optional subtitle, one optional inline action, an optional explanation card and an optional content card.
- Shared cards use 12-point padding. Use `UtilityStyle`, `UtilityControls.swift`, shared rows, tooltips and pointer behavior; do not create feature-specific style systems.
- Keep the utility window readable at 620 × 420, 860 × 660 and, where needed, 1100 × 800. The popover remains compact and closes when the utility window opens.
- Sidebar order and shortcuts are fixed: Connection (Command-1), Keep Awake (Command-2), Usage (Command-3), Notifications (Command-4) and Settings (Command-5).

A section heading contains one semantic Title Case heading. A small native switch, picker or primary action may sit inline on the trailing edge. Keep actions keyboard reachable, expose meaningful accessibility labels and values, and apply the shared pointing-hand cursor when enabled.

### 4.2 Descriptions, content and status

- Put explanations in one rounded description card directly below the heading. Show up to two rendered lines, then a right-aligned native Read More / Read Less button when the text overflows. Measure overflow at the current width and font size; keep the expanded/collapsed value accessible.
- Keep warnings, errors, confirmations and result values fully visible. Do not apply the description truncation rule to them.
- Content cards contain actual rows, metrics, charts, editors or controls. Hide conditional content until it has meaningful loading, result, empty-state or error content; never render an empty rounded card.
- Do not duplicate a description, status, error or nested result card when the heading or status row already supplies that context.
- Use the shared `UtilityCapabilityCard` for durable capability states, as Settings and Notifications do: one full-width rounded card with an icon, concise label and optional right-aligned recovery actions that wrap when narrow. Green `checkmark.circle.fill` means ready/active; orange `exclamationmark.circle.fill` means unavailable, denied or failed. Use an action such as `Open Settings` only when it can address the cause; do not add a generic Retry without a defined retry and deduplication contract.
- Modules without a durable capability state keep their action-specific results and timestamps in their owning panels.

### 4.3 Rows, controls and state truthfulness

- Use `UtilityValueRow` for label/value state, `UtilityMetricRow` for aligned measurements and `UtilityTimestampRow` for `Last Checked`, `Last Updated` and `Last Ran`.
- Match the shared timestamp icon, color, format and detail order. Use success styling only for a completed or currently healthy state; use warning styling for incomplete, unavailable, cancelled or failed outcomes.
- Preserve distinct outcomes. Never label a cancelled, replaced, timed-out or failed operation `Completed`.
- Prefer native SwiftUI controls with the shared small switch and control-size conventions. App-owned buttons, switches, pickers and expandable description actions use the hand cursor; disabled controls keep the arrow cursor.
- Clicking outside a text field ends editing. Numeric fields select their complete value on focus, and validation appears beside the affected editor. Keep keyboard focus, selected values, on/off values and VoiceOver labels meaningful.

### 4.4 Connection and stability

- Connection checks use `ConnectionServerCards`: one card per endpoint, equal columns when they fit and matching stacked cards when narrow. Do not wrap them in another results card or add dividers between endpoints.
- Both checks use `ConnectionReplyMetrics` with the same row order and labels. Use `UtilityMetricRow` for label/value alignment and keep metric-specific explanations inline.
- Keep the Reply Times timeline inside the five-minute check and put its shared `Last Checked` row after the chart. Shared chart legend and selection tokens belong to `UtilityStyle.Chart`.
- Description cards cover Wi-Fi Signal And Link, Reply Time And Missed Replies, 5-Minute Connection Check, Reply Times and Internet Speed While Busy using the shared overflow behavior. Connection headings do not use info icons.
- Stability timelines use centralized neutral colors, distinct symbols/dashes, coverage breaks and a labeled confirmed-miss lane. Unobserved runs show reasons and gaps without a fabricated latency chart. Keep elapsed/remaining time, Missed and Cancel outside the scrolling results; Missed explains that a probe could not run and is shown only for the last started check. Tooltips and keyboard/accessibility inspection expose the same observations, and labels must not overlap axes.

### 4.5 Keep Awake

The popover is control-only and appears after Current Speed and before Today's Usage: heading, synchronized native small switch and two-to-four equal-width enabled preset buttons. It has no description, status sentence, Keep Display On control, info icon or separate Start/Stop button. Preserve the existing inactive rate string; active sessions prefix `☾ <remaining>` or `☾ ∞` with one em space and no separator dot.

The utility window owns the full module:

- Keep the synchronized small switch inline with the Keep Awake heading.
- Keep Current Session separate and show a transient `Last Ran` row after it.
- Place Keep Display On before Duration Presets with its switch inline and no description.
- Keep Restore Defaults outside the presets card.
- Show preset name, left-side minute field/unit and a right-side small switch without a table header. Select the complete minute value on focus and end editing when the user clicks elsewhere.
- Use `checkmark.circle.fill` with the shared success color for `Last Ran`, include the start time and selected duration, and show the real outcome. Use `Completed` only after a finite session reaches its captured deadline. Use `Cancelled` for manual stop, replacement, Until Stopped stop and application quit. A failed assertion start does not create a new Last Ran entry; outcomes disappear on relaunch. When replacement follows an active session, the previous session remains `Cancelled`.
- Defaults are 30 Min, 1 Hour, 2 Hours and Until Stopped. Require two-to-four unique enabled options, accept 1-1,440 whole minutes, count Until Stopped toward the minimum and save edits when editing ends/Return is pressed. Switch and Restore Defaults changes save immediately.
- Keep Display On exists only in the utility window, persists for later sessions and applies live to an active session. Preference edits must not rewrite an active session's captured deadline.
- Keep minute text monospaced. Increased popover height is acceptable, but preserve its width and inspect two, three and four enabled preset buttons on the target display.

### 4.6 Notifications

Notifications is a utility-window section after Usage and before Settings. Use one Settings-style capability card, one master switch named `Enable Notifications` inline with the section heading, and one concise event description. Permission/recovery actions and progress appear only in the capability card. Distinguish permission-request failures from delivery failures. Follow the permission actions and bounded manual delivery retry contract in [Notification System Conventions](../conventions/notification-system.md#61-utility-window). Do not add a second switch, duplicate detail line or conditional error card.

The master preference is `notifications.enabled.v1`, defaulting off, with one-time migration from `notifications.keepAwakeTimer.v1`. Request `.alert` and `.sound` only after explicit enable while authorization is undetermined. Re-read authorization, alert, sound and Notification Center settings; keep the switch off when authorization is denied or no delivery surface remains. A finite Keep Awake expiration makes one immediate local attempt after assertion cleanup; manual stop, replacement, Until Stopped, quit, stale callbacks and cleanup failure remain silent. Use `Keep Awake Finished` and `<duration> session has ended.`, with no usage data. When the app is active, request the native banner and list presentation as well as background delivery; macOS settings and Focus may still suppress what the user sees. Do not add popover controls, future scheduling, APNs, critical/time-sensitive alerts, helpers or notification history. Future notification types follow [Notification System Conventions](../conventions/notification-system.md).

### 4.7 Usage, charts and widgets

- Usage Summary uses individual bordered metric cards without an enclosing card: Downloaded, Uploaded, Combined and a selection-labeled average. Place each icon beside its caption above the figure, emphasize Combined, arrange four cards horizontally when possible and use two columns at compact widths. The date range is an optional `UtilityPanel` subtitle with secondary metadata typography and two-digit years; do not add a separate average explanation.
- `UsageHistory.average` divides observed combined bytes by every calendar day in the selected range (7, 15, 30 or elapsed month days including today), keeps missing days in the divisor, handles overflow safely and preserves the existing no-data state. Summary totals are independent of chart visibility.
- Chart legends are shared plain buttons with Shown/Hidden accessibility values. Hidden layers remain available but dimmed, are excluded from chart scaling and inspection, and visibility starts with every layer shown. If all layers are hidden, show the shared empty state without axes or grid lines. Selected observations expose an accessibility value and named previous/next actions alongside arrow-key navigation; Usage exposes Previous Day / Next Day, Connection exposes Previous Result / Next Result, and Escape clears inspection. Share chart scale and series definitions through `UsageChartPresentation`.
- Widgets use native margins/backgrounds and semantic typography. Medium is a summary with a compact Average footer; Large adds 8 points of vertical padding and static stacked daily bars without a separate directional legend. Both show the saved range, accessible Last Reading timestamp and Downloaded/Uploaded/Combined columns with left/center/right alignment. Do not repeat the range in the Average label. Missing days are No Data and measured zero remains zero. Use the four existing ranges through Edit Widget, with no custom dropdown or chart gestures, and route `macutilities://usage?range=<stable-option-id>` through the singleton readiness queue; repeated links use a fresh generation and reset chart inspection, while normal startup opens no window.

### 4.8 Module state and verification

Before implementation or review, identify initial/waiting, active/ready, empty/no-data, recoverable warning/error, cancelled/replaced and disabled-by-preference states. Controllers own transitions and guard stale asynchronous results during visibility changes, cancellation and shutdown.

Verify every module in Light and Dark at supported sizes, including narrow layouts, keyboard navigation, VoiceOver labels/values, pointer behavior, text-field focus, empty/error/warning/recovery states and status truthfulness. Confirm that headings/actions align, no card is empty, timestamps align and no duplicate description/status/error text is visible.

The app does not provide text or system services; keep the Mac Utilities Services command group empty so unrelated providers do not appear in its menu.

## 5. Reproducible Project And Local Signing

`project.yml` is the tracked XcodeGen specification; `/MacUtilities.xcodeproj/` remains ignored. Use XcodeGen 2.46.0. Version/build belong in `Configuration/Version.xcconfig`. `Configuration/Build.xcconfig` loads the optional, exactly ignored `Configuration/Signing.local.xcconfig`; create it locally with `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY` and `MACUTILITIES_APP_GROUP_IDENTIFIER`. For the native macOS team-prefixed group, verify both the local team and group prefix against the built signature's TeamIdentifier; the development certificate's displayed suffix is not a substitute. A group correction changes the storage location: stop the writer, preserve a backup and transfer existing history before relaunching. No tracked signing example is required. Never commit personal signing values, certificates or private keys.

`Configuration/Info.plist` is preprocessed and merged by Xcode. Its custom group key must be present in the built plist; arbitrary `INFOPLIST_KEY_` settings alone do not reliably emit custom keys. Only Debug includes the optional UUID verification namespace. Entitlements use the same local group setting. Release contains no verification namespace key.

```sh
xcodegen generate --spec project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-foundation CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-foundation build
codesign --verify --deep --strict '/tmp/mac-utilities-foundation/Build/Products/Release/Mac Utilities.app'
```

The ad-hoc test command proves injected regressions, not App Group authorization. Verify matching signed entitlements, built group configuration and actual sandboxed container read/write before changing this setup. The supported route is a local Apple Development signature with the documented team-prefixed macOS group form; public distribution/notarization is outside this scope. Do not change the stable group without a separate data-transfer design.

## 6. Verification And Privacy

Hosted Usage, Connection, Keep Awake and Window tests use temporary URLs and isolated preferences/login adapters, with parallel hosted execution disabled. Never point tests at personal history or change Start At Login during tests. Keep clocks, counter readers, process runners and storage roots injectable. A failed startup or verification-only launch must not claim active monitoring.

Keep Awake tests use isolated `UserDefaults`, fake clocks/date providers and a fake power-assertion adapter; hosted tests never create a real assertion or change system sleep settings. Debug previews inject fake assertions and isolated preferences. Release contains no preview route or synthetic session. Signed native verification may inspect the app's named assertions read-only while starting/stopping the requested session, but must restore inactive state and prove cleanup after timeout and quit. Controller and presentation tests also distinguish `Completed` from `Cancelled` Last Ran outcomes, cover replacement and quit reasons, and confirm that failed starts do not create a Last Ran entry.

Notification tests use an injected local client and isolated preferences. They verify the master preference migration, explicit opt-in authorization, denied or externally disabled alert and Notification Center states, the single combined status card and state-specific actions, exact private-data-free content, one attempt per finite session generation, native foreground banner/list options, response routing and no delivery for cancellation, replacement, quit, Until Stopped or assertion-cleanup failure. The host registers one `UNUserNotificationCenterDelegate` through the app-lifetime controller; Release adds no APNs, critical-alert or time-sensitive entitlement and does not schedule future notification requests. Native delivery remains subject to user authorization, Focus and Notification Center policy.

Stability tests use virtual continuous time for the five-minute deadline and 60-slot cap and injected events/probes for interruption boundaries. Opt-in `StabilitySignedIntegrationTests` run only when the test scheme receives build setting `MACUTILITIES_SIGNED_STABILITY_CHECK=1`; use the verified local signature, not ad-hoc signing, for that gate. They include a real five-minute run, bounded no-reply validation against a reserved documentation address, real child cancellation and process-local workspace notification checks. These notifications do not sleep the computer or change its network settings. Default test runs skip real long checks.

Phase 10 reads optional Wi-Fi signal, noise, channel and link-rate values through the sandboxed, transient CoreWLAN path. Do not request Location access or call APIs for SSID/BSSID, scanning, association or Wi-Fi configuration. A signed preview does not install or replace the existing app. CoreWLAN values may be unavailable on a particular run.

Debug-only previews expose named state parameters so each module can be inspected without changing production data or macOS settings. `--usage-preview=<state>` opens Usage with disposable synthetic history; supported states are `history`, `empty`, `zero`, `counter-error` and `storage-error`. `--usage-preview-light`, `--usage-preview-compact` and `--usage-preview-expanded` exercise appearance and window sizing. `--settings-preview=<state>` opens Settings using the same isolated UsageMonitor; supported states are `active` and `unavailable`, with matching `--settings-preview-light`, `--settings-preview-compact` and `--settings-preview-expanded` variants.

`--stability-preview=<state>` opens Connection with synthetic results and an isolated usage monitor, without live probes or production collection. Supported states are `complete`, `sparse`, `unobserved`, `running` and `cancelled`; the existing `--stability-preview-sparse` and `--stability-preview-unobserved` aliases remain supported. Optional `--stability-preview-light`, `--stability-preview-compact` and `--stability-preview-expanded` flags exercise appearance and sizing. `--keep-awake-preview=<state>` opens Keep Awake with isolated preferences and a fake assertion adapter; supported states are `idle`, `active`, `until-stopped`, `completed`, `cancelled`, `display-on`, `error`, `display-error`, `preference-error`, `two-presets` and `three-presets`. The existing Keep Awake state flags remain supported, along with light/compact/expanded variants.

`--notification-preview=<state>` opens Notifications with isolated synthetic preferences and an injected notification client; supported states are `off`, `active`, `denied`, `alerts-disabled`, `notification-center-disabled`, `sound-disabled`, `requesting` and `delivery-error`. Optional `--notification-preview-light`, `--notification-preview-compact` and `--notification-preview-expanded` flags exercise appearance and sizing. Release contains no preview route.

A namespaced Debug `--usage-preview` publishes its synthetic canonical state and projection into that UUID namespace before requesting a targeted widget reload. Add `--usage-preview-large-envelope` only for the near-9-MiB native resource gate; it pads an unused canonical explanation, never the consumed projection, and is ignored without a verification namespace. Relaunch the ordinary usage preview afterward to restore the small fixture.

Builds and hosted tests can register temporary host/extension bundles even without a manual preview installation. After the final build/test or preview launch, quit task-owned app copies, unregister their exact host paths with `lsregister -u`, then register the installed host and embedded extension again. Check that PlugInKit lists only the intended installed extension and verify the actual Edit Widgets gallery shows both families; registration output alone is insufficient. If widget-service logs show a missing containing bundle or stale executable, refresh the verified widget-service process and repeat gallery/runtime checks. Do not remove preferences, widget placements or usage data. A subsequent build/test invalidates this final discovery check and requires it again.

For widget verification, verify both host and embedded extension signatures, matching nonempty teams and group entitlements, then prove an OS-launched extension can read host-published synthetic usage in the same Debug-only UUID namespace. Host authorization alone is insufficient. Keep Release free of verification keys and preview routes. Add Usage History from the macOS widget gallery and use Edit Widget to choose a range; collection requires the host app to remain open. Widget refresh timing is system-controlled, and saved readings retain their original observation time when the host quits. After replacing a preview with the installed Release, verify gallery discovery and an OS-launched extension at the installed path before declaring installation complete. PlugInKit registration alone is insufficient: launchd can retain the removed preview executable under chronod. If logs confirm that stale path, refresh the widget service and recheck installed-path launch and both family timelines; do not delete widget preferences, layouts or usage data.

For signed native fixture checks, build Debug with a fresh UUID `MACUTILITIES_VERIFICATION_NAMESPACE` and supply synthetic saved state in that namespace. A normal launch of that verification build shows the saved fixture without sampling. Remove only its UUID namespace after quitting it. Never use the namespace as a production fallback; Release rejects any nonempty namespace supplied to the resolver.

Review the entire changed source/config set, run the phase's regression and signed integration gates, verify generator idempotency and inspect compact/default/expanded native layouts. Preserve private rollback backups outside Git. Confirm no duplicate app/test processes remain. Use the update-docs workflow to revise current authoritative contracts in place; preserve chronological logs and completed phase records.
