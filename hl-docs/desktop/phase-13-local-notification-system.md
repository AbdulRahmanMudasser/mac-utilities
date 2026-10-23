# Phase 13 - Local Notification System

## 1. Phase Purpose

Add an opt-in macOS notification for a finite Keep Awake timer while keeping notification delivery separate from power-assertion ownership. The app remains a menu-bar utility with one host-owned session controller, no helper process, no remote notification service, and no change to usage or widget storage.

## 2. Feature Objective

- **Phase Goal:** Let the user enable a native notification when a timed Keep Awake session finishes.
- **User Or System Outcome:** The user opens the `Notifications` utility section, turns on the `Enable Notifications` master switch, and the app makes one concise local notification delivery attempt when a finite session expires; visible presentation remains subject to macOS authorization and delivery policy.
- **In Scope:** A top-level Notifications utility section; a saved notification preference; explicit notification authorization; one app-lifetime notification controller; a UserNotifications platform adapter; an expiration-only Keep Awake event; foreground/background handling; notification-click routing to Keep Awake; isolated tests and signed runtime verification.
- **Out Of Scope:** Remote push/APNs, notification service extensions, critical or time-sensitive alerts, scheduled notifications that survive an app crash, notification actions beyond opening the related Keep Awake section, badges, notification history, usage/widget notifications, automatic Keep Awake starts, helper processes, `caffeinate`, closed-lid behavior, and active-session restoration after relaunch.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Desktop Execution Workflow](./execution-workflow.md)
- **Product Source:** Current approved decisions in this task and the [Mac Utilities PRD](../mac-utilities-prd.md). The PRD now records the approved local notification behavior; remote push, helper processes and notification history remain out of scope.
- **Prerequisites (Blocked By):** Completed [Phase 12](./phase-12-keep-awake-control.md) for the app-lifetime Keep Awake deadline, expiration, outcome-aware Last Ran state and utility-window conventions. Also require completed [Phase 06](./phase-06-unified-utility-window.md) for the reusable sidebar/window and completed [Phase 08](./phase-08-shared-architecture-foundation.md) for composition, signing and isolated-test conventions.
- **Downstream Tasks (Unlocks):** Not applicable.
- **Target Git Commit Prefix:** `feat(notification-system): ...`
- **Project Profile(s):** Native macOS SwiftUI/AppKit host application using UserNotifications for local delivery (high confidence).
- **Applicable Development Standards:** [Desktop Development Standards Sections 2-6](./development-standards.md), especially app-lifetime ownership, platform adapters, isolated preferences, utility-window conventions, App Sandbox/signing checks and termination cleanup. Future notification additions also follow the [Notification System Conventions](../conventions/notification-system.md) guide.
- **Platform References:** Apple [User Notifications](https://developer.apple.com/documentation/usernotifications), [local notification scheduling](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app), [authorization](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:)), [notification settings](https://developer.apple.com/documentation/usernotifications/unnotificationsettings), and [foreground presentation](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter%28_%3Awillpresent%3Awithcompletionhandler%3A).

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Keep Awake journey, functional requirements, controls/preferences, window lifecycle, notification scope, persistence boundaries and support readiness.
- **Related Build Plan Section:** Not applicable; the execution workflow owns delivery sequencing.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** None. Tests use an injected notification client and isolated `UserDefaults` suites.
- **Database/Index Changes:** Not applicable. Store only the notification preference in dedicated local preferences. Do not write notification state, active sessions or delivery history to `UsageStateStore`, the App Group ledger, widget projection or `Shared/`.
- **Feature Flags / Config Switches:** Debug-only `--notification-preview=<state>` uses isolated preferences and an injected notification client to inspect `off`, `active`, `denied`, `alerts-disabled`, `notification-center-disabled`, `sound-disabled`, `requesting` and `delivery-error` states; optional light, compact and expanded flags cover appearance and sizing. Release contains no notification preview route. Controller tests continue to use isolated preferences and fake clients; signed UI inspection uses the real system authorization state. Add the host `UserNotifications.framework` dependency only if the generated target requires an explicit link; do not add APNs or critical-alert entitlements.
- **Seed / Fixture Requirements:** Authorization states (not determined, authorized, denied), alert/Notification Center/sound surface combinations, notification preference off/on, finite 1-minute and normal-duration sessions, Until Stopped, expiration after workspace wake, manual stop, replacement, quit, delivery failure, and notification-click routing.
- **Required Reusable Utilities:** Reuse `UtilityScrollContent`, `UtilityPanel`, `UtilityStyle`, `UtilitySection`, `UtilityWindowCoordinator`, `AppDelegate`, injected `UserDefaults`, the existing Keep Awake clock and session-generation guards. Keep UserNotifications behind one platform adapter and keep notification formatting out of `Shared/`.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** No network endpoint. The host emits one `keepAwakeTimerFinished` event only when a finite Keep Awake session reaches its captured monotonic deadline. The event is handed to the local notification client for one immediate delivery attempt to the current macOS user's Notification Center through `UNUserNotificationCenter`.
- **Utility Window Contract:** Add `.notifications = "Notifications"` before `.settings` in `UtilitySection`. Keep Connection Command-1, Keep Awake Command-2 and Usage Command-3; assign Notifications Command-4 and Settings Command-5. Render a new `NotificationsView` for the section.
- **Preference Contract:** Persist the Notifications master switch as `notifications.enabled.v1` in the injected standard-preferences suite, defaulting to `false`. On first read, migrate the released `notifications.keepAwakeTimer.v1` value once and never write the legacy key again. On an explicit enable, query current settings and call `requestAuthorization` for `.alert` and `.sound` only while authorization is `.notDetermined`; a denial turns the master switch back off, keeps the unavailable capability state visible and does not trigger repeated prompts until the user changes System Settings. Recheck settings when the app becomes active. The capability state must include authorization, alert, sound and Notification Center availability: an authorized app remains deliverable when Notification Center is enabled even if alert banners are disabled, and sound-disabled is an active state with a secondary detail; only the absence of every delivery surface is unavailable. Do not persist active-session state, notification delivery history or pending requests.
- **Notification Content Contract:** Recipient is the current macOS user only. Title is `Keep Awake Finished`. Body is `<duration> session has ended.` where `<duration>` is a notification-friendly singular/plural rendering of the captured timed `KeepAwakeDuration`, for example `30-minute`, `1-hour` or `2-hour`; `Until Stopped` never produces this event. Use sentence-style body text, no badge, no private usage data and the system default sound when sound authorization is enabled. Attach a per-session event UUID and captured duration in `userInfo`; use that UUID with the session generation in the request identifier so the generation remains an in-process guard rather than a globally stable identifier. Do not add a remote payload or custom notification category in this phase.
- **Delivery Contract:** The notification client makes one immediate local delivery attempt when the controller resolves the expiration transition; it must not schedule a future request at session start. Capture the expiring session before invalidating its generation, release its display and system assertions synchronously, and emit only when that cleanup succeeds. This keeps the monotonic Keep Awake controller authoritative and avoids stale scheduled alerts after a crash or normal quit. A finite session that reaches its deadline after sleep/wake makes one attempt when `reconcileAfterWake` resolves it. `Until Stopped`, manual stop, replacement, quit, assertion-creation failure and release failure do not emit a finish notification. macOS authorization, Focus, sound settings and delivery policy can still prevent the user from seeing the attempted notification.
- **Preference Changes During a Session:** If the user enables the preference before a finite session expires, the expiration event is eligible; if the user disables it before expiry, no notification is sent. Changing the preference never changes the captured session deadline.
- **Response Contract:** A default notification click opens or foregrounds the existing Keep Awake utility section and leaves the transient Last Ran row, including its `Completed` expiration outcome, as the related in-app detail. The current `AppDelegate` stores only a pending `UsageRoute` and delivers it through `presentUsage(range:)`; extend that readiness route with a typed Keep Awake destination (or an equivalent separate one-shot route), deliver it through the existing `UtilityWindowCoordinator.present(.keepAwake)`, and consume it once when the utility window is ready. No custom action button is added.
- **Deduplication Contract:** Use the Keep Awake session generation only for in-process identity and pair it with a fresh event UUID for the request identifier and payload. Mark the initial expiration attempt before awaiting delivery so timer/wake races cannot submit duplicates. Only an explicit manual retry of the retained failed payload may submit again, using the same identity and original five-minute deadline. Explicit stop/replacement/quit paths invalidate the generation before cleanup, and stale timer callbacks must remain unable to emit. A newer session invalidates the retained retry and its callbacks. If an explicit stop or replacement is processed before the expiration transition on the main actor, it wins and no finish attempt is made.

## 7. UX / Behavioral Expectations

- **Utility Window:** Add a `Notifications` sidebar item before Settings. The section uses the same scroll, spacing and description-card patterns as Connection and Usage. Lead with one Settings-style readiness/monitoring status card that contains the state icon, one concise state label and a right-aligned `Open Settings` action when permission or System Settings recovery is actionable. The card owns permission and delivery state; do not render a second detail line or error card. Use the state-specific permission actions and bounded manual `Retry Delivery` contract in Notification System Conventions Section 6.1. Follow it with a `Notifications` `UtilityPanel` whose native small `Enable Notifications` master switch is inline on the right side of the panel heading and which has no duplicate visible description. Follow that with a `Keep Awake Timer` `UtilityPanel` containing only the short description `Shows a macOS notification when a timed Keep Awake session ends.`; it has no second switch or conditional error content. Do not add a notification control to the Keep Awake popover.
- **System Behavior:** Notifications are off on first launch. Finite expiration remains owned by `KeepAwakeController`; `NotificationsController` owns preference, authorization, formatting and delivery. The app remains active in the menu bar and no background helper is introduced.
- **Foreground Behavior:** `KeepAwakeController` updates Last Ran with the `Completed` outcome when it resolves the finite expiration. `UNUserNotificationCenterDelegate` requests native banner/list presentation, including while the app is active; macOS alert settings, Focus and Notification Center policy may still suppress or delay what is visible. A click routes to Keep Awake.
- **Error States To Support:** Permission not determined, authorization denied, alert/Notification Center/sound disabled in System Settings, local-delivery failure, notification controller shutdown, stale expiration callback, wake-after-deadline, manual stop, replacement and quit. Permission and delivery state are represented by the single top status card. A notification failure must never keep a power assertion alive or mark a successfully expired session as failed.
- **Accessibility / Platform Constraints:** Use native switches/buttons, Title Case labels, keyboard focus, meaningful master-switch and capability values, and accessible labels for the status action and current authorization state. Keep the section readable at the existing 620 x 420, 860 x 660 and 1100 x 800 sizes in Light and Dark appearances. Do not request Critical Alerts, Time Sensitive delivery, remote push, location, network or additional App Sandbox permissions.

## 8. Acceptance Criteria

- Permission actions and manual delivery retries follow [Notification System Conventions Section 6.1](../conventions/notification-system.md#61-utility-window): separate permission errors, serialize requests, retain only the latest failed payload for five minutes, reuse its identity and invalidate retries on a newer session, disable, success or quit. Isolated tests verify races, expiry, refresh preservation and recovery actions; native recovery-button inspection remains pending. These additions are included in installed Release 1.7.1 (23).
- The utility sidebar shows `Notifications` before Settings, with Command-4; Connection, Keep Awake and Usage remain Commands 1–3, and Settings moves to Command-5.
- `Enable Notifications` is off by default, migrates the prior Keep Awake notification preference, requests authorization only when enabled, and exposes an honest denied/disabled state in the single top status card with `Open Settings` when recovery is actionable, without changing the Keep Awake session.
- One immediate local delivery attempt is made for one finite expiration when the preference and authorization are enabled; its title/body match the content contract and contain no usage data, while visible presentation remains subject to macOS notification policy.
- No notification delivery attempt is made for Until Stopped, manual stop, preset replacement, quit, assertion-creation failure, release failure or stale timer callbacks.
- Enabling or disabling the preference during an active finite session affects only whether the eventual expiration delivery attempt is made; it never changes the captured deadline.
- A notification click opens the Keep Awake utility section through a queued, single-consumption route when necessary; no custom action or second window is created.
- When the Keep Awake utility section is visible in the frontmost app, presentation is suppressed in favor of the existing Last Ran UI; otherwise native Notification Center behavior is used subject to user settings and Focus.
- Notification code is isolated from usage storage, widget projection, power assertions and the extension. Release contains no APNs/critical-alert entitlement and no Debug notification route.
- The signed arm64 build, affected tests, permission-state inspection, expiration/cleanup checks and Light/Dark utility layouts all pass before the phase is marked completed.

## 9. Implementation Steps (Component Audit)

### A. Notification Platform Adapter

- [NEW] `MacUtilities/Platform/Notifications/UserNotificationClient.swift`:
  - **Target Anchor:** Existing `UserNotificationClient` adapter and its injected `LocalNotificationClient` contract; all UserNotifications access remains behind this boundary.
  - [x] Define an injectable protocol for authorization status, authorization request and immediate local delivery. Because this phase never schedules a future request, the protocol needs no pending-request removal API.
  - [x] Implement the `UNUserNotificationCenter` adapter with `.alert` and `.sound` authorization, no APNs registration, no critical-alert options and no future pending timer request.
  - [x] Return typed authorization/delivery errors without exposing `UNUserNotificationCenter` to SwiftUI views or `KeepAwakeController` tests.
  - [x] Include `notificationCenterSetting` in the injected capability state so the UI can distinguish full delivery availability from an authorized app whose delivery surfaces are disabled.
  - [x] Add an injected/testable `Open Settings` action that opens macOS System Settings → Notifications with the Mac Utilities app entry selected, then falls back to the Notifications pane or System Settings app when the deep link is unavailable; keep AppKit settings-launching code out of SwiftUI.

### B. Notification Feature And Host Composition

- [NEW] `MacUtilities/Features/Notifications/NotificationsModels.swift`:
  - **Target Anchor:** New feature-owned event and authorization values; keep these out of `Shared/`.
  - [x] Define the persisted preference key, authorization state, `keepAwakeTimerFinished` event identity, captured duration payload and stable content strings.
  - [x] Add the `notifications.enabled.v1` master key, one-time legacy-key migration, capability-state values and state-specific recovery action values without persisting delivery history.
- [NEW] `MacUtilities/Features/Notifications/NotificationsController.swift`:
  - **Target Anchor:** App-lifetime observable-service pattern used by `KeepAwakeController`, `UsageMonitor` and `ConnectionDiagnostics`.
  - [x] Own the saved opt-in switch, authorization refresh, one-attempt-per-session-generation guard, foreground delegate behavior, concise error state and Keep Awake response route.
  - [x] Keep the native client injected for isolated tests; do not own power assertions, session deadlines or usage data.
  - [x] Separate master preference state from capability state, preserve denied/disabled capability state after the switch returns off, refresh settings through the `Open Settings` status action, and apply the approved transient manual retry contract.
- [MODIFY] `MacUtilities/Features/KeepAwake/KeepAwakeModels.swift`, `MacUtilities/Features/KeepAwake/KeepAwakeView.swift`:
  - **Target Anchor:** `KeepAwakeSessionSnapshot`, `KeepAwakeView`'s transient `lastSession` row and the shared `UtilityTimestampRow` convention.
  - [x] Add an explicit transient ended-session outcome/reason value to the Last Ran model. Use `Completed` only for natural finite expiry and `Cancelled` for manual stop, replacement, Until Stopped stop and quit; a failed assertion start must not create a new outcome.
  - [x] Replace the Keep Awake row's `hourglass` override with the shared `checkmark.circle.fill` / success-color presentation and include the outcome without persisting it.
- [MODIFY] `MacUtilities/Features/KeepAwake/KeepAwakeController.swift`:
  - **Target Anchor:** `startSession(using:)`, `stopSession()`, `reconcileTimer(...)` and `reconcileAfterWake()`.
  - [x] Inject a narrow timer-finished notifier and pass an explicit session outcome/reason through expiration, manual stop, replacement, quit and failure paths; preserve the prior session's `Cancelled` outcome if a replacement start then fails.
  - [x] Capture the expiring session before invalidating its generation, release both assertions synchronously, mark the one-shot attempt before awaiting delivery, and notify only after cleanup succeeds; never notify from stale callbacks, shutdown paths or a release failure.
- [MODIFY] `MacUtilities/App/Mac_UtilitiesApp.swift`, `MacUtilities/App/AppDelegate.swift`:
  - **Target Anchor:** Existing app-lifetime service creation, environment injection, accessory lifecycle, `applicationDidFinishLaunching`, `applicationDidBecomeActive`, the current `UsageRoute` readiness queue, and `UtilityWindowCoordinator`'s reusable section presentation.
  - [x] Create one `NotificationsController`, inject it into `KeepAwakeController`, `NotificationsView` and the app delegate, and register the notification delegate before launch completes.
  - [x] Forward notification responses to the controller, queue its Keep Awake destination alongside the current Usage route until window readiness, refresh authorization on app activation, and shut down the notification controller idempotently from both termination paths.
  - [x] Configure the notification delegate to request native banner/list foreground presentation without coupling it to utility-window selection or creating a controller/window retain cycle.
- [MODIFY] `project.yml`:
  - **Target Anchor:** Recursive `MacUtilities` host source membership and host SDK dependencies.
  - [x] Keep new host files in the recursive source group; add `UserNotifications.framework` only if the generated target requires explicit linking. Do not add the extension, App Group, APNs or critical-alert capabilities.

### C. Utility Window Presentation

- [MODIFY] `MacUtilities/App/UtilityWindow.swift`:
  - **Target Anchor:** `UtilitySection`, `shortcut`, sidebar `ForEach` and section switch in `UtilityWindowView`.
  - [x] Insert `.notifications = "Notifications"` before `.settings`, assign Command-4 to Notifications and Command-5 to Settings, and render `NotificationsView`.
- [MODIFY] `MacUtilities/Features/Notifications/NotificationsView.swift`:
  - **Target Anchor:** Existing `KeepAwakeView` utility panels and shared `UtilityScrollContent`/`UtilityPanel` conventions.
  - [x] Replace the Keep Awake-specific switch with one inline `Enable Notifications` master switch in a Notifications panel with no duplicate visible description; keep the Keep Awake Timer panel description-only.
  - [x] Collapse permission and delivery state into one top status card with a right-side `Open Settings` action for denied or externally disabled delivery; show state-specific permission/retry actions in the same card; remove the second detail line and conditional error card.
  - [x] Expose separate accessibility values for master switch state and notification capability state, and make no popover changes.

### D. Tests And Documentation

- [NEW] `Mac UtilitiesTests/Notifications/NotificationsControllerTests.swift` and `Mac UtilitiesTests/Notifications/NotificationsPresentationTests.swift`:
  - **Target Anchor:** Existing Swift Testing suites, isolated preferences and hosted presentation tests.
  - [x] Cover default-off behavior, authorization request/denial, externally disabled alert/sound settings, settings refresh, exact content, native foreground banner/list presentation, one initial failed attempt with bounded manual retry, response routing and one delivery attempt per generation; keep controller/authorization/delivery assertions separate from presentation coverage, and host the real view at 620 x 420, 860 x 660 and 1100 x 800 in Light and Dark. Stale-callback and native response presentation remain covered by the controller guards and the installed-path inspection.
  - [x] Add migration coverage for `notifications.keepAwakeTimer.v1`, Notification Center-disabled capability coverage, master-switch/status-card action coverage including the injected settings opener, and the absence of a second conditional error card.
- [MODIFY] `Mac UtilitiesTests/KeepAwake/KeepAwakeControllerTests.swift`:
  - **Target Anchor:** `KeepAwakeTestHarness`, fake clock and expiration/wake/stop/replacement tests.
  - [x] Inject a fake notifier and prove exactly one expiration attempt, including expiry after wake; prove `Completed` for natural finite expiry, `Cancelled` with the correct reason for manual stop/replacement/Until Stopped stop/quit, no new Last Ran outcome after assertion-creation failure, no attempt for non-expiration paths or release failure, preference changes during a session, stale callback suppression, and the main-actor race where an explicit stop or replacement arrives before versus after the deadline transition.
- [MODIFY] `Mac UtilitiesTests/KeepAwake/KeepAwakePresentationTests.swift`:
  - **Target Anchor:** Existing isolated Keep Awake view hosting and Light/Dark size checks.
  - [x] Verify the Last Ran row uses the shared checkmark icon/success color, displays `Completed` or `Cancelled` honestly, and clears after relaunch; preserve the current popover and utility-window size coverage.
- [MODIFY] `Mac UtilitiesTests/Window/UtilityWindowTests.swift`:
  - **Target Anchor:** `startupDoesNotCreateAWindow`, `presentingUtilityDismissesOnlyItsPopover`, `firstRequestSelectsRequestedSection`, `UtilitySection.allCases` and `utilitySectionsUseSequentialKeyboardShortcuts`.
  - [x] Add Notifications to the sidebar order and section switch, preserve Commands 1–3, assert Command-4 for Notifications and Command-5 for Settings, and verify a notification response arriving before readiness opens the existing utility window's Keep Awake section once.
- [MODIFY] PRD, desktop development standards and execution workflow during implementation:
  - [x] Reconcile notifications from the current PRD out-of-scope list into the approved product behavior, record the ownership/UI/persistence decisions in the standards, and update the current workflow register. Preserve the chronological decision and execution logs; native installed-path delivery evidence remains pending before the phase is marked completed.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Notification authorization can be denied or changed externally; macOS may suppress foreground presentation despite an accepted request; a stale generation could deliver a false finish message; adding a sidebar section can accidentally renumber existing shortcuts; local notification delivery is not guaranteed by macOS.
- **Operational Risks:** Focus, Notification Center settings, sound settings and system delivery policy can delay or suppress the alert. The feature does not guarantee delivery, wake a sleeping Mac, override Focus, or continue a session after quit. A notification failure must not affect assertion cleanup or usage collection.
- **Rollback Approach:** Turn the preference off, remove the Notifications sidebar section/controller/adapter, remove only the dedicated preference key, and revert the PRD/standards/workflow entries. Keep Keep Awake power assertions, presets, Last Ran, usage history, widgets and App Group data unchanged.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Generation Command:** `xcodegen generate --spec project.yml` if the host dependency changes.
- **Exact Regression Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-notifications CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Result:** Passed 226 tests in 17 suites after permission recovery and manual retry changes; the two existing opt-in stability integration tests were skipped. `git diff --check` also passed.
- **Targeted Tests:** New Notifications controller/presentation tests, affected Keep Awake controller tests and `UtilityWindowTests`. Tests use fake notification clients, fake clocks and isolated preferences; they never request real notification permission or send a real user notification.
- **Signed Integration Build:** Passed signed arm64 Debug and Release builds. Both bundles have strict signatures, the existing `7VZNSW83KX.com.abdulrahman.mac-utilities.shared` App Group and matching team `7VZNSW83KX`, no APNs/critical-alert entitlement, and no `keep-awake-preview` string in the built executable. Release 1.7.1 (23) now replaces the prior installed bundle at `~/Applications/Mac Utilities.app`; the user confirmed that native notification authorization and delivery are working in the installed app.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Default | Launch or relaunch the app | Notifications section is present; `Enable Notifications` is off; no permission prompt appears; Keep Awake remains off | Controller tests and signed UI inspection |
| First Enable | Open Notifications and enable `Enable Notifications` | macOS authorization prompt appears once; accepted state is shown; denied state leaves the master switch off and keeps the concise state label plus `Open Settings` action in the top status card | Native signed inspection and authorization-state evidence |
| Finite Expiration | Enable notifications, start a finite Keep Awake session, let it expire | One immediate delivery attempt uses the exact title/body; Last Ran updates with `Completed` and the shared checkmark presentation; power assertions release; visible presentation follows macOS policy | Fake-client tests, signed runtime, Notification Center inspection |
| Until Stopped | Enable notifications and run Until Stopped | No finish notification delivery attempt is made while it remains active or when manually stopped | Controller tests and runtime inspection |
| Stop / Replace / Quit | Stop, replace, or quit before a finite deadline | No finish notification; no scheduled request remains; Last Ran records `Cancelled` with the applicable reason and assertion cleanup remains correct | Controller tests and `pmset -g assertions`/Notification Center evidence |
| Wake / Stale Callback | Sleep/wake after a deadline or resume an old timer callback | At most one expiration delivery attempt; stale generation cannot notify or release a replacement session | Virtual-time tests and signed wake inspection |
| Foreground / Background | Expire with the app active or hidden | Keep Awake updates Last Ran with `Completed`; the delegate requests native banner/list presentation in both cases, subject to macOS settings and Focus | Controller/delegate tests and native UI inspection |
| Response | Click the delivered notification | Existing Mac Utilities window opens or foregrounds Keep Awake once; no second window or repeated route | Notification response test and native interaction evidence |
| Layout / Accessibility | Inspect 620 x 420, 860 x 660 and 1100 x 800 in Light/Dark; keyboard/VoiceOver | Sidebar and Notifications panel fit, shortcuts remain correct, switch state/permission values are exposed and errors remain visible | Signed Debug screenshots and accessibility inspection |

### C. Evidence To Capture

- Generated target/dependency graph, targeted/full test output, signed Debug/Release builds, strict signature and entitlement comparison, and Release-string inspection for preview-only routes.
- Native Notifications utility screenshots for off and authorized states in Light and Dark appearances, plus hosted presentation evidence for denied and delivery-error states.
- A controlled short finite session showing one delivery attempt and, when macOS policy allows, one Notification Center alert; the `Completed` Last Ran update with the shared checkmark presentation; assertion cleanup; and `Cancelled` Last Ran outcomes with no attempt for manual stop/replacement/quit.
- Keyboard navigation, VoiceOver labels/values, existing Command-1 through Command-3 behavior, new Command-4 Notifications behavior, Command-5 Settings behavior, and confirmation that usage storage/widgets remain unchanged.

## 12. Execution Notes

- **Status:** Implemented; installed Release and native notification delivery verified; final accessibility inspection pending
- **Started At:** 2026-10-22
- **Completed At:** Not completed
- **Blockers Encountered:** No implementation blockers. Final Light/Dark accessibility inspection remains open.
- **Notes:** The app-lifetime `NotificationsController` owns the `notifications.enabled.v1` opt-in preference, one-time legacy migration, authorization refresh, one-attempt guard, foreground delegate and response route; `UserNotificationClient` is the only UserNotifications adapter. Keep Awake remains authoritative for deadlines and assertion cleanup. Automated coverage and signed Debug/Release checks pass; the signed Release 1.7.1 (23) is installed and its embedded widget is registered. The user confirmed that native notification authorization and delivery are working; final accessibility inspection remains separate.
