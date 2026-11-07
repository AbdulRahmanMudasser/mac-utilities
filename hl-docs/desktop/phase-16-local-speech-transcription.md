# Phase 16 - Local Speech Transcription

## 1. Phase Purpose

Implement an English and Urdu speech-to-text capability for local macOS use. Recognition-quality and resource benchmarking is tracked separately in [Phase 17](./phase-17-speech-benchmark.md); implementation completion does not claim benchmark acceptance.

## 2. Feature Objective

- **Phase Goal:** Transcribe user-selected English or Urdu speech locally with one designated speech recognition model per language.
- **User Or System Outcome:** The user opens Transcribe in the utility window, selects a language, starts microphone capture and receives a transcript without sending audio to a server. Successful transcriptions appear in History with a timestamp and per-entry Copy and Delete controls.
- **In Scope:** Transcribe utility module, configuration and microphone capability states, native capture, language selection, two model assets, model access and integrity, local inference, successful transcription history, lifecycle and verification.
- **Out Of Scope:** Automatic language detection, translation, cloud transcription, automatic model substitution, alternative quantizations, model training, public binary distribution and unrelated usage history changes. Silero VAD is a separate speech detector, not a third transcription model. Recognition-quality, latency, memory and energy benchmarking belongs to Phase 17.

## 3. Current State And Implementation Delta

- **Verified Current Behavior:** The SwiftUI/AppKit app has a singleton utility window, shared module controls and an app-lifetime composition root. The sandboxed host has an audio-input entitlement and microphone usage description. Transcribe is wired into the utility window with isolated preview storage, explicit English setup, persistent transcript history and language preference. The user confirmed post-fix native English and Urdu recording, stop/finalization, History saving and the previously reported capture-buffer and segment-timing cases.
- **Verified Gap:** Recognition quality, latency, memory and energy have not been benchmarked; those measurements and the acceptance decision belong to Phase 17.
- **Desired Implementation Delta:** Add one isolated local speech feature and platform adapters while preserving existing controller ownership and storage boundaries.
- **Preserved Or Excluded Behavior:** Preserve the canonical usage ledger, App Group, widget contract, existing shortcuts and diagnostic/Keep Awake lifecycles. No model or quantization fallback is permitted.

## 4. Project Topology & Dependencies

- **Local Tracker:** [Desktop Execution Workflow](./execution-workflow.md).
- **Prerequisites (Blocked By):** The implementation supports user-selected Urdu model import after the user independently obtains authorization and downloads the file. No user's account approval, local cache or provisioned file is a project prerequisite.
- **Downstream Tasks (Unlocks):** [Phase 17](./phase-17-speech-benchmark.md) measures recognition quality, latency and resource use after the implementation and privacy controls are complete.
- **Target Git Commit Prefix:** `feat(speech): ...`.
- **Project Profile:** Native macOS desktop, SwiftUI/AppKit, macOS 26.6+.
- **Applicable Development Standards:** [Desktop Development Standards](./development-standards.md) §§1–6, especially §§2–3 ownership and storage, §4 shared UI and shortcuts, §5 signing and §6 privacy and verification.

## 5. Ownership And Delivery Notes

