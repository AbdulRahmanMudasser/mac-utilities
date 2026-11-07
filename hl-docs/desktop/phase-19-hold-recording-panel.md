# Phase 19 - Hold-To-Record And Floating Transcription

## 1. Phase Purpose

Control implementation of this substantial delivery boundary. This document is a plan, not evidence of implementation. Approved conversation requirements govern the planned delta.

## 2. Feature Objective

- **Phase Goal:** Deliver configurable held-key recording and a voice-driven bottom-center panel using the existing single Transcribe session.
- **User Or System Outcome:** Deliver configurable held-key recording and a voice-driven bottom-center panel using the existing single Transcribe session.
- **In Scope:** Shortcut preferences and capture control, permission adapters, panel lifecycle, waveform, completed-text copy card, 30-second timer and isolated preview states.
- **Out Of Scope:** Automatic insertion belongs to Phase 20. Fn/Globe and modifier-only shortcuts, model changes and automatic language detection are excluded.

## 3. Current State And Implementation Delta

- **Verified Current Behavior:** `TranscribeFeatureController.startRecording()` and `stopRecording()` own preparation and stop actions through `TranscriptionSessionCoordinator`. `TranscribeView.swift` exposes the Language configuration and transcript/history UI. `AudioCaptureAdapter` has a bounded microphone tap/pipeline but no UI-level meter. `UtilityWindow.swift` owns the existing utility window, not a global dictation panel.
- **Verified Gap:** The scoped behavior is absent from the current sandboxed implementation.
- **Desired Implementation Delta:** Extend existing ownership and adapters as specified below; do not create a second speech engine or Usage writer.
- **Preserved Or Excluded Behavior:** Keep explicit English/Urdu language selection, pinned models, successful-only History, private local data and existing unrelated module behavior.

## 4. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md).
- **Prerequisites (Blocked By):** Phase 18 completed with backup/cutover evidence.
- **Downstream Tasks (Unlocks):** Phase 20.
- **Target Git Commit Prefix:** `feat(speech): ...`.
- **Project Profile:** Native macOS desktop, SwiftUI/AppKit, macOS 26.6+; sandboxed WidgetKit extension remains a separate responsibility.
- **Applicable Development Standards:** [Desktop Development Standards](./development-standards.md) §§2–3 ownership/storage, §4 UI, §5 signing and §6 privacy/verification; [Speech Transcription Conventions](../conventions/speech-transcription.md), especially §5 planned dictation contract.

## 5. Ownership And Delivery Notes

