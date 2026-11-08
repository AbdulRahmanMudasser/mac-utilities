# Phase 20 - Focused Text Delivery And Integrated Release

## 1. Phase Purpose

Control implementation of this substantial delivery boundary. This document is a plan, not evidence of implementation. Approved conversation requirements govern the planned delta.

## 2. Feature Objective

- **Phase Goal:** Deliver completed dictation to the original eligible focused field, otherwise present the copy card, and verify the integrated upgrade.
- **User Or System Outcome:** Deliver completed dictation to the original eligible focused field, otherwise present the copy card, and verify the integrated upgrade.
- **In Scope:** Accessibility destination inspection, selection/caret insertion, controlled paste compatibility, recovery, privacy and signed end-to-end release checks.
- **Out Of Scope:** Submitting messages, pressing Return, password fields, unattended dictation, cloud speech, public distribution and claims of universal editor support.

## 3. Current State And Implementation Delta

- **Verified Current Behavior:** Existing copy action in `TranscribeFeatureController.copyHistoryEntry` uses its injected pasteboard writer. `TranscriptionSessionCoordinator.runRecognition` publishes final text and independently attempts `history.append`; it already preserves visible text after a save failure. There is no focused-element capture, destination revalidation or cross-application insertion. The planned Phase 19 supplies shortcut session generations and the floating result surface; it is not current implementation evidence.
- **Verified Gap:** The scoped behavior is absent from the current sandboxed implementation.
- **Desired Implementation Delta:** Extend existing ownership and adapters as specified below; do not create a second speech engine or Usage writer.
- **Preserved Or Excluded Behavior:** Keep explicit English/Urdu language selection, pinned models, successful-only History, private local data and existing unrelated module behavior.

## 4. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md).
- **Prerequisites (Blocked By):** Phases 18 and 19 completed, including Phase 18's verified pre-install backup receipt and rollback evidence, unsandboxed host/sandboxed widget checks and unchanged signed App Group access; signed permissions and existing Phase 17 quality limitations reviewed.
- **Downstream Tasks (Unlocks):** Not applicable; integrated local installation completes this series.
- **Target Git Commit Prefix:** `feat(speech): ...`.
- **Project Profile:** Native macOS desktop, SwiftUI/AppKit, macOS 26.6+; sandboxed WidgetKit extension remains a separate responsibility.
- **Applicable Development Standards:** [Desktop Development Standards](./development-standards.md) §§2–3 ownership/storage, §4 UI, §5 signing and §6 privacy/verification; [Speech Transcription Conventions](../conventions/speech-transcription.md), especially §5 planned dictation contract.

## 5. Ownership And Delivery Notes

