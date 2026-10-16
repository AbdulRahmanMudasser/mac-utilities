# Desktop Development Standards

## 1. Scope And Platform

Mac Utilities is a native SwiftUI/AppKit application for this arm64 MacBook, targeting macOS 26.6 and later. The [PRD](../mac-utilities-prd.md) owns product behavior. [Phase 08](./phase-08-shared-architecture-foundation.md) records the shared architecture and canonical storage contract. Completed earlier phases remain historical implementation evidence.

## 2. Source Ownership

| Directory | Responsibility |
| :--- | :--- |
| `MacUtilities/App/` | App composition, delegate and singleton utility-window lifecycle |
| `MacUtilities/Features/Popover/` | Menu-bar label and popover |
| `MacUtilities/Features/Usage/` | Sampling/accounting coordination, history UI and projection publication |
| `MacUtilities/Features/Connection/` | User-started diagnostics and their models |
| `MacUtilities/Features/Settings/` | Settings presentation |
| `MacUtilities/Platform/` | AppKit resources, network counters, processes, login items and canonical storage |
| `MacUtilities/UI/` | Shared host typography, cards, controls, spacing and tooltips |
| `Shared/` | Value types, calendar/range calculations, byte formatting, bounded projection reader and chart presentation |
| `Mac UtilitiesTests/` | Usage, Connection and Window regression suites |

Dependencies flow from app/features into platform adapters and shared values. `Shared/` must not import AppKit, ServiceManagement, collection code, process execution or canonical writers. Its presentation file may import SwiftUI; storage/model files use Foundation. Explicitly isolate pure types from the host's default MainActor and use valid Sendable value contracts. No framework/package target is needed for these local sources.

## 3. Runtime Ownership And Storage

- One `UsageMonitor` owns collection while the app is open, including when all views are closed. One `ConnectionDiagnostics` owns manual checks; the singleton window owns presentation and close-time diagnostic cleanup.
- `UsageStateStore` owns canonical decoding, validation and atomic writes. `UsageWriterLease` holds a stable nonblocking lock until shutdown. A second writer must fail before collecting.
- Resolve the group using the built `MacUtilitiesAppGroupIdentifier` key and `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. Do not construct a production container path manually or fall back to legacy writes.
- Canonical data is `Library/Application Support/MacUtilities/today-usage.json` beneath that group. Schema 3 retains independent Today counters, daily history, checkpoints and timestamps. The optional schema-1 `widgetSnapshot` is derived from canonical history and committed in the same atomic replacement; there is no sidecar ledger.
- Shared limits are 9 MiB per envelope, 64 KiB per projection and 31 local-day projection records. Preserve valid core state if the optional projection is invalid; regenerate derived data. Protect unsupported/corrupt core data. A size/write failure preserves the last file and exposes a saving error without pruning history.
- The sole installation's usage history was copied into the shared canonical file before this implementation. Startup reads only that file; it does not resolve or import data from another location. An absent canonical file starts a new ledger. Retained backup files are never automatic recovery sources; restoring one requires an explicit recovery action with collection stopped.
- Reset Today preserves history. Clear History preserves Today and atomically clears the projection. Missing days are unknown, recorded zeroes are measured zero, and all totals remain observed traffic. `savedAt` is distinct from `lastObservedAt`.
- Publish commit callbacks only after a successful canonical write. Phase 08 adds no WidgetKit target or reload behavior.

## 4. UI Conventions

Reuse `UtilityStyle`, `UtilityPanel`, shared controls and tooltip components. Preserve semantic fonts, Title Case labels, card/section spacing, native accessibility and the existing sidebar/keyboard conventions. Keep the 620 × 420 minimum and 860 × 660 default window sizes. The popover remains compact and closes when opening the utility window. Do not create a second style system for new Connection tools. Share chart scale/series definitions through `UsageChartPresentation`; adapt future widget layout to its own system margins.

## 5. Reproducible Project And Local Signing

`project.yml` is the tracked XcodeGen specification; `/MacUtilities.xcodeproj/` remains ignored. Use XcodeGen 2.46.0. Version/build belong in `Configuration/Version.xcconfig`. `Configuration/Build.xcconfig` loads the optional, exactly ignored `Configuration/Signing.local.xcconfig`; create it locally with `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY` and `MACUTILITIES_APP_GROUP_IDENTIFIER`. No tracked signing example is required. Never commit personal signing values, certificates or private keys.

`Configuration/Info.plist` is preprocessed and merged by Xcode. Its custom group key must be present in the built plist; arbitrary `INFOPLIST_KEY_` settings alone do not reliably emit custom keys. Only Debug includes the optional UUID verification namespace. Entitlements use the same local group setting. Release contains no verification namespace key.

```sh
xcodegen generate --spec project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-foundation CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-foundation build
codesign --verify --deep --strict '/tmp/mac-utilities-foundation/Build/Products/Release/Mac Utilities.app'
```

The ad-hoc test command proves injected regressions, not App Group authorization. Verify matching signed entitlements, built group configuration and actual sandboxed container read/write before changing this setup. The supported route is a local Apple Development signature with the documented team-prefixed macOS group form; public distribution/notarization is outside this scope. Do not change the stable group without a separate data-transfer design.

## 6. Verification And Privacy

Hosted tests use temporary URLs and isolated preferences/login adapters, with parallel hosted execution disabled. Never point tests at personal history or change Start At Login during tests. Keep clocks, counter readers, process runners and storage roots injectable. A failed startup or verification-only launch must not claim active monitoring.

For signed native fixture checks, build Debug with a fresh UUID `MACUTILITIES_VERIFICATION_NAMESPACE` and supply synthetic saved state in that namespace. A normal launch of that verification build shows the saved fixture without sampling. Remove only its UUID namespace after quitting it. Never use the namespace as a production fallback; Release rejects any nonempty namespace supplied to the resolver.

Review the entire changed source/config set, run the phase's regression and signed integration gates, verify generator idempotency and inspect compact/default/expanded native layouts. Preserve private rollback backups outside Git. Confirm no duplicate app/test processes remain. Use the update-docs workflow to revise current authoritative contracts in place; preserve chronological logs and completed phase records.