- **Owner / Priority / Target Window:** TBD.
- **Related PRD Section:** [FR-19 Local Speech Transcription](../mac-utilities-prd.md#fr-19-local-speech-transcription) defines the current transcription baseline; these phases specify the approved storage migration and global dictation extensions.
- **Related Build Plan Section:** Not applicable; no separate build plan is maintained for this scope.

## 6. Infrastructure & Environment Requirements

- **Environment Variables:** Reuse `DEVELOPER_DIR` and ignored local signing configuration from Standards §5; no new server or credentials.
- **Database/Index Changes:** Not applicable; existing local JSON stores remain.
- **Feature Flags / Config Switches:** User-configured shortcut enables global dictation; unconfigured/denied state preserves manual recording.
- **Seed / Fixture Requirements:** Isolated temporary roots, synthetic transcripts, fake clocks and injected platform adapters; never use production data in hosted tests.
- **Required Reusable Utilities:** Existing `TranscribeFeatureController`, `TranscriptionSessionCoordinator`, `UsageStoragePaths`, shared capability cards, timestamps and icon controls; native adapters stay in Platform.

## 7. API & Data Contract Specifications

HTTP request/response schemas are not applicable: this is a native local feature with no service.

Shortcut configuration stores schema version, hardware key code and normalized modifier mask; no binding is active until configured. Input events carry a session generation and pressed/released/cancelled edge. Repeats do not start sessions. Release during permission/model preparation cancels the pending start; release during recording stops capture then drains inference. Manual sessions and shortcut sessions have separate ownership tokens but share one capture/recognizer. Meter events contain generation plus normalized RMS/peak only, throttled to 20–30 Hz with a newest-value bounded channel. Panel states: hidden, preparing, recording, finalizing, result, error. Result expiry is 30 seconds from final availability; hovering/selecting pauses it.

Persist the binding in standard preferences as `speech.recordingShortcut.v1`, with schema version 1, a hardware key code and a normalized Command/Option/Control/Shift mask. Missing or invalid data means disabled, not a guessed default. The shortcut recorder suspends the active binding while capturing configuration; Escape abandons the edit and restores the previous binding, and Clear explicitly disables it. Validate only the supported modifier-plus-key form and stored value types before saving. The user chooses a non-overlapping binding; conflict detection, conflict warnings, reserved-shortcut lists and automatic remapping are outside scope. Observe the binding without suppressing, rewriting or consuming its events in the focused application. A binding change invalidates its old input generation. This is the approved event policy, not an unresolved implementation decision.

Session transitions are idle → preparing → recording → finalizing → result/error → idle/hidden. Only the matching held-token release can transition preparing/recording; release in finalizing is ignored. Sleep, monitor failure, lost authorization or shutdown invalidate the token and cancel owned capture/preparation. A new press during preparing/recording/finalizing is ignored; a new press after result cancels the previous dismissal timer and starts a new generation. No-speech completion returns to ready/hidden without an empty result card or History entry. The complete-result event includes generation, selected language and text; its delivery is independent of History success. Transient failures use the same specific error-domain titles as the utility module.

## 8. UX / Behavioral Expectations

Recording Shortcut sits below Language using existing configuration styles. Show a black rounded capsule above the Dock on the focused-window display, or pointer display when no destination exists. Use a nonactivating NSPanel and SwiftUI content without changing foreground app. Animate smoothed voice-level bars, provide a quiet baseline and Reduce Motion behavior. Expand final text within bounded dimensions, then scroll; include Copy and Close. Closing the utility window does not end recording. Escape cancels the shortcut session. Errors retain actionable recovery; no empty or failed History entries.

Permissions remain user-controlled. Keep private audio, transcripts, clipboard contents and destination field contents out of logs, repository fixtures and public evidence. No screen-recording permission or screen capture is required for this design.

## 9. Acceptance Criteria

- **AC1:** Press and release work across other apps and inside Mac Utilities; auto-repeat, missed release, permission loss and stale callbacks cannot leave capture active.
- **AC2:** A key released during preparation never starts recording later; another trigger cannot stop a manual session.
- **AC3:** Waveform follows measured audio level without blocking the audio callback or adding persistent audio.
- **AC4:** The floating card shows final text for 30 seconds, pauses during interaction, supports Copy/Close, and saves complete text to ordinary History.
- **AC5:** English/Urdu layout, VoiceOver, Reduce Motion, Light/Dark surroundings, multiple displays and Spaces are verified.

## 10. Requirement Traceability

| Requirement | Planned Implementation | Affected Files / Symbols | Acceptance Criteria | Verification Evidence |
| :--- | :--- | :--- | :--- | :--- |
| P19-1: Configurable global held shortcut | Validated binding and generation-tagged input edges | GlobalRecordingShortcut (new); RecordingShortcutPreferences (new); TranscribeView configuration | AC1 | Global/local delivery without event suppression, repeat, lost-release and permission regressions |
| P19-2: Release cancels preparation safely | Extend existing start/stop/cancel ownership | TranscribeFeatureController; TranscriptionSessionCoordinator | AC2 | Permission/model-load hold-release and manual/global conflict tests |
| P19-3: Voice-responsive waveform | Bounded meter from accepted audio worker buffers | AudioCapturePipeline.receive; AudioCaptureStream; panel presentation | AC3 | Known PCM level fixtures, bounded publication and native meter inspection |
| P19-4: Timed final transcript card | Panel state and transient Copy action independent of History row | TranscriptionPanelController (new); TranscriptionPanelView (new); controller pasteboard action | AC4 | Timer pause/resume, copy failure, finalization and empty/error tests |
| P19-5: Accessible native overlay | Nonactivating AppKit panel with shared styles and isolated fixtures | AppDelegate; Mac_UtilitiesApp; UtilityWindowCoordinator; TranscribePreviewDependencies | AC5 | English/Urdu, keyboard/VoiceOver, display/Space and shutdown walkthrough |
| Explicit exclusions | Automatic insertion belongs to Phase 20. Fn/Globe and modifier-only shortcuts, model changes and automatic language detection are excluded. | No implementation in this phase | Scope boundary | Diff review |

## 11. Implementation Steps (Component Audit)

### A. MacUtilities/Platform/Input/GlobalRecordingShortcut.swift

- **NEW:** `MacUtilities/Platform/Input/GlobalRecordingShortcut.swift`, `MacUtilities/Features/Speech/RecordingShortcutPreferences.swift`.
- **Target Anchor:** Platform input adapter and feature-owned validated preference value.
- [ ] Implement configurable modifier-plus-key edges, local/global coverage without duplicate delivery, passive observation and event-monitor disable recovery. Request only required Input Monitoring/Accessibility access when enabling. Do not preinstall a binding or implement overlap management; the user is responsible for avoiding conflicts. Remove monitors on shutdown and cancel owned sessions on sleep, permission loss or lost-event recovery.

### B. MacUtilities/Features/Speech/TranscribeFeatureController.swift

- **MODIFY:** `MacUtilities/Features/Speech/TranscribeFeatureController.swift`, `MacUtilities/Features/Speech/TranscriptionSessionCoordinator.swift`, `MacUtilities/Features/Speech/TranscribeView.swift`, `MacUtilities/App/Mac_UtilitiesApp.swift`, `MacUtilities/App/AppDelegate.swift`.
- **Target Anchor:** Existing actions, generation ownership, configuration card and app lifetime composition.
- [ ] Route shortcut and manual controls through the same controller. Add explicit origin/session token and release-before-ready cancellation. Lock shortcut editing while active. Compose one app-lifetime shortcut adapter and panel controller; join cleanup before termination. Keep readiness/action availability coherent.
- [ ] Set the held intent and token synchronously before scheduling `startActionTask`; release invalidates that intent even before `performStartRecording()` creates `leaseRun`. Check it before model preparation, permission requests and `coordinator.start()`. The existing no-lease stop path is insufficient for this race. Deduplicate input edges by binding/generation and clear held state when a monitor is disabled or loses access. `AppDelegate.applicationDidBecomeActive` currently only refreshes microphone presentation: extend permission refresh to cancel an active shortcut session on loss, without treating missing global-input authorization as missing manual-recording permission.
- [ ] Extend `TranscribeViewModel`, `TranscribeViewActions` and `TranscribeCapabilityAction` in `TranscribeView.swift` for shortcut configuration and permission recovery; keep views presentation-only. Reuse the single shared capability card and `UtilityCapabilityMessage` Title Case title/sentence-case detail rules instead of adding a second permission row or contradictory global-ready flag. Global-input failure must not disable otherwise available manual recording.
- [ ] Extend the existing injected pasteboard action in `TranscribeFeatureController` to copy a complete transient result even when History saving fails; do not create a synthetic History entry merely to reuse `copyHistoryEntry`. Preserve existing Copy feedback/error conventions, and keep card text selectable without activating the destination app away from its field until the user explicitly interacts with the result.
- [ ] Add a generation-tagged complete-result callback/event at `TranscriptionSessionCoordinator.runRecognition` after successful recognition, independently of `history.append` success. Publish once for a nonempty complete result; cancellation/failure publishes no deliverable result. The panel consumes this event to enter result state; do not use `finalizedTranscript` changes as a completion signal because that property also receives intermediate confirmed segments. Phase 20 reuses this event rather than introducing another completion publisher. When saving fails, show the complete text and the existing truthful History error; never claim an unsaved result is in History.

### C. MacUtilities/Platform/Speech/AudioCaptureAdapter.swift

- **MODIFY:** `MacUtilities/Platform/Speech/AudioCaptureAdapter.swift`, `MacUtilities/Platform/Speech/AudioCaptureStream.swift`.
- **Target Anchor:** Bounded tap/pipeline and existing stream declarations.
- [ ] Calculate inexpensive RMS/peak from existing accepted buffers outside allocation-heavy UI work; smooth and throttle through a bounded latest-level path. Never wait for drawing, log samples or allocate an unbounded waveform history.
- [ ] Perform metering on `AudioCapturePipeline`'s existing serial `workerQueue` before the copied buffer slot is cleared/released. Keep the real-time callback's preallocated bounded-copy contract; publish only normalized numeric levels and generation metadata. Meter delivery cannot block or consume the recognizer's audio stream, and cancelled generations cannot update a new panel.

### D. MacUtilities/Features/Speech/TranscriptionPanelController.swift

- **NEW:** `MacUtilities/Features/Speech/TranscriptionPanelController.swift`, `MacUtilities/UI/Speech/TranscriptionPanelView.swift`.
- **Target Anchor:** Feature-owned presentation state/timer and presentation-only SwiftUI view; the platform host owns AppKit window operations.
- [ ] Implement nonactivating recording/processing/result/error states, screen geometry, cancellation-safe timer and generation replacement. Preserve Urdu baseline/direction and child accessibility labels. Add isolated Debug-only panel fixtures without microphone or production storage.
- [ ] Keep AppKit panel construction/geometry in a platform adapter such as new `MacUtilities/Platform/Speech/TranscriptionPanelHost.swift`, with the feature controller owning state/timer policy and the SwiftUI view consuming presentation values. Extend `Mac_UtilitiesApp`'s preview dependency composition, `TranscribePreviewDependencies.swift` and `AppDelegate`'s existing Debug routing; preserve `UtilityWindowCoordinator` singleton behavior. Avoid a parallel utility window or a second model lease.
- [ ] Obtain frontmost-window frame/display context at press through a narrow platform placement adapter; use pointer display when unavailable, including missing Accessibility trust. Phase 20 enriches that context with editable-element identity. Recompute usable geometry after display removal without activating another app. Preserve the existing `closingTranscribeWindowLeavesActiveRecordingAndModelLeaseRunning()` lifecycle contract.
- [ ] Use a continuous clock and generation-checked dismissal callback. Pause the remaining 30-second budget during hover or text selection; Copy follows the existing feedback behavior without restarting the budget. Close or replacement cancels the old timer. Phase 20 refines result presentation: confirmed insertion suppresses the card, while unavailable/failed/uncertain delivery uses this same card/timer. Add Debug-only `--transcribe-panel-preview=<state>` fixtures for `preparing`, `recording`, `finalizing`, `result` and `error` with a fake clock and synthetic levels/text; route through existing preview composition and update the owning verification matrix during implementation. Release must contain none of these routes.

### E. Mac UtilitiesTests/Speech/RecordingShortcutTests.swift

- **NEW:** `Mac UtilitiesTests/Speech/RecordingShortcutTests.swift`, `Mac UtilitiesTests/Window/TranscriptionPanelTests.swift`.
- **Target Anchor:** Fake input source, fake clock, fake capture and panel geometry.
- [ ] Cover preparation/release races, duplicate events, repeat keys, ownership conflicts, lost release, permission revocation, sleep, timer pause/resume, replacement, display removal, copy failure and shutdown.

## 12. Risks And Rollback Notes

- **Implementation Risks:** Event ordering, native API restrictions, stale generations and storage identity must be verified on the signed candidate.
- **Operational Risks:** Sandbox removal does not grant microphone/Accessibility/input authorization. Stable signing identity and supported group access must be verified; failure blocks rollout rather than changing group identity.
- **Rollback Approach:** Disable global dictation and remove monitors/panel/delivery tasks while preserving manual Transcribe and all saved data. Use Phase 18's verified rollback procedure for any host rollback.

## 13. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** Run after implementation, not during planning:
```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-dictation CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test
```
- **Targeted Tests:** Existing speech/window/storage suites and proposed tests in Section 11. Use meaningful failure/race cases, isolated roots and fake platform adapters.
- Regenerate the project after target configuration changes with `xcodegen generate --spec project.yml`. Use the signed Release build and `codesign --verify --deep --strict` procedure in Standards §5; ad-hoc tests cannot establish group or global permission access.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Response Code |
| :--- | :--- | :--- | :--- |
| Hold/release | Hold configured shortcut then release | Single capture; immediate microphone stop; final tail drained | Not applicable; native operation |
| Early release | Release during preparation or permission prompt | Pending start cancelled | Not applicable; native operation |
| Manual session | Press shortcut during manual recording | Manual owner preserved | Not applicable; native operation |
| Result timer | Hover/select/copy, then leave | 30-second visible-time policy; no History deletion | Not applicable; native operation |
| Display / permission changes | Remove display, revoke access, sleep | Safe panel reposition/cancellation and recovery | Not applicable; native operation |

### C. Evidence To Capture

Record test totals, configuration/entitlement checks without signing secrets, synthetic UI captures, native outcome counts and relevant resource/compatibility limitations. Keep backup manifests, real transcripts, model assets and per-utterance evidence outside Git. Verify Release excludes Debug preview routes and verification namespaces. Each phase includes its own implementation checks; there is no test-only phase.

## 14. Execution Notes

- **Status:** Planned
- **Started At:** Not started
- **Completed At:** Not completed
- **Blockers Encountered:** Prerequisites above. Native permissions/group access and editor compatibility require implementation-time verification.
- **Notes:** No application changes, migration, backup, installation or verification execution is claimed by this plan.
