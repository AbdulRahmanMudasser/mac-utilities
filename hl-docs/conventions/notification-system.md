# Notification System Conventions

## 1. Purpose And Ownership

This document is the canonical design and engineering guide for adding future notifications to Mac Utilities. It defines how a notification is proposed, designed, implemented, tested and released. It is intentionally separate from phase plans, the execution workflow and chronological logs.

The current local notification implementation is the reference implementation:

- `NotificationsController` owns the saved preference, authorization state, delivery guard, foreground policy and response routing.
- `UserNotificationClient` is the only adapter allowed to call `UNUserNotificationCenter`.
- The feature that owns an event remains responsible for deciding when that event is real and whether it is complete, cancelled or stale.
- `AppDelegate` and `UtilityWindowCoordinator` own application activation and destination routing; notification code does not create a second window or a helper process.

Future notification work must extend these owners or document an approved exception. A new feature must not call `UNUserNotificationCenter` directly from a view, controller or model.

## 2. Scope And Platform Boundary

The supported baseline is an opt-in local notification delivered to the current macOS user through `UserNotifications`.

The baseline does not include:

- APNs, remote push, a server, a helper process or a launch daemon;
- critical, time-sensitive or bypass-Focus alerts;
- a notification that guarantees delivery, wakes the Mac or overrides Focus, sleep, thermal or power policy;
- a second copy of feature state in notification storage, usage history, the App Group ledger or widget data;
- a future scheduled request when the feature's source event is owned by the running host and cannot survive quit.

Any proposal outside this boundary requires a new product and platform decision before implementation.

## 3. When A Notification Is Appropriate

Add a notification only when all of these conditions are true:

1. The event is meaningful without opening the app immediately.
2. The event has a clear owner and a precise completion, cancellation and expiry definition.
3. The user can understand why the notification appeared and what action, if any, is available.
4. The event is not already visible through an active utility section, menu-bar state or existing Last Checked/Last Ran row unless the notification adds clear value.
5. The delivery can be deduplicated by a stable in-process event identity.
6. The feature can remain correct when authorization is denied, alerts are disabled, Focus suppresses delivery or the app is not running.

Do not notify for every sample, counter update, transient diagnostic result, missing reading or recoverable internal retry. Prefer an in-app state or an existing status row for information that does not require interruption.

## 4. Notification Categories And Lifecycle

Every proposal must identify its category before implementation:

| Category | Use | Baseline delivery | Additional decision required |
| --- | --- | --- | --- |
| Event completion | A user-started operation finished, such as a finite Keep Awake session | One immediate local attempt after the owner confirms completion | Event identity, cancellation rules and deep link |
| Action required | The user must make a decision to continue or recover | Local alert only when the action cannot be shown reliably in the active app | Action buttons, urgency and recovery behavior |
| State change | A durable condition changed and is useful outside the app | Prefer the utility window or menu bar; notify only when the change is actionable | Repetition, quiet periods and reset semantics |
| Reminder | A user explicitly requested a future reminder | Out of the current baseline; requires a persisted schedule and restart contract | Schedule ownership, time zone, persistence and cancellation |
| Remote event | An external service produced the event | Out of scope | Authentication, server contract, privacy, APNs and failure policy |

The implementation should model these states where they apply: `Proposed`, `Disabled`, `Authorization Pending`, `Authorized`, `Suppressed`, `Delivered`, `Failed`, `Cancelled` and `Expired`. The event owner must not report `Delivered` merely because a request was constructed; it means the local delivery attempt was accepted by the platform adapter. Native presentation can still be suppressed by macOS.

## 5. Product Decisions Required Before Coding

The request owner must answer every row before a new notification enters a plan. “Use the existing convention” is acceptable only when the row genuinely matches the current baseline.