- **Owner / Priority / Target Window:** TBD.
- **Related PRD Section:** [FR-19 Local Speech Transcription](../mac-utilities-prd.md#fr-19-local-speech-transcription) is baseline context; the approved shortcut/unsandboxing extension is specified by this series. PRD edits are outside this documentation request.
- **Related Build Plan Section:** Not applicable; no separate build plan is maintained for this scope.

## 6. Infrastructure & Environment Requirements

- **Environment Variables:** Reuse `DEVELOPER_DIR` and ignored local signing configuration from Standards §5; no new server or credentials.
- **Database/Index Changes:** Not applicable; existing local JSON stores remain.
- **Feature Flags / Config Switches:** User-configured shortcut enables global dictation; unconfigured/denied state preserves manual recording.
- **Seed / Fixture Requirements:** Isolated temporary roots, synthetic transcripts, fake clocks and injected platform adapters; never use production data in hosted tests.
- **Required Reusable Utilities:** Existing `TranscribeFeatureController`, `TranscriptionSessionCoordinator`, `UsageStoragePaths`, shared capability cards, timestamps and icon controls; native adapters stay in Platform.

## 7. API & Data Contract Specifications

HTTP request/response schemas are not applicable: this is a native local feature with no service.

At shortcut press record session generation, destination PID and focused element identity, plus selection/caret metadata only as needed. Do not retain arbitrary field contents. Before delivery, revalidate process, focused element, editability, secure-field exclusion and session generation. Delivery outcome is inserted, unavailable, failed or uncertain. Only confirmed success dismisses the result surface; failures/uncertainty show the copy card and never blindly retry. Prefer supported selected-text insertion, including at an empty selection. Do not replace whole-field value. Clipboard paste compatibility snapshots supported pasteboard representations, writes the transcript, revalidates focus, posts only Paste and conditionally restores prior contents if ownership has not changed; do not claim a universal reliable paste-consumed signal. Keep snapshots transient and never log them.

The destination snapshot is transient: generation, PID plus process-lifetime identity, focused AX element, containing window identity/frame where obtainable, selection range and secure/editable classification. PID reuse must not identify a new process as the old destination. An unavailable required identity or selection attribute produces `unavailable`, not a best guess. Retain no full draft, selected-text contents or destination metadata in History. A successful supported Accessibility mutation yields `inserted`; an API failure after a possible mutation yields `uncertain` and must not trigger a second insertion method. Only an explicitly unsupported, unattempted direct mutation is eligible for a compatibility path.

Delivery state is pending → validating → inserting → inserted/unavailable/failed/uncertain. Claim the generation's delivery token before any mutation; subsequent completion callbacks are ignored. Cancel pending validation on replacement/quit; never retry a mutation already dispatched. The approved delivery behavior remains automatic insertion where safe, and the existing 30-second copy card when insertion is unavailable, unsafe, failed or uncertain. This is a settled recovery rule, not a pending product decision. Posting Paste alone cannot prove consumption; an arbitrary restoration delay cannot establish success. A clipboard compatibility adapter may be used only for a destination whose consumption/restoration behavior has been verified without overwriting user clipboard changes; otherwise classify it unavailable before posting and show the copy card. If an attempted mutation has an uncertain outcome, show that card with concise uncertainty detail and never retry automatically. Direct Accessibility delivery and safe recovery must work independently of clipboard compatibility.

## 8. UX / Behavioral Expectations

A caret in a compatible editable field is sufficient. Replace selected text according to normal editor semantics. Successful delivery shows no copy-result card; no destination, changed focus or failed/uncertain delivery shows the Phase 19 copy card for 30 seconds. History saving is independent of insertion outcome. Recovery messages distinguish permissions, unsupported destination, changed focus and delivery failure.

Permissions remain user-controlled. Keep private audio, transcripts, clipboard contents and destination field contents out of logs, repository fixtures and public evidence. No screen-recording permission or screen capture is required for this design.

## 9. Acceptance Criteria

- **AC1:** A matching editable destination receives text once at its caret/selection, without Return or form submission.
- **AC2:** Secure fields, changed destinations, missing permissions and unsupported editors produce a copy card without unintended insertion.
- **AC3:** Clipboard changes made by the user during delivery are preserved; uncertain paste is not retried.
- **AC4:** Complete English/Urdu transcripts remain visible in the app if History persistence fails, with truthful unsaved/retry state. Successful saves remain in History independently of insertion outcome; insertion failure never marks a failed save as persisted.
- **AC5:** Upgrade, widget, permission, shortcut/panel and delivery matrices pass before signed local installation; resource/compatibility limits are recorded without private content.

## 10. Requirement Traceability

| Requirement | Planned Implementation | Affected Files / Symbols | Acceptance Criteria | Verification Evidence |
| :--- | :--- | :--- | :--- | :--- |
| P20-1: Insert once at original destination | Capture and revalidate destination/caret before mutation | FocusedTextDestination (new); TranscriptTextInsertion (new) | AC1 | Caret/selection fixtures and signed target-app matrix |
| P20-2: Recover without unintended writes | Classify secure/changed/unsupported/permission outcomes | FocusedTextDestination (new); TranscribeFeatureController; TranscriptionPanelController (Phase 19) | AC2 | Focus, selection, target-close, secure-field and trust-revocation tests |
| P20-3: Preserve clipboard and avoid duplicates | Bounded paste operation with conditional restoration and uncertain outcome | TranscriptTextInsertion (new); TranscriptDeliveryTests (new) | AC3 | Clipboard owner change, unsupported types, delayed paste and duplicate callback tests |
| P20-4: Independent delivery and persistence | Publish complete-result event independently of History append | TranscriptionSessionCoordinator.runRecognition; TranscribeFeatureController | AC4 | History failure versus insertion success and inverse integration tests |
| P20-5: Integrated local release | Verify migration, widget, panel and native insertion before installation | Configuration/Version.xcconfig; existing signed build protocol; lifecycle tests | AC5 | Signed Release/version, backup receipt and compatibility/resource evidence |
| Explicit exclusions | Submitting messages, pressing Return, password fields, unattended dictation, cloud speech, public distribution and claims of universal editor support. | No implementation in this phase | Scope boundary | Diff review |

## 11. Implementation Steps (Component Audit)

### A. MacUtilities/Platform/Accessibility/FocusedTextDestination.swift

- **NEW:** `MacUtilities/Platform/Accessibility/FocusedTextDestination.swift`, `MacUtilities/Platform/Accessibility/TranscriptTextInsertion.swift`.
- **Target Anchor:** Platform-owned Accessibility and input-injection adapters.
- [ ] Inspect focused editable elements under explicit authorization; exclude secure or unverifiable fields. Keep destination identity tied to session generation; revalidate immediately before mutation. Prefer settable selected-text APIs. Implement clipboard compatibility as a distinct bounded operation with an explicit uncertain outcome, supported-format restoration policy and no automatic duplicate retries. Verify current macOS API/permission behavior before finalizing adapters.
- [ ] Reuse Phase 19's permission/trust adapter and shared capability presentation rather than adding a second independent authorization owner. Bound Accessibility messaging timeouts and marshal native calls away from latency-sensitive input callbacks; retain MainActor presentation ownership. Empty/no-speech, cancelled and failed recognition results must never trigger insertion. App capability is verified per destination; do not identify all web inputs as editable merely from their role.

### B. MacUtilities/Features/Speech/TranscribeFeatureController.swift

- **MODIFY:** `MacUtilities/Features/Speech/TranscribeFeatureController.swift`, `MacUtilities/Features/Speech/TranscriptionSessionCoordinator.swift`, `MacUtilities/Features/Speech/TranscriptionPanelController.swift`, `MacUtilities/App/AppDelegate.swift`.
- **Target Anchor:** Complete transcript publication, session ownership and panel result transition.
- [ ] Capture destination at shortcut press; route finalized complete text once after successful recognition. Preserve app transcript and History independently of external delivery. Suppress expanded result only for confirmed insertion. Cancel stale delivery on quit/new generation; errors cannot target a later focused field.
- [ ] Subscribe delivery to Phase 19's generation-tagged complete-result event/callback from `TranscriptionSessionCoordinator.runRecognition`, independently of `history.append` success. Do not create a second completion publisher or infer completion by observing `finalizedTranscript`, which already changes for intermediate confirmed segments. Keep delivery ownership in `TranscribeFeatureController`; views and the History store must never initiate insertion.
- [ ] Revalidate caret/selection metadata as well as PID and focused element identity; typing, moving the caret or changing selection while inference finishes makes the destination unavailable for automatic delivery. Coordinate the held shortcut's modifier release with synthetic Paste so the command cannot include still-held recording modifiers. Releasing a pointer/keyboard event must not activate Mac Utilities or move focus away from the original field.
- [ ] Extend Phase 19's press-time placement context with the destination window frame/display identifier where available; reuse its pointer-display fallback and display-removal handling. Keep floating-panel geometry independent from utility-window visibility. Phase 20 refines Phase 19's final-card rule only after a confirmed insertion outcome; failed/uncertain delivery retains the same 30-second remaining-budget semantics.

### C. Mac UtilitiesTests/Speech/TranscriptDeliveryTests.swift

- **NEW:** `Mac UtilitiesTests/Speech/TranscriptDeliveryTests.swift`.
- **Target Anchor:** Fake destination/accessibility/clipboard/input adapters.
- [ ] Cover selection replacement, caret insertion, empty fields, secure fields, denied/revoked trust, target close/focus change, selection changes, clipboard ownership change, unsupported clipboard formats, uncertain paste, duplicate completion and stale generation. Do not send real events to external apps in hosted tests.

### D. Mac UtilitiesTests/Window/TranscribeWindowLifecycleTests.swift

- **MODIFY:** `Mac UtilitiesTests/Window/TranscribeWindowLifecycleTests.swift`, `Mac UtilitiesTests/Speech/TranscribeFeatureControllerTests.swift`.
- **Target Anchor:** Existing lifecycle and feature integration suites.
- [ ] Extend integration coverage for manual/global session conflict, History failure versus delivery success, insertion failure versus History success, terminal cleanup and panel timer cancellation. Verify all-module preference preservation, App Group widget reads and migration rollback in the signed candidate.

### E. Configuration/Version.xcconfig

- **MODIFY:** `Configuration/Version.xcconfig`, `hl-docs/conventions/speech-transcription.md`, `hl-docs/desktop/execution-workflow.md`.
- **Target Anchor:** Authorized release version and current implementation/evidence fields.
- [ ] During implementation choose the release version from actual intervening releases, increment build and verify built Info.plist. Document tested target-app versions and results, aggregate memory/CPU/load observations, unavailable energy measurements and open Phase 17 gates. Install only after verified backup and signed Release checks; do not claim benchmark acceptance from UI smoke tests.

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
| Native editors | Dictate in TextEdit and Notes | Caret/selection insertion once; no result card on confirmed success | Not applicable; native operation |
| Browser/Electron/rich text | Dictate into supported composers/editors | Compatibility recorded per app/version; copy recovery when uncertain | Not applicable; native operation |
| No target / focus changed | Dictate without field or switch fields before completion | Copy card; no write into another field | Not applicable; native operation |
| Permissions / secure input | Deny access or focus password control | No external mutation; actionable recovery | Not applicable; native operation |
| Upgrade and resources | Run migration, actual dictation and widget checks | Data preserved, one writer, cleanup and bounded resource observations | Not applicable; native operation |

### C. Evidence To Capture

Record test totals, configuration/entitlement checks without signing secrets, synthetic UI captures, native outcome counts and relevant resource/compatibility limitations. Keep backup manifests, real transcripts, model assets and per-utterance evidence outside Git. Verify Release excludes Debug preview routes and verification namespaces. Each phase includes its own implementation checks; there is no test-only phase.

## 14. Execution Notes

- **Status:** Planned
- **Started At:** Not started
- **Completed At:** Not completed
- **Blockers Encountered:** Prerequisites above. Native permissions/group access and editor compatibility require implementation-time verification.
- **Notes:** No application changes, migration, backup, installation or verification execution is claimed by this plan.