- **Owner / Priority / Target Window:** TBD.
- **Related PRD Section:** [Transcribe product requirements](../mac-utilities-prd.md#fr-19-local-speech-transcription).
- **Related Build Plan Section:** Not applicable; no build plan was identified for this feature.

## 6. Infrastructure & Environment Requirements

- **Environment Variables / Feature Flags:** Not applicable for on-device inference. **History Storage / Migration:** Persist locally across restarts with no automatic expiry, retaining entries until the user deletes them. Use a private `0700` directory and `0600` history file in app-sandbox Application Support, separate from the usage ledger; reject symbolic links and atomically replace updates. There is no existing transcription schema to migrate.
- **Model Assets:** English: [Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo), MIT, [whisper.cpp q5_0 conversion](https://huggingface.co/ggerganov/whisper.cpp/tree/98aa99a0a9db05ae2342309f5096248665f7cba3), `ggml-large-v3-turbo-q5_0.bin`, pinned SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`. Urdu: [Urdu Sukhan ASR v1](https://huggingface.co/Loudness-ai/urdu-sukhan-asr-v1), `ggml/ggml-urdu-sukhan-asr-v1-q5_0.bin`, CC BY-NC 4.0, gated by individually approved access; the implementation pins its source revision and SHA-256 for import verification. Neither model's weights are committed or shipped. A user must obtain their own approval and authorized file for Urdu; redistribution rights are not assumed.
- **Runtime:** `project.yml` links the arm64 host to a framework built by `Scripts/Speech/build-whisper-runtime.sh` from [whisper.cpp](https://github.com/ggml-org/whisper.cpp) revision `d1be6fde11ac6e0407606b4e42fe72d34add8037`, with embedded Metal shaders; the widget does not link it. A local native bridge smoke test using the English q5_0 model and [Silero VAD v6.2.0](https://huggingface.co/ggml-org/whisper-vad) successfully transcribed the upstream English sample using Metal. The detector file at revision `9ffd54a1e1ee413ddf265af9913beaf518d1639b` has verified SHA-256 `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`. The [Silero project license](https://github.com/snakers4/silero-vad/blob/master/LICENSE) is MIT; this smoke test is not a representative benchmark.
- **Fixtures:** Consent-based English and Urdu recordings and reference text, including mixed speech, short phrases, silence, names, accents and noise; store private recordings outside Git. Provide synthetic fixtures and fake capture/inference for automated tests.
- **Reusable Utilities:** Use `UtilityPanel`, `UtilityScrollContent`, `UtilityCapabilityCard` and `UtilityStyle` from `MacUtilities/UI/` for the eventual surface.

## 7. API & Data Contract Specifications

- **External API:** Not applicable for transcription; no audio or transcript is sent to an external service. Public model acquisition uses the network. Each user seeking Urdu must request access from the publisher, download the authorized file themselves, and import it locally.
- **Local contract:** A session receives an explicitly selected `en` or `ur`; map it to its one fixed model and pass the language to Whisper in transcription mode. A single owner serializes model use and associates audio and transcript events with a session generation. Stop ends capture and permits the current generation to finish its last buffered speech; cancellation, replacement or shutdown invalidates that generation and rejects its late results. Emit provisional and final text, failure and cancellation. Partial text may change; finalized segments have monotonic audio ranges and must not be duplicated across overlapping windows. A selected-model load failure is an error, never permission to use the other checkpoint.
- **Data:** Audio is transient in memory and never written to disk by the app. Persist only completed, nonempty transcripts locally across restarts with stable entry identity, text and the time saved to History; empty results and failed sessions, including partial results from failed sessions, are excluded. Retain entries until individually deleted. A text match or timestamp alone is not an identity. Store History in app-sandbox Application Support with a `0700` directory and `0600` file, separate from the canonical usage ledger and widget projection; reject symbolic links and atomically publish updates. Do not log transcript or audio content. Keep model files in app-specific Application Support, outside the usage App Group and Git; verify a pinned digest before atomic publication. Do not collect or store Hugging Face credentials.

## 8. UX / Behavioral Expectations

- Provide a `Transcribe` module immediately before Settings in the utility window with configuration, an English and Urdu dropdown, start/stop, recording state and provisional/final transcript. English is the default when no selection has been saved; remember a changed selection across relaunches. Selecting a different language automatically starts setup for that language and locks the picker until setup finishes. Disable language switching while recording; never infer the selected language.
- Follow `NotificationsView` and the shared `UtilityCapabilityCard` pattern for microphone permission, availability, transcription and other errors: show a state-specific Title Case title, concise sentence-case detail and actionable recovery in the card, and show progress during in-flight setup/recording work. Keep concurrent blockers and independent current errors represented with their recovery actions; one error must not silently mask another. Show microphone denial when it blocks recording, but do not append granted or unrequested permission status to model-readiness messages. Do not add a duplicate permission row. Request microphone access for Transcribe only; do not reuse or alter notification authorization.
- Show a History section for successful transcriptions, newest first, with whitespace between entries and no separator lines. Put a destructive Clear History button inline with the History heading; disable it when History is empty or unavailable and confirm before permanently deleting all saved entries. Each entry shows its transcript, a formatted saved-to-History timestamp and separate icon-only Copy and Delete buttons. Use `UtilityTimestampRow.timestampText(for:detail:)` formatting where appropriate and the shared `UtilityStyle.iconButtonFont` / `iconButtonSize` and small control size, accessible action labels, tooltips and keyboard access. Copy copies that entry's text; Delete removes only that entry without confirmation, including when two entries have identical text or timestamps. Expose the saved timestamp in the row summary while keeping transcript text accessible once as child content; do not repeat the full transcript in the row-level accessibility value. Failed transcriptions never appear in History. Match the Usage History empty-state styling and show a visible error if history cannot be loaded or updated; do not imply a failed operation succeeded.
- If the selected model is missing, inaccessible or invalid, show its state and a permitted recovery path; do not load another model. Forced language is a decoding instruction, not a guarantee of script or code-switch accuracy.
- Request microphone access only as part of a user-started operation. Recording continues when the utility window closes. Stop capture and invalidate work on cancellation, input loss and termination.
- Use shared native controls, keyboard access, VoiceOver labels and readable bidirectional Urdu/English text. Preserve existing Command-1 through Command-5 shortcuts; assign Transcribe Command-6 even though it appears before Settings. Reconcile the sidebar convention in the standards when implemented.

## 9. Acceptance Criteria

- A1: English uses only the pinned English q5_0 checkpoint with `en`; Urdu uses only the pinned Urdu q5_0 checkpoint with `ur`; neither automatic detection nor a fallback occurs.
- A2: Authorized microphone audio is processed on the Mac; silence, short speech, cancellation and microphone denial are handled truthfully without unbounded buffering or stale results.
- A3: Provisional and final text are distinguishable; Urdu, English and mixed-script examples are evaluated without claiming guaranteed recognition accuracy.
- A4: Model provenance, access, license and integrity are verified; missing, corrupt, unavailable or unauthorized models fail visibly without substitution.
- A5: Signed native capture, UI accessibility and existing regression checks pass. Recognition quality, latency, memory and energy acceptance are established and documented separately in Phase 17.
- A6: The Transcribe utility module exposes configuration and permission states using the shared Notifications-style capability presentation; failure titles identify their domain, accurate details remain visible, concurrent current errors are not silently masked, and failed transcriptions are not added to History.
- A7: Each successful History entry displays its transcript and formatted timestamp with accessible icon-only Copy and Delete actions; each action affects the intended stable entry. VoiceOver exposes the transcript once and the saved timestamp without duplicating the full transcript in the row value. History load or update failures remain visible and do not falsely report success.
- A8: English is the initial default and later language selections survive relaunch; completed, non-empty History entries survive relaunch and remain until explicitly deleted, with no automatic expiry.
- A9: Language cannot be changed during recording; recording continues when the window closes; History shows save time; Delete removes the selected entry without confirmation; Transcribe precedes Settings and existing shortcuts remain unchanged.

## 10. Requirement Traceability

| Requirement | Planned Implementation | Affected Files / Symbols | Acceptance Criteria | Verification Evidence |
| :--- | :--- | :--- | :--- | :--- |
| Explicit English/Urdu, English default, one model each, no fallback or detection | Fixed model/language mapping | New `MacUtilities/Features/Speech/` and `MacUtilities/Platform/Speech/` | A1, A4, A8 | Default/mapping and failure tests; model provenance |
| Efficient local speech-to-text | Native capture, VAD, bounded inference and cancellation | New speech feature/platform adapters; `project.yml` | A2, A5 | Target-Mac benchmark and lifecycle tests |
| Readable transcript and privacy | Shared utility surface and transient audio | `MacUtilities/App/UtilityWindow.swift`, new speech view, `Configuration/Info.plist`, host entitlements | A2, A3, A5 | Signed permission, UI and offline checks |
| Transcribe module, configuration and error presentation | Shared capability card and utility panels, modeled on Notifications, with domain-specific and concurrent error presentation | `MacUtilities/Features/Speech/TranscribeFeatureController.swift`, `MacUtilities/Features/Notifications/NotificationsView.swift`, `MacUtilities/UI/Controls/UtilityControls.swift`, Transcribe view | A6 | Permission/error presentation, concurrent-error and accessibility tests |
| Persistent successful transcription History with timestamp, Copy and Delete | Persist successful entries until deleted; reuse shared formatting and controls; expose transcript and timestamp without duplicate VoiceOver text | `MacUtilities/Features/Speech/TranscriptionHistoryStore.swift`, `MacUtilities/Features/Speech/TranscribeView.swift`; `UtilityTimestampRow.timestampText(for:detail:)` | A7, A6, A8 | Relaunch, retention, action, failure, formatting and VoiceOver checks |
| Recording language lock and sidebar placement | Disable language switching during recording; timestamp at save; delete without confirmation; insert Transcribe before Settings with Command-6 | `MacUtilities/App/UtilityWindow.swift`, new speech view and coordinator | A9 | Recording-state, history action and shortcut tests |
| No training, cloud, translation or automatic model substitution | Explicit exclusions | Speech engine and model manager | A1, A2, A4 | Configuration review and failure tests |

## 11. Implementation Steps (Component Audit)

### A. Feasibility And Assets

- [x] Pin the Urdu model source revision, expected size and digest used by the importer. The user-selected file is verified before installation. Each user must obtain access and the file under the publisher's terms; no account-specific access or local provisioning status belongs in public documentation.
- [ ] Benchmark the exact q5_0 checkpoints with `whisper.cpp` and representative held-out audio in Phase 17. Record per-language WER, Urdu CER and script errors, code-switch errors, first partial and final latency, real-time factor, cold/warm load time, peak memory and energy, including long speech and silence. Define normalization, corpus size and environment alongside the results. Keep provisional engineering targets distinct from measured guarantees; do not invent a quality threshold or substitute a model.

### B. Native Engine And Lifecycle

- [x] Modify `project.yml` host target's `dependencies` and source integration to pin a verified macOS arm64 native runtime. Confirm C API/module visibility, Metal resources, signing and Release packaging; keep inference and microphone dependencies out of the explicitly enumerated widget extension. Generate the ignored project and check generation idempotency.
- [x] Implement `MacUtilities/Platform/Speech/` adapters for `AVAudioEngine`, sample conversion to 16 kHz mono, VAD and the C API bridge. Capture and inference queues are bounded and report overload; input configuration changes, sleep, cancellation, inference completion and cleanup are handled without releasing an in-use model.
- [x] Implement the `MacUtilities/Features/Speech/` session coordinator and model store. The selected language and model are fixed per session; provisional/final events, segment merging, digest checks, atomic model publication and error states are covered by source and regression suites.
- [ ] Evaluate VAD and segment behavior with representative short, faint and code-switched Urdu recordings in Phase 17. Confirm empty-output behavior against the pinned runtime. Do not assume the current window settings establish acceptable quality or latency.
- [x] Implement model acquisition and import with cancellation, digest/size validation, atomic installation, and protection against replacing assets in use. The gated Urdu path prompts for an authorized local file; app credentials are intentionally not collected or stored. The user confirmed native Urdu recording, including model loading; no separate low-disk stress result is recorded.
- [x] Add the sandbox audio-input entitlement and microphone usage description; tests and previews use isolated dependencies. The user confirmed post-fix native English and Urdu capture and finalization below.

### C. Presentation And Integration

- [x] Integrate Transcribe before Settings with Command-6, preserving existing shortcuts. Compose one app-lifetime owner and join its capture/inference cleanup during termination; closing the utility window leaves recording active.
- [x] Implement the Transcribe surface, persistent local History, stable entry actions and isolated storage. English is the default; the language dropdown persists choices and locks during active setup/recording. The capability card owns permission/errors, History shows successful nonempty transcripts only, and Copy/Delete use the shared timestamp and icon-button conventions.
- [x] Add injected speech, model, history and window lifecycle regression suites. The most recent full automated run passed 371 tests in 30 suites. The user confirmed post-fix live capture; performance and recognition-quality evaluation are tracked in Phase 17.
- [x] Add isolated Debug preview routing with synthetic data/dependencies. Preview capability is explicit and truthful. Start and Stop work through fake capture/inference, save clearly synthetic language-appropriate text, and never access the real microphone or model assets. Switching language remains stable and does not start real model setup. Previews use isolated History/preferences and Release excludes preview routes. Focused speech/window tests pass, and the ad-hoc signed Debug preview was exercised through English and Urdu Start/Stop. Follow [Speech Transcription Conventions](../conventions/speech-transcription.md#4-presentation-and-verification).

## 12. Risks And Rollback Notes

- **Implementation Risks:** Urdu model publisher reports weak proper-name recognition; forced language does not ensure correct script or code-switching. Quantization, VAD and window merging can degrade accuracy or lose speech; no target-device benchmark has yet been run.
- **Operational Risks:** Urdu model is access-gated and non-commercial; authorized acquisition and redistribution cannot be assumed. Model download size and energy/latency are device-specific; SHA-256 is meaningful only when obtained from trusted pinned provenance.
- **Model Evaluation Risk:** The Urdu publisher recommends q8_0 for best quality on Apple Silicon; q5_0 is the user's selected single checkpoint and must be evaluated on its own merits. No automatic or manual q8_0 fallback is part of this phase.
- **Rollback Approach:** Stop active capture and inference, disable or revert the feature and its permissions/configuration, and leave the usage ledger and existing app preferences untouched. Delete model assets only through an explicit user action.

## 13. Verification Protocol (Definition of Done)

### A. Automated Suite

- Generate after project configuration changes: `xcodegen generate --spec project.yml`.
- Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-speech CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`.
- Run the signed Release build and signature checks from [Standards §5](./development-standards.md#5-reproducible-project-and-local-signing); ad-hoc tests alone do not prove microphone authorization or App Group access.

### B. Functional Verification Matrix

| State | Trigger | Expected result |
| :--- | :--- | :--- |
| English / Urdu | Select each and speak | Correct fixed model and language; local transcript |
| Language during recording | Attempt to change language while recording | Selector is disabled and controller rejects the change; active session keeps its language |
| Language on relaunch | Select Urdu, quit and relaunch | The explicitly selected language remains Urdu; English is the default before any selection |
| Transcribe preview interaction | Launch `--transcribe-preview=history`, switch language, start and stop | The capability card labels readiness as simulated; the selected language stays selected without a setup-state flash; Start/Stop complete a fake session and save clearly synthetic text without accessing the microphone or real models |
| Window close during recording | Close the utility window while recording | Recording continues and its owner remains active |
| Missing / invalid model | Remove or corrupt test asset | Visible recovery state; no other model loaded |
| Permission denied / input lost | Deny access or disconnect test input | No capture; clear actionable state and cleanup |
| Install / disk / access | Cancel, exhaust space, deny access or attempt concurrent removal in isolated storage | No incomplete model is marked ready; active inference remains safe; explicit error, no substitution |
| Successful / empty / failed transcription | Complete one non-empty transcription, then produce an empty result and a failure with partial text | Only the completed non-empty transcript appears in History with a formatted timestamp; failure appears in the capability/error state |
| History actions | Copy and delete one entry among multiple entries | Copy produces that entry's text; Delete removes only the chosen entry without confirmation; controls are keyboard and VoiceOver accessible; VoiceOver announces transcript text once and the saved timestamp |
| History timestamp | Save a successful transcription | Display the formatted time at which the entry was saved to History |
| History relaunch | Complete a transcription, quit and relaunch using isolated storage | Entry survives with its timestamp; no automatic expiry; deletion affects only the selected entry |
| History unavailable with another failure | Inject a history load/update failure together with a capture or transcription failure | Keep both current causes and their available recovery actions represented; preserve entries and do not claim an operation succeeded |
| Silence / short or noisy speech | Speak briefly or remain silent | No fabricated success; record recognition and VAD errors |
| Stop / cancel / replace / quit | Stop normally, then separately cancel, replace or quit during inference | Normal stop finalizes buffered speech; invalidated generations cannot mutate the next session and all capture stops |
| Appearance / accessibility | Light, Dark, compact and expanded | Readable mixed-direction text, keyboard and VoiceOver access |

### C. Evidence To Capture

- Exact model/runtime revisions, verified digests, access terms, benchmark corpus and results, chosen quality thresholds, native signed permissions, offline behavior, lifecycle and UI evidence. Confirm built Info.plist/entitlements, signed Release packaging and absence of preview fixtures; follow Standards §6 widget discovery cleanup after the final build/test. Do not record private audio or transcripts in logs.

## 14. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-31
- **Completed At:** 2026-11-02
- **Blockers Encountered:** None for Phase 16. Benchmark acceptance is tracked separately in Phase 17.
- **Notes:** The importer verifies user-selected Urdu assets against pinned metadata and does not embed or store account credentials. Earlier live English runs exposed oversized capture buffers and invalid/overlapping segment timing; code and regression coverage were updated. The user confirmed post-fix English and Urdu native capture, finalization, History saving, and verification of the prior capture-buffer and segment-timing issues. No account-specific access, local cache or model-provisioning status is part of this public phase record. The implementation has one q5_0 checkpoint per language and does not fall back to another model. Quality and resource measurements remain open in Phase 17.
