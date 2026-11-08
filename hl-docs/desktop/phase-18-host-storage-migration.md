# Phase 18 - Unsandboxed Host And Safe Data Migration

## 1. Phase Purpose

Control implementation and verification of the host storage cutover. Approved conversation requirements govern this delivery boundary; Section 14 records its current verification state.

## 2. Feature Objective

- **Phase Goal:** Deliver an unsandboxed host with verified backup, idempotent data migration and a working sandboxed widget.
- **User Or System Outcome:** Deliver an unsandboxed host with verified backup, idempotent data migration and a working sandboxed widget.
- **In Scope:** Host signing configuration, storage-root resolver, backups, preference migration across modules, startup ordering, rollback and widget interoperability.
- **Out Of Scope:** Shortcut, overlay and text insertion belong to downstream phases. Public distribution, notarization enrollment and model changes are excluded.

## 3. Current State And Implementation Delta

- **Verified Current Behavior:** `project.yml` disables host sandboxing and retains the widget's sandbox. Host audio-input and App Group entitlements remain. `UsageStoragePaths` still resolves the same canonical group ledger. `HostStartupController` gates `HostRuntime` construction on verified migration; `TranscriptionStoragePaths` resolves user Application Support for Transcribe and the private receipt.
- **Verified Gap:** None within this phase's storage and host cutover scope. Global recording and text delivery remain excluded.
- **Delivered Implementation Delta:** Shared preflight/backup validation, recoverable publication, allowlisted preference import, same-lease Usage ownership, explicit recovery export and signed host/widget cutover.
- **Preserved Or Excluded Behavior:** Keep explicit English/Urdu language selection, pinned models, successful-only History, private local data and existing unrelated module behavior.

## 4. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md).
- **Prerequisites (Blocked By):** Phase 16 complete; Phase 17 remains separately tracked and is not a blanket prerequisite. Verify current storage and signing before cutover.
- **Downstream Tasks (Unlocks):** Phase 19.
- **Target Git Commit Prefix:** `feat(storage): ...`.
- **Project Profile:** Native macOS desktop, SwiftUI/AppKit, macOS 26.6+; sandboxed WidgetKit extension remains a separate responsibility.
- **Applicable Development Standards:** [Desktop Development Standards](./development-standards.md) §§2–3 ownership/storage, §4 UI, §5 signing and §6 privacy/verification; [Speech Transcription Conventions](../conventions/speech-transcription.md), especially §5 planned dictation contract.

## 5. Ownership And Delivery Notes

