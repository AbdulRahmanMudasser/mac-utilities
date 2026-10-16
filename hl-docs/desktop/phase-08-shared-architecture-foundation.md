# Phase 08 - Shared Architecture Foundation

## 1. Phase Purpose

Establish reproducible project generation, clear source ownership and safe shared usage storage before adding the next Connection tools and a native macOS usage widget. This is the first of four planned phases, followed by [Phase 09](./phase-09-extended-stability-checks.md), [Phase 10](./phase-10-wireless-link-quality.md) and [Phase 11](./phase-11-configurable-usage-widget.md).

## 2. Feature Objective

- **Phase Goal:** Organize the existing implementation around app composition, features, platform adapters and reusable usage contracts; use the supported App Group container for the canonical usage ledger without changing accounting.
- **User Or System Outcome:** A fresh checkout can reproduce the app/test project; saved Today counters and chart history survive the transition; future features reuse existing ownership and visual conventions.
- **In Scope:** Tracked XcodeGen specification, explicit build/entitlement configuration, source moves and focused extractions, shared usage types/formatting/chart data, single-writer storage, an atomically embedded widget snapshot contract, regression coverage and architecture documentation.
- **Out Of Scope:** New diagnostics or widget UI, a backend, cloud sync, per-app attribution, Network Extensions, database adoption, public distribution, changed usage retention/reset semantics, and cosmetic redesign of the popover. Do not add layers, packages or generic repositories without an actual second consumer.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md).
- **Product Source:** The approved request extends the [PRD](../mac-utilities-prd.md). Its device accounting, privacy, reset and window contracts continue to apply. The PRD now records shared App Group storage and the matching local development signature.
- **Prerequisites (Blocked By):** Completed [Phase 07](./phase-07-usage-history-chart.md). The sole installation's history was copied to the canonical container before this implementation; verify App Group signing/container access before collection.
- **Downstream Tasks (Unlocks):** Phases 09–11. Phase 11 requires the storage contract and signed container gate; Connection features reuse the reorganized paths.
- **Target Git Commit Prefix:** `refactor(core): ...`; `build(project): ...` and `feat(storage): ...` for their respective changes.
- **Project Profile(s):** Native macOS SwiftUI/AppKit app, Foundation persistence and local Xcode build configuration (high confidence). A WidgetKit extension is added only in Phase 11.
- **Applicable Development Standards:** [Desktop Development Standards](./development-standards.md), with the retained UI/accounting contracts in [Phase 06 Section 7](./phase-06-unified-utility-window.md) and [Phase 07 Sections 6–8](./phase-07-usage-history-chart.md). Central host styles live in `MacUtilities/UI/UtilityStyle.swift`. The common engineering baseline supplied ownership/validation guidance during implementation; no applicable AGENTS.md or native desktop fallback was found.
- **Platform References:** [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [App Group authorization on macOS](https://developer.apple.com/documentation/xcode/accessing-app-group-containers), [shared containers](https://developer.apple.com/documentation/xcode/configuring-app-groups). XcodeGen supports tracking a specification while keeping the generated project ignored.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** TBD
- **Target Window:** TBD
- **Related PRD Section:** FR-2–7, FR-13–14; Runtime And Data Contracts; Dependencies.
- **Related Build Plan Section:** Not applicable; the execution workflow owns delivery sequencing.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** No production environment variables. Signing values belong in ignored `Configuration/Signing.local.xcconfig`, loaded through the tracked build configuration. No signing example file is needed or tracked. Use an injected temporary storage root for tests and previews. Never infer production group access from a test override.
- **Database/Index Changes:** No database. Preserve schema 3 of `PersistedUsage`, including Today totals, history, timestamps, boot identity and interface checkpoints; add only an optional derived `widgetSnapshot` field to that envelope. Existing valid schema-3 snapshots without this additive field remain supported. The sole installation's `today-usage.json` was copied to `Library/Application Support/MacUtilities/` beneath `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` before the app began using the canonical store.
- **Signing Gate:** Verified with a sandboxed process using the available Apple Development identity, then the signed host against synthetic storage fixtures. The selected stable group uses the documented `<signed-team-id>.com.abdulrahman.mac-utilities.shared` form, which avoids an App Group provisioning profile but requires a valid matching team signature. Keep the team prefix local and resolve the same identifier from configuration; a team setting alone is insufficient evidence. If authorization fails on another setup, stop collection and preserve the canonical data. Do not use a hardcoded container path, sandbox exception or ad-hoc entitlement as a substitute. Phase 11 must separately prove actual extension authorization before rollout.
- **Feature Flags / Config Switches:** Preserve app/test bundle IDs, module `Mac_Utilities`, macOS 26.6 deployment target, Swift language/concurrency settings, current version/build, icon resources, sandbox/network permissions, Start At Login and Debug launch routes. Keep `/MacUtilities.xcodeproj/` ignored. XcodeGen 2.46.0 is installed; pin the supported generator version in the future build instructions.
- **Signed Verification Isolation:** Define an optional Debug-only build setting/Info.plist value `MACUTILITIES_VERIFICATION_NAMESPACE`, shared by both future targets and restricted to a safe UUID path component. It redirects verification fixtures to `Verification/<namespace>/` within the authorized group, disables live collection and is never a fallback for production. Release rejects a nonempty namespace. App-hosted unit tests continue using injected temporary URLs. This lets later OS-launched widget processes read signed synthetic fixtures without assuming they inherit the host's command-line/environment overrides. Remove the namespace directory and restore the normal app after native checks.
- **Seed / Fixture Requirements:** Supported schema 1/2/3 files, deliberately different Today/history totals after resets, cleared ledgers, corrupt/future data, failed writes, denied container access and competing writer instances. Tests must never open personal usage storage or mutate the installed app.
- **Required Reusable Utilities:** Retain `UsageMonitor`, `UsageHistory`, `UtilityWindowCoordinator`, `DiagnosticProcessRunner` and shared UI helpers; extract their existing responsibilities rather than creating parallel implementations.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** Local app startup resolves canonical storage, obtains the writer lease, loads state and then starts collection. Existing schema compatibility remains within the canonical state decoder. The future widget is a read-only consumer. No network endpoint is added.
- **Canonical State Contract:** Only the host app writes `today-usage.json`. Preserve existing byte arithmetic, calendar keys, schema validation and atomic replacement. Keep the current bounded decoding protection; it must accept every valid snapshot currently accepted. A failed or unsupported load must preserve the file and expose an error. A new persistence type must not silently convert an unreadable file into empty history.
- **Failure And Writer Contract:** Use `usage-writer.lock` next to the canonical file and hold its nonblocking flock/file descriptor until the final shutdown write has completed; do not delete/recreate the lock inode. A competing instance must not collect into or write the same ledger; show a clear already-running/storage state or foreground the existing app. Denied group access or lock failure must not silently fall back to another storage location. Explicit test/previews use isolated injected paths and never access production storage.
- **Widget Snapshot Contract:** Embed a derived `widgetSnapshot` object inside the canonical `today-usage.json` envelope; do not create a separately committed widget data file. It is a presentation projection, never an independent accounting source. Its schema 1 contains `schemaVersion`, `savedAt`, optional `lastObservedAt`, `timeZoneIdentifier`, `dataUnit` (`decimal`/`binary`) and records within the 31 local calendar days through the publication day, using existing day keys, bytes and observation bounds. This covers every supported range with at most 31 records; do not select the largest 31 keys if a prior clock change left future-dated records. The projection excludes interface counters, boot identity, Wi-Fi identifiers and diagnostic results, although host checkpoints remain in the surrounding canonical envelope. Missing dates remain absent; measured zero remains a record. The app recovers and accounts from the canonical history, never from this derived field. The widget performs a bounded read of the canonical file and decodes only the supported envelope version and projection, without constructing the full history/checkpoint model.
- **Publication Contract:** Build the projection from the exact state about to be committed and include both in the same atomic replacement, retaining the existing five-second canonical save cadence. Force a commit after Clear History, data-unit changes, day/time-zone transitions and orderly quit. There is no independent cache-write failure or two-file publication ordering: a failed commit leaves the previous complete file, exposes a storage warning and retries using in-memory intent; a successful clear commit contains both an empty history and empty projection. On reload/restart the widget can never read a separately stale pre-clear cache. Already rendered WidgetKit timelines can remain visible until the system honors a reload request; a successful disk clear is not an immediate guarantee of on-screen widget erasure. Preserve standard app preferences; only the data-display unit is copied into the projection. Distinguish `savedAt` from actual observation time; a forced save must not make old measurements appear fresh. A data-unit preference survives independently in UserDefaults; after a crash before the forced usage commit, the next startup regenerates the projection using that preference.
- **Read Limits And Derived Recovery:** Share one new whole-envelope ceiling of 9 MiB between host and widget readers, increasing the existing 8 MiB ceiling to leave room for the additive projection. Limit the serialized projection to 64 KiB and 31 records; validate the fully encoded envelope against the shared whole-file ceiling before atomic replacement so no successful write creates a file that readers reject. Preserve every previously accepted 8 MiB snapshot and test an exact legacy-boundary file plus its projection, as well as new-limit/limit-plus-one fixtures. If a later encoded ledger exceeds the safety ceiling, preserve the last file, retain current observations in memory, surface a saving error and do not prune history. This is an input/memory safety bound, not a data allowance or automatic retention policy. Define shared limits in `Shared/Storage/UsageStorageLimits.swift`. The host decodes and validates core schema/history independently from the optional derived field: absent, malformed or unsupported projection alone must not discard or block otherwise valid history. Regenerate that field from valid canonical history and commit it atomically; an unsupported root schema or corrupt core remains protected. The widget validates the envelope version and projection it consumes and shows unavailable for invalid derived data. Verify provider peak memory/latency using a valid near-9-MiB synthetic envelope; never materialize the full history/checkpoint model in the extension.
- **Shared Code Boundary:** `Shared/` contains value types, calendar/range calculations, byte formatting, projection decoding and chart presentation inputs. AppKit activation, ServiceManagement, counter collection, diagnostic processes and canonical writes stay host-only. Compile shared files into the existing host target and the future extension through explicit XcodeGen source membership; a package/framework target is unnecessary for two local consumers at this size.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** Existing rates, Today, history, reset, units, login preference and window routes behave as before with the canonical shared ledger. Storage failures remain visible and actionable. Production collection starts only after storage ownership is established. Expose startup storage readiness from the store to UsageMonitor.collectionStatus and the existing Settings status row: denied group or duplicate writer must not show Device Monitoring Active when sampling never started. Preserve live in-memory collection with a separate save warning after a transient write failure once ownership/load succeeded; no extra Readiness section is introduced.
- **System Behavior Change:** Source placement reflects ownership; the app remains the sole collector while open. Reuse the singleton window, close-time diagnostic cleanup and test activation injection. Keep all clocks, filesystem boundaries and OS readers injectable at existing test seams.
- **Error States To Support:** Missing/denied group, corrupt or unsupported canonical state, duplicate writer, projection validation failure and failed writes. Preserve prior files and in-memory observations where storage had already loaded safely; never fabricate saved success.
- **Accessibility / Platform Constraints:** Retain shared semantic typography, compact popover dimensions, 620 × 420 minimum/860 × 660 default window sizing, Title Case labels, native chart accessibility and existing keyboard shortcuts. OS signing approval prompts must be reported accurately during future rollout.

## 8. Acceptance Criteria

- A clean checkout plus documented local signing configuration generates the same app/test targets and shared scheme without tracked project files or personal signing values.
- Each source has one clear owner; no duplicate sampler, diagnostic runner, history range or formatter is introduced. Widget source membership cannot pull in the app entry point or collection code.
- Schema 1–3 decoding preserves independent Today/history totals, zero/missing distinctions and all comparable checkpoints.
- Canonical storage decoding, single-writer ownership and atomic replacement hold across the failure cases in Section 6.
- The embedded bounded projection represents all four supported ranges and carries accurate freshness metadata. Rebuilding that field from the canonical history cannot change accounting or restore cleared records.
- The signed target resolves the actual App Group before collection. Existing regression suite, signed build and native app behavior pass after reorganization.

## 9. Implementation Steps (Component Audit)

### A. Project Generation And Source Ownership

- [NEW] `project.yml`, `Configuration/Build.xcconfig`, `Configuration/Version.xcconfig`, `Configuration/MacUtilities.entitlements`, `Configuration/Info.plist`; [MODIFY] `.gitignore`:
  - **Target Anchor:** The ignored local project currently lists one app target, one hosted test target, explicit sources and a shared `Mac Utilities` scheme.
  - [x] Record current targets/settings before replacement. Define the app/test scheme and explicit source ownership; preserve the test host/module, disabled parallel hosted tests, isolated test launch path and all assets. Separate version and local signing values. Resolve one MACUTILITIES_APP_GROUP_IDENTIFIER from local signing configuration; substitute it into entitlements and the MacUtilitiesAppGroupIdentifier Info.plist key so runtime readers never duplicate a team/group literal. Carry the optional Debug verification namespace through a generated Info.plist key; the extension will adopt both keys in Phase 11. Keep the generated project ignored and add the exact `/Configuration/Signing.local.xcconfig` rule; verify it with `git check-ignore -v Configuration/Signing.local.xcconfig` before storing local values. Document generator/build commands and signing/container prerequisites in the desktop development standards, preserving the Phase 00 convention that the repository root has no README.
  - [x] Prove the regenerated project builds with the reorganized sources; regenerate after coherent source moves. Do not add the WidgetKit target yet.
- [MOVE / SPLIT] Existing root app files into the following host-owned layout:
  - `MacUtilities/Mac_UtilitiesApp.swift` → `MacUtilities/App/Mac_UtilitiesApp.swift` (composition and app entry only); extract `AppDelegate` → `App/AppDelegate.swift`, `AppBrand` → `Platform/AppKit/AppBrand.swift`, `SettingsView` → `Features/Settings/SettingsView.swift`, hand-pointer/toggle/picker controls → `UI/Controls/UtilityControls.swift`, and `MenuBarStatusLabel` → `Features/Popover/MenuBarStatusLabel.swift`.
  - `MacUtilities/UtilityWindow.swift` → `MacUtilities/App/UtilityWindow.swift`; preserve coordinator, sidebar shortcuts and popover capture.
  - `MacUtilities/ContentView.swift` → `MacUtilities/Features/Popover/ContentView.swift`; preserve the approved popover.
  - `MacUtilities/UtilityStyle.swift` → `MacUtilities/UI/UtilityStyle.swift`; keep shared window/card/tooltip ownership here.
  - `MacUtilities/Monitoring/UsageHistoryView.swift` → `MacUtilities/Features/Usage/UsageHistoryView.swift`.
  - `MacUtilities/Monitoring/UsageMonitor.swift` → `MacUtilities/Features/Usage/UsageMonitor.swift`; extract `InterfaceCounterReader` → `Platform/Networking/InterfaceCounterReader.swift` and login registration → `Platform/LoginItems/LoginItemService.swift`. Keep one monitor and inject adapters.
  - `MacUtilities/Diagnostics/ConnectionCheckView.swift` → `MacUtilities/Features/Connection/ConnectionCheckView.swift`.
  - `MacUtilities/Diagnostics/ConnectionDiagnostics.swift` → `MacUtilities/Features/Connection/ConnectionDiagnostics.swift`; move `ProbeTarget`, `ProbeStatistics`, `ProbeResult`, `HTTPSResult`, `QualityResult` and `DiagnosticError` into `Features/Connection/Models/DiagnosticModels.swift`; `DiagnosticProcessRunner`/`DiagnosticProcessOutput` into `Platform/Processes/DiagnosticProcessRunner.swift`; `NetworkInterfaceLabel` into `Platform/Networking/NetworkInterfaceLabel.swift`. Preserve parser/process semantics and existing injection seams.
  - [x] Keep icon/catalog resources at their current paths. Remove emptied directories and obsolete references. Organize existing tests beneath `Mac UtilitiesTests/Usage/`, `Connection/` and `Window/` without changing target/module identities.

### B. Shared Contracts And Host Storage

- [MOVE / SPLIT] `MacUtilities/Monitoring/UsageHistory.swift` → `Shared/Usage/UsageHistory.swift`; [NEW] `Shared/Usage/UsageBytes.swift`, `Shared/Usage/UsageFormatting.swift`, `Shared/Usage/UsageWidgetSnapshot.swift`, `Shared/Presentation/UsageChartPresentation.swift`:
  - **Target Anchor:** `DailyUsageRecord`, `UsageHistoryRange`, `UsageHistoryDay`, `UsageHistory.days/totals`, `InterfaceByteCount`, `DataDisplayUnit`, `UsageMonitor.formatData` and existing history chart scale/series tokens.
  - [x] Move pure reusable definitions without changing raw stored units or calendar behavior. Share scale/format/series definitions between host and future widget, with widget-specific layout adapting system margins. Remove state mutation methods from shared history into host `Features/Usage/UsageAccounting.swift`; retain their algorithms and update callers/tests. Keep `RateDisplayUnit` host-only. Isolate pure APIs explicitly from the current default MainActor setting where background reads require it; cross-executor values must have valid Sendable contracts.
- [NEW] `MacUtilities/Platform/Storage/UsageStateStore.swift`, `UsageWriterLease.swift`; [NEW] `Shared/Storage/UsageStoragePaths.swift`, `UsageStorageLimits.swift`, `UsageWidgetSnapshotReader.swift`; [NEW] `MacUtilities/Features/Usage/UsageSnapshotPublisher.swift`:
  - **Target Anchor:** `UsageMonitor.init`, `readState`, `saveState`, `validate`, five-second save cadence, `resetToday`, `clearHistory`, `flush` and `shutdown`.
  - [x] Move `PersistedUsage` and canonical decoding/validation to host storage. Implement the lease and embedded-projection contracts in Section 6. Use injected roots/adapters for tests. Preserve canonical atomic Today/history updates and established byte-accounting behavior; avoid second writers or independent ledgers.
  - [x] Have the monitor own sampling and coordinate persistence/publication through the extracted store. Make UsageSnapshotPublisher build the derived value before the one canonical commit, then emit a successful-publication event only after that commit. It must not write a sidecar file. No WidgetKit import is needed in this phase; expose the commit event for Phase 11.

### C. Regression Coverage And Documentation

- [MOVE / MODIFY] Existing test files into the test folders above; [NEW] `Mac UtilitiesTests/Usage/UsageStateStoreTests.swift`, `UsageWidgetSnapshotTests.swift`:
  - **Target Anchor:** Existing `UsageHistoryTests` synthetic schema fixtures, protected-file cases, failed-write retry, reset/clear, calendar and counter regressions.
  - [x] Retarget tests to extracted owners; cover schema compatibility, writer competition, denied paths, embedded-projection derivation/freshness/limits, failed clear commits and successful-clear crash consistency, valid core with bad derived data, exact old/new size boundaries, and unit propagation. Include filesystem integration using temporary directories and real locking, without personal containers.
- [NEW] `hl-docs/desktop/development-standards.md`; [MODIFY DURING IMPLEMENTATION] PRD, execution workflow and this phase:
  - [x] Document the actual source/dependency graph, process ownership, shared contracts, UI conventions and supported local build/signing route. Update current architecture statements; retain earlier completed phases as historical evidence. Record actual completion gates without claiming public distribution support.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Source moves can change access control, actor isolation or test membership; extraction must preserve algorithms before extending them. Multiple app instances could duplicate usage without the writer lease.
- **Operational Risks:** Ad-hoc tests do not prove group authorization; the installed host now has verified signed access. Future code-signing changes can prompt macOS approval for existing storage. Retain canonical data and rollback app/project backups. Old binaries do not honor the new writer lease and must not run concurrently.
- **Rollback Approach:** Stop all writers. Preserve the canonical ledger and restore the last working app/project. Keep the separate pre-cutover backup outside Git; do not overwrite newer canonical observations with an older copy. Rebuild the embedded projection from canonical history after reapplying the new version.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Generation Command:** `xcodegen generate --spec project.yml`. XcodeGen 2.46.0 generated the project successfully; consecutive generations produced identical project and shared-scheme hashes.
- **Exact Regression Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-foundation CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Scope Of Ad-Hoc Tests:** Existing suite and injected filesystem/model tests only; this command does not prove production App Group authorization. Ensure hosted tests bypass production storage and login/diagnostic side effects.
- **Signed Integration Command:** After configuring a valid local signing identity/group, use the same Xcode arguments with `-configuration Release build`, omit the ad-hoc signing overrides and let the tracked/local configuration supply the verified identity. Verify the built app with `codesign --verify --deep --strict '/tmp/mac-utilities-foundation/Build/Products/Release/Mac Utilities.app'`; inspect its group entitlement and confirm actual runtime access. Do not run the normal collector against real data until the previous writer has stopped.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Existing Canonical Ledger | Relaunch against a synthetic reset-independent history | All fields preserved; only eligible new deltas accumulate | Fixtures and field comparison |
| Protected Or Denied Storage | Supply corrupt/future canonical data or unavailable group | Existing files stay intact; actionable failure; no alternate writer fallback | Tests and signed runtime |
| Competing Copy | Start a second writer against the same injected store | Only one collector can commit; stable lease released at shutdown | Lock integration test |
| Reset / Clear / Units | Reset Today, clear history and switch units | Existing independent semantics; embedded projection changes in the same atomic commit without restoring cleared records | Regression suite |
| Architecture / Native UI | Generate, build, open popover and each section, navigate/close/reopen | Same fonts, controls, routes, sizing and cleanup; no duplicate Dock/test processes | Build and native inspection |

### C. Evidence To Capture

- XcodeGen 2.46.0 generation and hosted tests passed on 2026-10-17: 100 tests across six suites. AppIntents metadata extraction reports no framework dependency, as expected before Phase 11; macOS also emits existing `linkd.autoShortcut` service diagnostics during hosted tests. No Swift concurrency compile warning was reported.
- Synthetic filesystem tests cover writer competition, protected core state, invalid derived data, reset/clear/units and exact 8/9 MiB boundaries. A standalone bounded reader verified an exact 9,437,184-byte envelope in about 5 ms with 36,061,184 bytes peak resident memory for the entire fixture-generating process; this is not an extension memory measurement.
- Signed host synthetic check passed all seven assertions. The installed signed Release has matching group configuration/entitlement and preserved all three real history days and Today on restart. Strict signature verification passed; only one app process remained.
- Native popover, Connection, Usage and Settings checks retained shared styling and routes; default/compact layouts were inspected and window regressions passed. Start At Login was not changed. The UUID verification namespace was removed after stopping its process; private rollback/evidence backups remain outside Git.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-17
- **Completed At:** 2026-10-17
- **Blockers Encountered:** Resolved: the original ad-hoc build could not establish group authorization. A matching Apple Development signature confirmed sandboxed read/write access to the canonical group. Signed integration also caught missing custom built-plist keys; an explicit preprocessed Info.plist now supplies them, with the verification namespace confined to Debug.
- **Notes:** Implementation includes source ownership, generated app/test project, store/lease and atomic projection. The signed synthetic host check passed read-back, competing-writer rejection, reset independence, clear consistency and reopen. The installed Release retained all three recorded days and Today totals across restart and continued sampling with views closed. The original app/project and private data backups remain outside Git. The release version is bumped from 1.0.6 (8) to 1.0.7 (9); Phases 09–11 are not implemented.