| Decision | Question to answer | Existing baseline |
| --- | --- | --- |
| User value | What problem does this notification solve, and why is an in-app state insufficient? | It must provide useful information outside the active utility surface. |
| Trigger | What exact event causes it, and what proves the event completed? | The owning controller emits one domain event after its own cleanup succeeds. |
| Recipient | Which local user receives it? | The current macOS user only. |
| Opt-in | Is the notification off by default, and where does the user enable it? | Off by default; controls live in the Notifications utility section when a saved preference is needed. |
| Authorization | When is macOS permission requested, and what happens after denial? | Request `.alert` and `.sound` only after explicit enable while authorization is not determined; denial leaves the preference off. |
| Timing | Is delivery immediate, scheduled or repeated? | Immediate local delivery; no future request or repeating schedule. |
| Dedupe | What event ID or generation prevents duplicate delivery? | One monotonically increasing event generation per app lifetime. |
| Cancellation | Which stops, replacements, failures or stale callbacks suppress delivery? | The owner must explicitly list every non-completion path. |
| Content | What title, body, sound, badge and actions are needed? | Short sentence-style title/body, no badge, default sound only when authorized, no private data. |
| Foreground behavior | Should the user see the event while the app is active? | Request native banner and list presentation in the foreground; macOS alert settings, Focus and Notification Center policy still control what appears. |
| Destination | Where does a default click go? | Reuse the existing readiness queue and focus the relevant utility section once. |
| Privacy | Does the content reveal personal, network, usage or device data? | Include only the minimum event context; never include usage totals, raw identifiers or private payloads. |
| Persistence | What survives relaunch? | Persist only an explicit user preference or an approved schedule; do not persist delivery history by default. A global notification opt-in uses a namespaced master key; feature-specific switches may be added only when a second notification type needs independent control. Migrate an existing feature-specific key before removing it. |
| Accessibility | How are the setting, state, error and action exposed? | Native controls, Title Case labels, meaningful on/off and permission values, keyboard focus and VoiceOver descriptions. |
| Rollback | How can the feature be disabled without affecting the source operation? | Notification failure must never block the owning operation or cleanup. |

Unanswered rows are a planning blocker, not an implementation detail to infer later.

## 6. Utility-Window And Menu-Bar Presentation

### 6.1 Utility window

When a notification has a saved preference, authorization state or user-facing error, add or extend the `Notifications` utility section. Follow the existing section structure:

