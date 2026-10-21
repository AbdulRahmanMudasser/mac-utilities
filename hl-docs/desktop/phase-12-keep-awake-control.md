# Phase 12 - Keep Awake Control

## 1. Phase Purpose

Add a user-controlled Keep Awake session to the existing menu-bar popover and shared utility window. Use macOS power assertions owned by the host app, keep active sessions transient, and expose configurable duration presets without starting a helper process or changing usage collection.

## 2. Feature Objective

- **Phase Goal:** Let the user keep the Mac awake for a selected duration or until stopped, with an optional saved Keep Display On preference.
- **User Or System Outcome:** Start and stop one clearly visible sleep-prevention session from the popover, inspect it in the utility window, and choose which duration presets appear.
- **In Scope:** One app-lifetime session controller; native IOKit idle-system and optional idle-display assertions; transient timed/until-stopped sessions; a popover master switch and two-to-four configurable presets; a Keep Awake utility section; saved preset/display preferences; synchronized state; active menu-bar duration; lifecycle, accessibility, preview, signed-runtime, and regression verification.
- **Out Of Scope:** Closed-lid overrides, automatic triggers, schedules, process/network/battery detection, restoring an active session after relaunch, remote control, notifications, a background helper, a second menu-bar item, spawning `caffeinate`, or changing usage collection and widget behavior.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Desktop Execution Workflow](./execution-workflow.md)
- **Product Source:** Current approved decisions in this task and the [Mac Utilities PRD](../mac-utilities-prd.md).
- **Prerequisites (Blocked By):** Completed [Phase 06](./phase-06-unified-utility-window.md) for the reusable window/sidebar and completed [Phase 08](./phase-08-shared-architecture-foundation.md) for current composition, signing, preview isolation, and test conventions. Phase 11 remains completed and is not a runtime dependency.
- **Downstream Tasks (Unlocks):** Not applicable.
- **Target Git Commit Prefix:** `feat(keep-awake): ...`
- **Project Profile(s):** Native macOS SwiftUI/AppKit host application with IOKit power-management integration (high confidence).
- **Applicable Development Standards:** [Desktop Development Standards Sections 2-6](./development-standards.md), especially app-lifetime ownership, shared utility presentation, isolated preferences/previews, signed runtime checks, and termination cleanup.
- **Platform References:** Apple [idle-system assertion](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep), [idle-display assertion](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep), [assertion creation](https://developer.apple.com/documentation/iokit/iopmassertioncreatewithproperties), and [paired release](https://developer.apple.com/documentation/iokit/iopmassertionrelease).

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** Keep Awake journey, platform scope, controls/preferences, window lifecycle, functional requirements, acceptance criteria, persistence boundaries, and support readiness.
- **Related Build Plan Section:** Not applicable; the execution workflow owns delivery sequencing.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** None. Tests inject a fake assertion adapter, monotonic clock, wall-date provider, and isolated `UserDefaults` suite.
- **Database/Index Changes:** Not applicable. Active sessions stay in memory; preset and Keep Display On preferences use bounded local preferences rather than usage storage.
- **Feature Flags / Config Switches:** Add IOKit to the generated host target. Add Debug-only `--keep-awake-preview`, `--keep-awake-preview-active`, `--keep-awake-preview-until-stopped`, `--keep-awake-preview-light`, `--keep-awake-preview-compact`, `--keep-awake-preview-expanded`, `--keep-awake-preview-two-presets`, and `--keep-awake-preview-three-presets` arguments. The base route opens `.keepAwake`; variants select deterministic isolated states. Every Keep Awake preview uses isolated preferences, a fake assertion adapter, a non-sampling isolated `UsageMonitor`, and no widget reload request. Release must exclude preview routing and synthetic state.
- **Seed / Fixture Requirements:** Default preferences; two, three, and four enabled presets; duplicate/out-of-range values; finite and Until Stopped sessions; assertion creation/release failures; delayed timeout; wake after deadline; immediate and delayed app termination.
- **Required Reusable Utilities:** Reuse `UtilityScrollContent`, `UtilityPanel`, `UtilityStyle`, existing sidebar/window coordination, app composition, AppDelegate shutdown, injected `UserDefaults`, and the current menu-bar typography. Use SwiftUI's native switch presentation for both master controls; `HandCursorToggleStyle` is a custom button treatment and is not the Keep Awake switch style. Keep power assertions out of `UsageMonitor` and `Shared/`.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** No network endpoint. User actions start, replace, or stop one process-owned Keep Awake session. A finite session owns an absolute deadline; Until Stopped owns no deadline. Closing the popover or utility window does not stop the session.
- **Preset Contract:** Store three ordered editable timed slots plus the fixed Until Stopped option. Defaults are 30 minutes, 1 hour, 2 hours, and Until Stopped. Each timed slot accepts 1-1,440 whole minutes. Exactly two to four unique presets must be enabled; Until Stopped counts toward the minimum. Disable the uncheck action when it would leave fewer than two enabled options, reject duplicate timed values, preserve order, and offer Restore Defaults. Valid minute edits save automatically when editing ends or Return is pressed; switches and Restore Defaults save immediately. If an idle selected preset becomes hidden, select the first enabled preset. Preference changes update the popover immediately but do not change a running session's captured duration or deadline.
- **Session Contract:** The app starts with no active session, regardless of saved preferences, and initially selects the first enabled preset. Selection is transient. Turning the popover or utility switch on starts the currently selected preset. Selecting another preset while active replaces the current session with that duration after first releasing its assertions. Turning either synchronized switch off stops it. Finite expiration, explicit stop, app termination, or assertion-start failure returns both switches to off. Until Stopped ends only through stop, replacement, quit, or process exit. Sessions do not resume after relaunch.
- **Power Contract:** `PowerAssertionClient` creates `kIOPMAssertionTypePreventUserIdleSystemSleep` through `IOPMAssertionCreateWithProperties` for every session and sends one `IOPMAssertionRelease` call for every successfully created ID. Give the base and optional display assertions distinct stable names for signed inspection. When Keep Display On is enabled, own a second `kIOPMAssertionTypePreventUserIdleDisplaySleep` assertion and create/release it live without restarting the base session. Give finite assertions the same native timeout as a safety bound with `kIOPMAssertionTimeoutActionTurnOff`; never use the automatic Release timeout action, because the controller remains responsible for releasing the ID. A display-assertion creation failure keeps the base session active and exposes a warning in the utility section; a base-assertion creation failure leaves the session off. If a release call fails, retain an actionable cleanup error, refuse another start that could compound assertion ownership, and rely on process termination as the final OS cleanup boundary. Do not request user activity, prevent manual/low-power/lid sleep, or claim that assertions override macOS.
- **Timing Contract:** Capture an injected monotonic deadline for expiration and a separate wall-clock end date for display. Use one cancellable controller-owned timer. On delayed callbacks and workspace wake, compare the monotonic clock to the captured monotonic deadline before publishing active state; wall-clock changes must not lengthen or shorten the session. Publish minute-granularity remaining text and schedule updates at minute boundaries; do not let UI refresh tasks own assertions.
- **Persistence Contract:** Save only validated preset configuration and Keep Display On in dedicated standard-preferences keys. Do not write active state, deadlines, assertion IDs, timers, or errors to `UsageStateStore`, the App Group ledger, widget projection, or `Shared/`. Corrupt or incomplete preferences fall back atomically to the four defaults.
- **Menu-Bar Contract:** Preserve the existing rate string and single rate-unit suffix. While a finite session is active, prefix it with `☾ <remaining>`; Until Stopped prefixes `☾ ∞`. Follow either state with one em space before the unchanged speed string. Never use a separator dot. When inactive, render the existing rate text unchanged.

## 7. UX / Behavioral Expectations

- **Menu Bar Popover:** Place Keep Awake after Current Speed and before Today's Usage. Show only the Title Case heading, synchronized native switch, and two-to-four equal-width enabled preset buttons. Show no section description, instructional/status sentence, Keep Display On control, info icon, or separate Start/Stop button. The switch starts/stops the selected preset. Each duration button needs a clear selected appearance plus an `.isSelected` accessibility trait/value; do not claim an existing popover selection treatment because none exists for this control. Increasing popover height is acceptable; preserve its width and inspect fit on the target display.
- **Utility Window:** Add Keep Awake as the second sidebar section, ordered after Connection and before Usage, with sequential shortcuts: Connection Command-1, Keep Awake Command-2, Usage Command-3, and Settings Command-4. Use the normal `UtilityScrollContent` and `UtilityPanel` conventions. Put the synchronized small switch inline with the module heading and keep the concise module description below it. Show Current Session without a duplicate switch. Place Keep Display On next with an inline small switch and no description. Put Duration Presets last, with compact rows and Restore Defaults outside the card.
- **Dynamic Behavior:** Both master switches share one controller. The utility window reflects popover starts/stops immediately. Keep Display On is absent from the popover, saved for future sessions, and applies immediately to an active session. Preset configuration updates the idle popover immediately; the active session continues with its captured deadline until stopped, expired, or replaced.
- **Error States To Support:** Base/display assertion creation failure, either assertion's release failure, invalid/corrupt preferences, fewer than two attempted enabled presets, duplicate/out-of-range timed values, delayed timeout, wake after deadline, and repeated start/stop/quit. A release failure keeps an actionable cleanup error visible and blocks another start until relaunch. Keep the popover control-only; show concise actionable failures in the utility section and accessible help/state rather than adding popover description text.
- **Accessibility / Platform Constraints:** Use native switches/buttons/fields, Title Case, keyboard focus, and meaningful visible selected/on/off states. Keep the utility module readable at 620 x 420, 860 x 660, and 1100 x 800 in Light and Dark appearances. The assertion is an OS request; macOS can still sleep for lid closure, explicit Sleep, low power, thermal conditions, or other reasons.

## 8. Acceptance Criteria

- The app starts and relaunches with Keep Awake off; no assertion exists until the user turns on a master switch.
- The popover shows two to four configured presets, no description or Keep Display On control, and synchronized selection/switch state.
- Defaults are 30 Min, 1 Hour, 2 Hours, and Until Stopped. The utility editor enforces two-to-four visible unique presets, timed values from 1 minute through 24 hours, stable order, immediate idle-popover updates, and default restoration.
- Finite sessions expire at their captured deadline; Until Stopped remains active until stopped or quit. Editing presets does not alter the running session; selecting another visible preset replaces it deliberately.
- Keep Display On is configured only in the utility section, persists locally, applies to new sessions, and creates/releases its optional assertion immediately during an active session without interrupting the base assertion.
- Closing either UI surface leaves the app-lifetime session running. Stop, timeout, replacement, and both termination paths send one release call for every successfully created assertion and suppress stale timer callbacks; a failed release is reported and blocks another start until relaunch.
- Active menu-bar text places the duration directly before the unchanged speed string with no separator dot. Inactive text remains byte-for-byte equivalent to the current rate-only formatting.
- The signed sandboxed build demonstrates named host-owned assertions while active and no surviving assertion after stop, timeout, or quit. No `caffeinate` child, helper, new entitlement, usage-ledger write, widget dependency, or closed-lid promise is introduced.

## 9. Implementation Steps (Component Audit)

### A. Models, Preferences, And Session Ownership

- [NEW] `MacUtilities/Features/KeepAwake/KeepAwakeModels.swift`:
  - **Target Anchor:** No Keep Awake model or general preset contract currently exists.
  - [x] Define stable preset IDs, timed/Until Stopped values, default configuration, enabled ordering, bounds/duplicate validation, display titles, and immutable active-session snapshots.
- [NEW] `MacUtilities/Features/KeepAwake/KeepAwakeController.swift`:
  - **Target Anchor:** Follow the app-lifetime observable/injected-dependency pattern used by `UsageMonitor` and `WiFiQualityMonitor`, without coupling to either feature.
  - [x] Own validated preferences, transient selected preset, monotonic session deadline, separate display end date, minute-boundary updates, wake reconciliation, synchronized switch state, assertion errors, and idempotent shutdown. Persist only presets and Keep Display On through injected `UserDefaults`.
  - [x] Start, replace, expire, stop, and live-update the display assertion through one injected `PowerAsserting` adapter. Cancel/invalidate old timers before publishing a replacement session and ignore stale callbacks by session generation.

### B. Native Power Adapter And Composition

- [NEW] `MacUtilities/Platform/Power/PowerAssertionClient.swift`; [MODIFY] `project.yml`:
  - **Target Anchor:** `MacUtilities/Platform/` owns macOS adapters; the generated host target currently has no IOKit dependency or power abstraction.
  - [x] Define the minimal injectable assertion protocol and IOKit implementation. Inject the create/release function boundary so hosted adapter tests never create a real assertion. Create descriptive property dictionaries with distinct system/display names, return typed IDs/errors, apply native finite timeouts with the Turn Off action, and send one release call for every successful ID. Link IOKit to the host target only; recursive source membership already includes the new host files, so do not add extension membership, permissions, or a helper executable.
- [MODIFY] `MacUtilities/App/Mac_UtilitiesApp.swift`, `MacUtilities/App/AppDelegate.swift`:
  - **Target Anchor:** Existing app composition creates all app-lifetime services and injects them into the popover/window; AppDelegate coordinates immediate and delayed termination cleanup.
  - [x] Create one `KeepAwakeController`, inject it into the popover, menu label, and utility view, and expose it to AppDelegate. Shut it down at the start of `applicationShouldTerminate(_:)` before either `.terminateNow` or the diagnostic `.terminateLater` wait, and again idempotently in `applicationWillTerminate(_:)`. In `applicationDidFinishLaunching(_:)`, route the exact Debug arguments from Section 5 through the existing coordinator to `.keepAwake`; app composition must pair those routes with isolated preferences, fake assertions, a non-sampling isolated usage monitor, and no widget reload. Release creates only the real adapter.

### C. Popover And Menu-Bar Presentation

- [MODIFY] `MacUtilities/Features/Popover/ContentView.swift`:
  - **Target Anchor:** Existing fixed-width popover orders Connection, Current Speed, Today's Usage, then footer.
  - [x] Insert a control-only Keep Awake section between Current Speed and Today's Usage with the native master switch and enabled preset buttons. Reflow two, three, or four equal-width buttons without descriptions, Keep Display On, status copy, or a second action. Give the selected button a visible state and native selected accessibility semantics. Keep existing Connection, Usage, Settings, Reset, and Quit behavior unchanged.
- [MODIFY] `MacUtilities/Features/Popover/MenuBarStatusLabel.swift`, `MacUtilities/App/Mac_UtilitiesApp.swift`:
  - **Target Anchor:** `UsageMonitor.menuBarText` owns only rate formatting and `MenuBarStatusLabel` currently renders that supplied text.
  - [x] Compose the controller's transient prefix with the unchanged usage-rate string at the menu-label boundary. Use monospaced minute text, an infinity symbol for Until Stopped, an em space before rates, no separator dot, and no Keep Awake state inside `UsageMonitor`.

### D. Utility Window Module

- [MODIFY] `MacUtilities/App/UtilityWindow.swift`; [NEW] `MacUtilities/Features/KeepAwake/KeepAwakeView.swift`:
  - **Target Anchor:** `UtilitySection`, `UtilityWindowView`, singleton window presentation, sidebar enumeration, and existing shared `UtilityScrollContent`/`UtilityPanel` components.
  - [x] Add `.keepAwake`, update the shortcut mappings to Connection Command-1, Keep Awake Command-2, Usage Command-3, and Settings Command-4, and render the sidebar in the order Connection, Keep Awake, Usage, Settings. Closing/navigating must not stop its app-level session.
  - [x] Build the module description, Current Session, inline Keep Display On control, and compact Duration Presets editor with Restore Defaults outside its card. Bind controls directly to the controller, show validation/errors only in the utility module, and keep the layout responsive without a second style system.
### E. Tests And Documentation

- [NEW] `Mac UtilitiesTests/KeepAwake/KeepAwakeControllerTests.swift`, `Mac UtilitiesTests/KeepAwake/PowerAssertionClientTests.swift`:
  - **Target Anchor:** Existing Swift Testing host suite, injected clocks/operations, isolated preferences, and nonparallel host execution.
  - [x] Cover default-off/relaunch, first-enabled transient selection, default and restored presets, two-to-four enforcement, validation/fallback, persistence, selection changes, immutable active snapshots after edits, replace/stop/monotonic-timeout/wake, wall-clock changes, Until Stopped, live display changes, create/release errors, blocked restart after failed release, stale callbacks, and one release call per ID. Exercise both the immediate `.terminateNow` path and diagnostic `.terminateLater` path, followed by idempotent `applicationWillTerminate(_:)`. Never create a real assertion in automated tests.
- [MODIFY] `Mac UtilitiesTests/Window/UtilityWindowTests.swift`; [NEW] `Mac UtilitiesTests/KeepAwake/KeepAwakePresentationTests.swift`:
  - **Target Anchor:** Existing `UtilitySection.allCases`, shortcut, singleton-window, navigation, dismissal, termination, and multi-size tests.
  - [x] Update `UtilitySection.allCases` and shortcut expectations while retaining the existing parameterized presentation/dismissal coverage; verify one shared controller across popover/window/label, two/three/four-button formatting, visible and accessible selected state, no popover description/Keep Display On, inactive/finite/Until Stopped menu-label strings with no separator dot, and window close/navigation persistence. Inspect the real Keep Awake view at 620 x 420, 860 x 660, and 1100 x 800 in both appearances. Keep production preferences, assertions, usage storage, login settings, and widgets untouched.
- [MODIFY] PRD, desktop development standards, and execution workflow during implementation:
  - [x] Keep product behavior, power ownership, UI conventions, privacy boundaries, verification evidence, and phase status synchronized. Preserve chronological decision/execution logs unless a log entry is explicitly requested.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Leaked or double-released assertion IDs can leave incorrect power state; stale timers can turn off a replacement session; preference corruption can empty the popover; menu-label growth can reduce available status-bar space. Central ownership, generation checks, validation/fallback, paired release tests, and compact formatting mitigate these risks.
- **Operational Risks:** Power assertions are requests, not guarantees. macOS may still sleep for explicit sleep, lid closure, low power, thermal conditions, or other system reasons. Keeping the display on increases energy use. Signed runtime behavior must be checked on the target Mac rather than inferred from an ad-hoc build.
- **Rollback Approach:** Stop/release the controller, remove the Keep Awake UI/section and IOKit host dependency, and delete only its dedicated preference keys. Usage history, widget data, login settings, and other app preferences require no migration or rollback.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Generation Command:** `xcodegen generate --spec project.yml` after adding IOKit membership.
- **Exact Regression Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-keep-awake CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Targeted Tests:** New KeepAwake controller/adapter/presentation tests and affected `UtilityWindowTests`, followed by the existing suite once. Tests use fake assertions, virtual time, and isolated preferences; they never keep the test Mac awake.
- **Signed Integration Build:** Build Debug preview and Release with the verified local signing configuration. Verify strict signature, unchanged App Sandbox/App Group contract, IOKit host linkage, and absence of preview arguments/fixtures from Release before native runtime checks.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Default / Relaunch | Launch normally and relaunch after an active preview session | Both switches are off, the first enabled preset is selected, existing rate label is unchanged, and no assertion is active | Controller tests, signed process/assertion inspection |
| Preset Bounds | Enable/edit two, three, and four presets; attempt one, five, duplicates, zero, and over 24 hours | Valid sets appear in order; invalid changes are blocked/explained; defaults restore | Model tests and native Utility Window inspection |
| Finite Session | Select a timed preset and turn on from either surface | One base assertion, matching deadline/countdown, synchronized switches, and no separator dot before rates; expiration releases it | Virtual-time tests, AX/UI inspection, `pmset -g assertions` evidence |
| Until Stopped | Select Until Stopped, start, close both surfaces, and reopen | Session remains active without a countdown deadline and stops only on explicit stop/replace/quit | Controller/window tests and signed native inspection |
| Display Preference | Toggle Keep Display On idle and active | Preference persists; active display assertion changes immediately while base assertion remains active | Fake-adapter tests and signed assertion inspection |
| Edit During Session | Change/hide presets while a timed session runs, then select another visible preset | Existing deadline remains unchanged until a new preset is selected; deliberate selection safely replaces it | Controller/presentation tests |
| Failure / Cleanup | Inject create/release failure, delayed timer, wake after deadline, wall-clock change, repeated stop, normal quit, and diagnostic-delayed quit | Honest utility error, failed-release restart guard, no stale callback, and one release call for every successful ID | Unit tests, termination tests, signed runtime inspection |
| Layout / Interaction | Inspect popover and utility section at supported sizes and Light/Dark appearances with keyboard navigation | Two-to-four controls fit, utility details reflow, visible labels/states remain clear, and no popover description or display option appears | Signed Debug preview screenshots and keyboard-interaction evidence |

### C. Evidence To Capture

- Generated target/dependency graph, full and targeted test results, Debug/Release build results, strict signature and entitlement comparison, and Release-string inspection for preview-only routes.
- Native popover and utility-window screenshots for off, finite, Until Stopped, two-preset, three-preset, and four-preset states in Light/Dark and minimum/default/expanded window sizes.
- Read-only `pmset -g assertions` or equivalent process-owned assertion evidence while inactive, active, display-on, stopped, expired, and after quit. Do not change system sleep settings during verification.
- Keyboard navigation inspection, menu-label no-dot formatting, persistence/relaunch behavior, and confirmation that usage storage/widgets remain unchanged.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-21
- **Completed At:** 2026-10-22
- **Blockers Encountered:** None known.
- **Notes:** The host-owned controller, native IOKit adapter, synchronized popover and utility controls, configurable saved presets, Keep Display On preference, menu-bar state and Debug-only isolated preview are implemented. The full signed arm64 suite passed 190 tests across 15 suites with no failures. Native inspection of installed Release 1.5.0 (18) confirmed finite and Until Stopped system-sleep assertions, live display-sleep assertion changes, stop and quit cleanup, inactive relaunch, menu-label spacing, sequential shortcuts, and readable 620 x 420, 860 x 660 and 1100 x 800 layouts in Light and Dark. Host and widget signatures, teams, App Groups and versions match; Release excludes preview routes and verification configuration, the extension has no network entitlement, installed-path registration resolves only widget 1.5.0, and existing medium and large widgets rendered current canonical usage after replacement. The installed app preserved its usage ledger and starts with Keep Awake off.