- **Owner / Priority / Target Window:** TBD.
- **Related PRD Section:** [FR-19 Local Speech Transcription](../mac-utilities-prd.md#fr-19-local-speech-transcription) is baseline context; the approved shortcut/unsandboxing extension is specified by this series. PRD edits are outside this documentation request.
- **Related Build Plan Section:** Not applicable; no separate build plan is maintained for this scope.

## 6. Infrastructure & Environment Requirements

- **Environment Variables:** Reuse `DEVELOPER_DIR` and ignored local signing configuration from Standards §5; no new server or credentials.
- **Database/Index Changes:** Not applicable; existing local JSON stores remain.
- **Feature Flags / Config Switches:** Host sandbox setting changes only at verified migration cutover; widget retains its own setting.
- **Seed / Fixture Requirements:** Isolated temporary roots, synthetic transcripts, fake clocks and injected platform adapters; never use production data in hosted tests.
- **Required Reusable Utilities:** Existing `TranscribeFeatureController`, `TranscriptionSessionCoordinator`, `UsageStoragePaths`, shared capability cards, timestamps and icon controls; native adapters stay in Platform.

## 7. API & Data Contract Specifications

HTTP request/response schemas are not applicable: this is a native local feature with no service.

Migration states: unexamined → backingUp → backupVerified → staging → destinationVerified → committed; any failure leaves the source authoritative and blocks new writers. A versioned manifest records relative paths, byte counts, hashes, schema versions and commit state, never transcript content or credentials. The stable Usage ledger stays in its App Group; it is backed up but not relocated. History keeps stable IDs and saved timestamps. Import only allowlisted preference keys, preserving an already populated destination. Conflicting same-ID History values require recovery rather than silent replacement.

The private schema-v1 receipt must contain `migrationID` (UUID), `schemaVersion`, `bundleIdentifier`, `createdAt`, `sourcePresence` (present/absent per store), `sourceFingerprints`, `backupRoot`, `destinationRoot`, `entries` and `state`. Each entry identifies a store, a relative path, byte count and SHA-256; reject absolute entry paths, traversal, duplicate paths and unknown schema versions. Source/destination absolute roots occur only in the private receipt, never public evidence. Persist the receipt atomically under user Application Support `MacUtilities/Migration/host-storage-v1.json`; Transcribe's destination is its sibling `MacUtilities/Transcribe`, not beneath the backup. Backup destination must be a distinct explicitly supplied durable directory, outside source, destination, Git and temporary/cache roots. Reject nested/overlapping roots. Native bootstrap and preflight share the same injected path resolver and receipt decoder.

Commit is a recoverable transaction, not a claim that filesystem and UserDefaults have one atomic operation. Validate and stage all files first; journal each published file and each allowlisted preference import, preserve previous destination values, and write `committed` last. On interruption, verify journaled outputs before continuing; mismatched outputs block recovery rather than being overwritten. Test the crash boundary after files publish but before preferences/receipt completion. A committed migration never reimports retained legacy data, including after Clear History or individual deletion.

Preflight validates the backup receipt and returns zero only on verified success; nonzero outcomes distinguish unsafe input, active writer, unsupported/corrupt source, insufficient space, changed source and backup verification failure using content-free codes. The wrapper forwards that status and cannot install or launch the app. Verify restore into isolated temporary roots before production cutover. Missing models are recorded as absent, not synthesized or downloaded; invalid existing models are preserved in backup and block their readiness. No process silently repairs corrupt user History.

## 8. UX / Behavioral Expectations

Use the existing capability/error presentation for blocked startup or recovery. A failed migration must not show collection or recording as available. No automatic login-setting changes or replay of notifications/active sessions.

Permissions remain user-controlled. Keep private audio, transcripts, clipboard contents and destination field contents out of logs, repository fixtures and public evidence. No screen-recording permission or screen capture is required for this design.

## 9. Acceptance Criteria

- **AC1:** A verified private backup exists before any destination publication or signing cutover installation.
- **AC2:** Usage bytes, History IDs/timestamps, authorized model hashes and supported preferences survive upgrade; widget reads the same ledger.
- **AC3:** Interrupted migration resumes safely; repeated launch does not import twice; populated/conflicting destinations are protected.
- **AC4:** The built host has sandbox disabled, the widget retains sandbox/group access, and actual signed container access is verified.
- **AC5:** Rollback preserves post-upgrade data and never silently restores an older snapshot over newer records.

## 10. Requirement Traceability

| Requirement | Implementation | Affected Files / Symbols | Acceptance Criteria | Verification Evidence |
| :--- | :--- | :--- | :--- | :--- |
| P18-1: Verified backup precedes cutover | Pre-install preflight plus validated receipt | Scripts/prepare-host-migration.sh (new); HostStorageMigration (new) | AC1 | Active-writer, changed-source, corrupt-receipt and backup restore tests |
| P18-2: Preserve all data/settings | Schema-aware History/model checks, preference allowlist and unchanged Usage group | TranscriptionHistoryStore; SpeechModelStore; UsageStoragePaths.resolve; startup composition | AC2 | Fixture counts/IDs/hashes plus signed widget read |
| P18-3: Idempotent safe startup | Gate owner initialization until staged commit | HostStartupController; HostRuntime; AppDelegate; HostStorageMigration | AC3 | Interrupted commit, fresh install, repeated launch, cancellation, termination and conflict tests |
| P18-4: Unsandboxed host and sandboxed widget | Host-only settings change with signed entitlement inspection | project.yml; MacUtilities.entitlements; preserved widget entitlements | AC4 | Signed host/widget configuration and actual group access |
| P18-5: Rollback preserves newer data/deletions | Leave shared Usage in place; explicit reconciliation for History conflicts | HostStorageMigration (new); HostStorageMigrationTests (new) | AC5 | Rollback after append/delete/clear and newer Usage writes |
| Explicit exclusions | Shortcut, overlay and text insertion belong to downstream phases. Public distribution, notarization enrollment and model changes are excluded. | No implementation in this phase | Scope boundary | Diff review |

## 11. Implementation Steps (Component Audit)

### A. project.yml

- **MODIFY:** `project.yml`, `Configuration/MacUtilities.entitlements`.
- **INSPECT / PRESERVE:** `Configuration/MacUtilitiesWidgets.entitlements`; its sandbox/group configuration is already correct and requires no new capability.
- **Target Anchor:** Mac Utilities target settings and separate entitlement dictionaries.
- [x] Disable App Sandbox for the host only after the migration gate. Preserve bundle identity, group identity and local signing; retain widget sandboxing. Distinguish ENABLE_USER_SCRIPT_SANDBOXING from app sandboxing. Verify whether hardened-runtime audio permission entitlement is required; do not remove microphone authorization.

### B. MacUtilities/Platform/Storage/HostStorageMigration.swift

- **NEW:** `MacUtilities/Platform/Storage/HostStorageMigration.swift`, `MacUtilities/Platform/Speech/TranscriptionStoragePaths.swift`.
- **Target Anchor:** New platform-owned migration coordinator and injected path resolver.
- [x] Inventory actual legacy and destination paths and every persistent preference owner before coding. Resolve legacy container through supported identity/container APIs where available; never guess a personal path. Copy Usage, History, models and allowlisted preferences into a durable versioned private backup outside Git, caches and temporary directories. Reject symlinks, check free space for backup plus staging, validate schemas/hashes, synchronize writes and verify the manifest. Stage the Transcribe destination in user Application Support, atomically commit, and persist completion last. Do not delete sources or automatically merge conflicting files.
- [x] Add `Scripts/prepare-host-migration.sh` as the pre-install backup entry point, reusing the migration manifest/validation contract. It must operate only after the installed host and task-owned previews have quit and their writer lease is available. It accepts explicitly verified source roots and a user-owned durable backup destination; it must not launch a second collector, read signing secrets or infer a container path from a personal username. Refuse active processes, unsafe paths and source changes during copying. Produce a verified backup receipt before replacing the installed sandboxed bundle. On first unsandboxed launch, validate that receipt and source hashes before staging; invalidate and repeat preflight if the old app has written since backup. A clean installation with no legacy data records that fact without requiring a nonexistent backup.
- [x] Keep the preflight executable independent of application startup: the shell entry point compiles/runs new `Scripts/Storage/HostMigrationPreflight.swift` against the Foundation/Darwin migration and schema-validation sources using the existing Xcode toolchain pattern. It must never launch `Mac_UtilitiesApp` to take a backup. Require explicit `--source-transcribe`, `--source-preferences`, `--usage-state` and `--backup-directory` absolute paths plus verified bundle identity; validate every root before reading. The native helper owns validation/copy/receipt logic, shared with `HostStorageMigration`, rather than reimplementing JSON/model validation in shell. Compile generated executables outside Git and remove only its own completed build outputs.
- [x] Reuse `TranscriptionHistoryStore` decoding/schema/ID rules in `MacUtilities/Features/Speech/TranscriptionHistoryStore.swift` and `SpeechModelStore` size/hash validation in `MacUtilities/Platform/Speech/SpeechModelStore.swift`; expose narrow validation helpers only where private implementations currently prevent reuse. The model remains app-local, never in the Usage group. History stays private JSON with atomic publication. Keep backup and staging permissions as restrictive as source storage; errors expose actionable domains without transcript/path contents.

### C. MacUtilities/App/Mac_UtilitiesApp.swift

- **MODIFY:** `MacUtilities/App/Mac_UtilitiesApp.swift`, `MacUtilities/App/AppDelegate.swift`, `MacUtilities/Platform/Storage/UsageStateStore.swift`.
- **NEW / PRESERVE:** `HostRuntime.swift` owns deferred composition; `UsageStoragePaths.resolve` and the widget's resolver remain unchanged.
- **Target Anchor:** Composition before controller/writer initialization; application termination; UsageStoragePaths.resolve.
- [x] Gate all writers and feature initialization on migration completion; coordinate termination and prevent concurrent old/new host writers. Preserve group resolution without a legacy Usage fallback. Import standard preferences before constructing feature controllers; exclude login registration, permissions, active sessions, errors and temporary preview namespaces.
- [x] Refactor the eager `Mac_UtilitiesApp.init()` composition into an explicit startup/bootstrap state before constructing `UsageMonitor`, `NotificationsController`, `KeepAwakeController` or `TranscribeFeatureController`; constructing these owners already reads/migrates preferences or starts collection. Reuse `UsageStateStore`/`UsageWriterLease` ownership without taking a second competing lease; protect the complete preflight/cutover interval and verify no old host is running because its Transcribe store has no cross-process writer lease. Isolated tests/previews bypass production migration through injected roots and receipts.
- [x] Add `MacUtilities/App/HostStartupController.swift` for bootstrap phase/result ownership and `MacUtilities/UI/HostStartupView.swift` for a presentation-only recovery surface using shared capability components. Construct production feature owners only after successful bootstrap, rather than launching asynchronous migration after eager `@StateObject` initialization. Keep retry/cancel/quit behavior explicit and prevent a failure surface from instantiating the blocked writers.
- [x] Migrate the existing allowlist from `UsageMonitor` (`rateDisplayUnit`, `dataDisplayUnit`), `KeepAwakeController` (`keepAwake.presets.v1`, `keepAwake.keepDisplayOn.v1`), `NotificationsController` (`notifications.enabled.v1`, legacy `notifications.keepAwakeTimer.v1`) and `TranscriptionLanguagePreferenceStore` in `TranscriptionLanguage.swift` (`speech.transcriptionLanguage.v1`). Reuse the Notifications controller's existing legacy-key semantics instead of another conflicting conversion. Read login state from `LoginItemService`; never register/unregister it as a migration side effect. Preserve missing-key defaults and validate stored types before import.

### D. Mac UtilitiesTests/Storage/HostStorageMigrationTests.swift

- **NEW:** `Mac UtilitiesTests/Storage/HostStorageMigrationTests.swift`.
- **Target Anchor:** Injected temporary roots and fake writer/preferences adapters.
- [x] Cover missing source, corrupt JSON, bad model hash, symlink, insufficient space, interrupted copy/commit, backup corruption, destination conflict, rerun, and rollback after new History/Usage writes. Implement restore as an explicit verified operation with writers stopped; merge newer compatible data by identity or retain both versions for explicit resolution.
- [x] For rollback, keep the shared Usage ledger in place and do not restore an older Usage snapshot over newer totals. Preserve destination and source History versions, including deletions; stable-ID union alone must not resurrect deleted entries. When deletion/conflict provenance cannot establish a lossless reconciliation, require explicit recovery selection before restarting the old host. Never expire or delete backup/source data automatically in this phase.
- [x] Exercise the pre-install entry point against injected temporary bundle/source/backup paths, including an old host restarted during backup, a changed source after receipt creation, failed preference import, pending termination and migration cancellation. Add startup-controller tests under `Mac UtilitiesTests/Window/HostStartupTests.swift`; verify no feature/writer factory is called before commit or after a failed/cancelled bootstrap. Retain existing schema tests rather than duplicating their decoder assertions.

## 12. Risks And Rollback Notes

- **Implementation Risks:** Event ordering, native API restrictions, stale generations and storage identity must be verified on the signed candidate.
- **Operational Risks:** Sandbox removal does not grant microphone/Accessibility/input authorization. Stable signing identity and supported group access must be verified; failure blocks rollout rather than changing group identity.
- **Rollback Approach:** Keep verified source/backup and the privately archived old bundle. Stop writers before running `--restore-directory`. Restore exports only to an absent recovery directory and never replaces the shared Usage ledger or current History. Newer records and deletions remain in their current stores. Reusing an older host requires an explicit recovery choice; no automatic union or snapshot overwrite is implemented.

## 13. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:**
```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-dictation CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test
```
- **Targeted Tests:** Existing speech/window/storage suites plus `HostStorageMigrationTests` and `HostStartupTests`. The full run completed 396 tests across 32 suites: 394 passed and two existing opt-in signed stability tests were skipped. Diagnostic scheduling and the stability-session lifecycle were not changed by this phase. Migration fixtures use disposable private directories and isolated preferences, never personal stores.
- Regenerate the project after target configuration changes with `xcodegen generate --spec project.yml`. Use the signed Release build and `codesign --verify --deep --strict` procedure in Standards §5; ad-hoc tests cannot establish group or global permission access.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Response Code |
| :--- | :--- | :--- | :--- |
| Populated upgrade | Backup and migrate isolated fixtures | Counts, IDs, timestamps, preferences and model hashes preserved | Not applicable; native operation |
| Interrupted copy / disk full | Inject failure before commit | Source remains intact; startup blocked with recovery | Not applicable; native operation |
| Repeated launch / conflict | Run twice or supply populated destination | No duplication or silent overwrite | Not applicable; native operation |
| Signed host and widget | Install only after verified backup | Unsandboxed host; sandboxed widget; same ledger | Not applicable; native operation |
| Rollback after new writes | Create newer records then restore | Newer data preserved or explicit reconciliation required | Not applicable; native operation |

### C. Evidence To Capture

Record test totals, configuration/entitlement checks without signing secrets, synthetic UI captures, native outcome counts and relevant resource/compatibility limitations. Keep backup manifests, real transcripts, model assets and per-utterance evidence outside Git. Verify Release excludes Debug preview routes and verification namespaces. Each phase includes its own implementation checks; there is no test-only phase.

## 14. Execution Notes

- **Status:** Completed
- **Started At:** 2026-11-08
- **Completed At:** 2026-11-08
- **Blockers Encountered:** None remaining. After the final hosted test run, temporary registrations were removed and the reopened native gallery confirmed both Medium and Large families render correctly. The existing live widget also displayed saved Usage data.
- **Notes:** A durable private backup and separate restore were verified before signed installation. Post-cutover checks confirmed preserved History identities/timestamps, model hashes, allowlisted preferences and existing Usage records; current-day counters continue without reset. Relaunch preserves the terminal receipt and does not reimport legacy History. English and Urdu model loading and microphone start/stop passed basic native smoke checks; these checks do not claim a new speech-quality benchmark. Notifications authorization, display settings, Keep Awake presets and native start/cancel behavior remain functional without changing login registration. Both widget families were inspected in the native gallery and rendered saved data through the OS-launched installed extension; the temporary verification placement was removed. Host/widget signatures and group agreement, Release route exclusion, generator idempotency and whitespace checks passed. Private receipts, backup locations and personal content remain outside Git. Phases 19 and 20 were not started.