- lead with one full-width rounded status card that owns the current capability state;
- use a green `checkmark.circle.fill` for an active, deliverable state;
- use an orange `exclamationmark.circle.fill` for off, denied, unavailable or failed states;
- show one concise state label and, when recovery is actionable, a right-aligned native action in the same card; do not add an info icon in the section heading;
- for permission-request or delivery failures with an existing `errorMessage`, pass the title and explanation separately through `NotificationsController.capabilityMessage` as a `UtilityCapabilityMessage`; use [the shared capability-card layout](../desktop/development-standards.md#42-descriptions-content-and-status) for casing, spacing, icon alignment and wrapping. Do not add a visible detail line for generic fallback descriptions or ordinary off, pending, active, denied or unavailable states;
- use the same `UtilityPanel` structure as Connection and Usage; place one native small `Enable Notifications` master switch inline on the Notifications panel heading without a duplicate visible description;
- keep feature-specific panels description-only while only one notification type exists; add an event-specific switch only after a second independent notification preference is approved;
- use a native small switch with a pointing-hand cursor and an accessible on/off value;
- place permission, request-in-progress and delivery errors in the single status card; do not render a second error card or an empty conditional content card;
- Show `Open Settings` for authorized, denied and disabled-surface states, including preference-off with prior authorization. Show `Allow Notifications` before permission is requested and `Try Again` after a permission-request error; re-read settings before requesting and never re-prompt a denial. While a request is pending, show progress and prevent concurrent permission requests.
- Offer manual `Retry Delivery` only for the latest failed payload, retained in memory for five minutes from its original failure. Preserve its event/request identity, allow one attempt at a time, and recheck authorization. Clear it on success, disable, quit, expiry or a newer session starting. Never retry an accepted request merely because a banner was unseen. Keep recovery actions and progress inside the top status card;
- use shared `UtilityScrollContent`, `UtilityPanel`, `UtilityStyle`, spacing and card components;
- preserve the current sidebar order and keyboard shortcuts unless the approved feature decision changes them.

The status card communicates the current notification capability. It must not claim that macOS displayed a banner when the app only submitted a request. Model the user opt-in separately from capability: `Off`, `Permission Pending`, `Authorized`, `Denied`, `Delivery Surface Disabled` and `Delivery Failed` are capability states, while the master switch is the user preference. Read authorization, alert, sound and Notification Center settings before claiming that delivery is available. Keep authorization values and generic status explanations accessible; only actual permission-request and delivery failure explanations also appear visibly beneath the title in the same card. Do not repeat the state label in a second description or error card.

### 6.1.1 Master And Feature-Specific Controls

Use the scalable two-level preference model only when the app has multiple independent notification events:

- `Enable Notifications` is the global delivery master. It gates delivery for every notification type.
- Add a feature-specific switch only when a second independent notification type needs its own opt-in, such as a separate Usage or Connection notification. That switch controls only its own event category.
- When there is one notification type, do not add a sub-switch. Keep the event panel description-only, as the current Keep Awake Timer notification is.

### 6.2 Menu-bar popover

Do not add a notification switch or status row to the popover by default. The popover remains for compact, immediate controls owned by the feature. Add a notification affordance there only when the product decision proves that the control must be available without opening the utility window; if approved, it must reuse the same preference, authorization state, native small control and pointer behavior.

### 6.3 Notification content

Use concise Title Case UI labels and sentence-style notification copy. The title identifies the finished or actionable event; the body gives the minimum context. Avoid raw timestamps, UUIDs, usage totals, debug terminology and internal state names. A click should have one predictable destination or no action at all.

## 7. Architecture And Data Ownership

Use this flow:

```text
feature owner -> domain notification event -> NotificationsController
              -> authorization check -> UserNotificationClient
              -> macOS Notification Center
```

Rules:

- The feature owner decides whether the event completed naturally, was cancelled, was replaced or became stale.
- `NotificationsController` owns opt-in state, authorization refresh, formatting, deduplication, foreground presentation policy and response routing.
- `UserNotificationClient` translates the app value into `UNMutableNotificationContent` and an immediate `UNNotificationRequest`.
- Views bind to published controller state; they do not inspect `UNUserNotificationCenter`.
- Notification delivery is best-effort and must be isolated from usage storage, widget projection, power assertions and network collection.
- Use dependency injection for notification clients and preferences so tests never request real permission or send a real alert.
- Keep notification formatting and feature-specific event values out of `Shared/` unless a value is independently shared by another subsystem.

## 8. Privacy, Authorization And Platform Policy

Request only the authorization options required by the approved content. Do not request permission at launch or for an unrelated view visit. Reflect external changes to authorization when the app becomes active.

Notification payloads must contain the minimum event context and no sensitive usage, network, account or raw device identifiers. Do not add APNs, critical-alert, time-sensitive or network entitlements for a local feature. A notification failure must be visible as a concise error where useful but must never prevent cleanup, data collection or application shutdown.

The UI and documentation must state the platform limitation when relevant: macOS, Focus, Notification Center settings, sound settings, sleep and power conditions can suppress or delay delivery.

## 9. Testing And Verification Contract

Every new notification must add or update these checks:

### Controller and event tests

- default preference state and explicit opt-in;
- authorization request, denial and externally disabled alerts;
- exact title/body/action content with no private data;
- one delivery attempt for one event identity;
- stale, duplicate, cancelled, replaced, failed and shutdown paths;
- sound, badge and action behavior;
- foreground banner/list options and background eligibility;
- response routing through the existing window-readiness queue.

### Presentation tests

- utility-window bounds at 620 × 420, 860 × 660 and 1100 × 800;
- Light and Dark appearances;
- off, active, denied, unavailable and delivery-error states;
- keyboard focus, native switch values and VoiceOver labels;
- narrow layouts and fully visible warnings, including structured failure details and recovery actions;
- preservation of actual failure explanations without splitting strings at punctuation, and absence of invented or duplicate detail lines;
- shared capability-card wrapping in Light and Dark through `UtilityCapabilityCardTests`, with title/icon alignment and centered single-line recovery cards checked in native previews.

### Signed native checks

- matching host and extension signatures and App Group configuration where widgets are involved;
- installed-path authorization and Notification Center inspection when the feature requires user permission;
- one controlled event with the expected native behavior;
- no unexpected pending requests after cancellation, replacement or quit;
- Release excludes preview routes, verification keys and unapproved entitlements.

Do not claim native delivery from unit tests or a successful build alone.

## 10. Release, Migration And Rollback

Before release, verify the saved preference key, version/build, signed entitlements and installed bundle. Preserve existing user data and avoid changing the App Group for a notification-only feature. If a notification is disabled or rolled back, the owning feature must continue to work without it. Remove only the dedicated notification preference when a migration explicitly requires it; do not clear usage history, widget placement or unrelated settings.

## 11. Future Notification Proposal Template

Copy this checklist into the relevant plan before implementation:

```markdown
### Notification proposal: <short name>

- User value:
- Category:
- Owning event and completion proof:
- Recipient:
- Default state and setting location:
- Authorization options and denial behavior:
- Timing and repetition:
- Event identity and deduplication:
- Cancellation, replacement and stale-event rules:
- Title:
- Body:
- Sound, badge and actions:
- Foreground behavior:
- Click destination:
- Privacy review:
- Persistence and migration:
- Accessibility and localization:
- Test matrix:
- Signed/native verification:
- Rollback plan:
- Open decisions:
```

The proposal is ready for implementation only when `Open decisions` is empty or each remaining item has an explicit approved exception.

## 12. Current Reference Behavior

The current Keep Awake timer notification follows this convention: it is opt-in, local and immediate; it notifies only after a finite session reaches its deadline and assertions are cleaned up; it stays silent for manual stop, replacement, `Until Stopped`, quit, stale callbacks and cleanup failure; it uses a full-width status card in the Notifications utility section; and it contains no usage data or future scheduled request. Future notifications should reuse this structure unless an approved product or platform decision says otherwise.
