# Agent Guide

## Start Here

Mac Utilities is a native SwiftUI/AppKit menu-bar app for personal use on an arm64 Mac, targeting macOS 26.6+. Keep discovery focused on the requested change.

1. Run `git status --short --branch`; preserve existing work and use the actual current branch.
2. Read the relevant section of [Desktop Development Standards](hl-docs/desktop/development-standards.md), then the affected source. This is the canonical guide for architecture, UI, storage, signing and verification.
3. Read [Desktop Execution Workflow](hl-docs/desktop/execution-workflow.md) only for sequencing or delivery status, and the linked phase document only when its contract affects the task. Read [the PRD](hl-docs/mac-utilities-prd.md) for product requirements.
4. Use targeted `rg` searches and small file reads. Reuse facts already established in this chat; do not repeatedly scan all docs, source, tools or skills.

Resolve conflicts using explicit user decisions and current verified evidence. Check version/configuration and the installed bundle for release facts; workflow prose can lag an installation. Keep transient versions, process IDs, build paths and phase status out of this guide.

## Source Map

| Location | Ownership |
| --- | --- |
| `MacUtilities/App/` | Composition, delegate and singleton utility-window lifecycle |
| `MacUtilities/Features/` | Connection, Usage, Settings and popover behavior |
| `MacUtilities/Platform/` | macOS adapters, networking, processes, login items and canonical storage |
| `MacUtilities/UI/` | Shared styles, panels, controls, cards and tooltips |
| `Shared/` | Shared values, formatting, calendar calculations and bounded projection reading |
| `Mac UtilitiesTests/` | Usage, Connection and Window regression suites |

## Implementation Rules

- Reuse existing shared components and match neighboring sections. Consult Standards §4 for Title Case labels, spacing, timestamps, chart behavior and description cards. Descriptions use the shared two-line overflow behavior with right-aligned Read More / Read Less; warnings and confirmations remain fully visible.
- Keep one usage collector/writer, one diagnostic controller and one transient Wi-Fi monitor. Respect shutdown, cancellation, visibility and stale-result guards. See Standards §§2–3 before changing ownership or persistence.
- Preserve personal usage history and the canonical App Group contract. Tests and previews use isolated storage. Never change login settings or point tests at production data.
- Keep CoreWLAN reads passive and transient: no Location request, SSID/BSSID collection, scans, association or Wi-Fi configuration. Wi-Fi sampling follows Connection visibility and stays outside usage storage.

## Build, Preview And Verification

- `project.yml` is authoritative; `MacUtilities.xcodeproj/` is generated and ignored. Run `xcodegen generate --spec 'project.yml'` when project configuration changes or the generated project is absent.
- Use scheme `Mac Utilities`, destination `platform=macOS,arch=arm64` and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Standards §5 contains the supported build/test/signing commands. Use a task-specific derived-data directory under `/tmp`.
- Version/build live in `Configuration/Version.xcconfig`. Local signing lives in ignored `Configuration/Signing.local.xcconfig`; do not expose or commit its contents. Ad-hoc tests do not prove App Group authorization.
- Bump the version only when requested or required by an explicitly authorized release workflow. Read the current values first, use the user's requested marketing version and increment `CURRENT_PROJECT_VERSION` for the new release. A preview alone does not require a bump. Verify the resulting version/build in the built bundle's Info.plist; do not rely on source values alone.
- A preview means a separate signed Debug build, launched with `open -n` and the existing `--stability-preview` or `--usage-preview` arguments. These isolate usage storage and disable production collection; stability results are synthetic while Wi-Fi readings remain passive live reads. See Standards §6 for appearance/size variants. Keep preview routes Debug-only.
- Installation targets `~/Applications/Mac Utilities.app` and is a separate action from previewing. Verify signature, sandbox/group configuration and requested version before replacing an installed bundle.
- A production/installed build uses the signed `Release` configuration and normal launch, without preview arguments or synthetic fixtures. Verify the Release bundle excludes Debug preview routes and the verification namespace, and preserves the existing sandbox/App Group contract. A successful Debug preview does not replace Release verification.
- When installation is requested, gracefully quit the installed app and task-owned previews, replace the app bundle while preserving usage data, then launch and verify the installed path and version/build. Preview requests leave the installed app bundle in place. Keep any rollback copies outside Git and clean up identified backups/build outputs when the user requests it.
- Run checks appropriate to the change. UI changes need a build and relevant layout/interaction inspection; lifecycle/storage changes need affected regression coverage. Run the signed stability gates when their scheduling/lifecycle contract changes. Report checks actually performed and any skips.
- Clean up only identified task-owned processes and temporary artifacts when appropriate; verify ownership and active use first. Keep generated outputs outside Git.

## Documentation And Git

- Update the existing canonical section in place. Development standards own technical/UI conventions; the PRD owns product intent. Preserve chronological logs and completed historical records. Use the requested documentation skill without duplicating its instructions here.
- Keep current delivery status in `hl-docs/desktop/execution-workflow.md`, dated decisions in `hl-docs/desktop/decision-log.md`, and chronological delivery evidence in `hl-docs/desktop/execution-log.md`. Read the separate logs only when relevant; preserve historical entries and append only when authorized. Keep the workflow's log sections as links rather than copying history back into the tracker.
- Use lowercase branches such as `feature/expandable-panel-descriptions`, with an approved `feature/`, `fix/`, `refactor/`, `docs/` or `chore/` prefix. Do not include phase numbers or tool names in branch names.
- Follow the explicitly invoked commit skill for commits, pushes and PRs. Keep Conventional Commit messages and PR text lowercase, group work logically, and honor the user's requested commit count. Verify the actual default branch rather than guessing it.
- Finish with the changed behavior, checks performed and any material limitation. Distinguish source changes, previews, installed builds and merged releases.
