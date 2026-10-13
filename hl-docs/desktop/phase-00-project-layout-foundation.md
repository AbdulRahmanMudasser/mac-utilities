# Phase 00 - Root Project Foundation

## 1. Phase Purpose

Establish and run the native macOS app from the repository root. Keep app source and the Xcode project in the repository root while keeping this workflow and its phase plans in `hl-docs/desktop/`.

## 2. Feature Objective

- **Phase Goal:** Confirm the root-level Xcode project builds and launches as a native menu-bar app.
- **User Or System Outcome:** The project has an unambiguous layout and its root-level starter app runs on the target Mac.
- **In Scope:** Preserve `MacUtilities.xcodeproj/` and `MacUtilities/` at the repository root; accept the Xcode license; complete Xcode first-launch setup; build and launch the app.
- **Out Of Scope:** Moving project files into `desktop/`, implementing traffic monitoring, configuring developer distribution signing, or creating a README.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow Log](./execution-workflow.md)
- **Product Source:** [Mac Utilities PRD](../mac-utilities-prd.md)
- **Prerequisites (Blocked By):** None.
- **Downstream Tasks (Unlocks):** Phases 01 and 02.
- **Target Git Commit Prefix:** chore(desktop-scope): ...
- **Project Profile(s):** Native macOS desktop application; SwiftUI/AppKit; root-level Xcode project.
- **Applicable Development Standards:** Codex fallback baseline `check-implementation/references/common-baseline.md`; no repository-specific standards were found.

## 4. Ownership And Delivery Notes

- **Owner:** TBD
- **Priority:** High
- **Target Window:** TBD
- **Related PRD Section:** Sections 4, 8, 12, 13, 14, and 17.
- **Related Build Plan Section:** Not applicable; no separate build plan is maintained.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** Use the selected Xcode installation; `DEVELOPER_DIR` may be needed when command-line tools point to a different developer directory.
- **Database/Index Changes:** None; persistence is introduced in Phase 01.
- **Feature Flags / Config Switches:** None. Local developer signing and target-Mac install checks are tracked in Phase 04. The first release does not use a Network Extension or app group.
- **Seed / Fixture Requirements:** None.
- **Required Reusable Utilities:** None; this phase establishes the existing app scaffold without adding monitoring logic.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** Not applicable; no service API is introduced.
- **Request Schema:** Not applicable.
- **Response Schema:** Not applicable.
- **Local Contract:** Preserve the app entry point, `MenuBarExtra`, and Settings scene. The app project and source remain at the repository root; workflow and phase documents remain under `hl-docs/desktop/`.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** At this phase's completion, the running app showed device rates and labeled app attribution unavailable. The later product decision deferred per-app usage from the first release.
- **System Behavior Change:** No change specific to the root-project foundation beyond confirming that the existing project builds and launches on the target Mac.
- **Error States To Support:** Record Xcode setup, build, and app-launch errors found during local verification. Device-counter availability is the first-release monitoring status.
- **Accessibility / Platform Constraints:** Target the owner's MacBook and installed macOS version/architecture. Do not add cross-Mac compatibility requirements.

## 8. Acceptance Criteria

- `MacUtilities.xcodeproj/` and `MacUtilities/` remain at the repository root.
- The `Mac Utilities` scheme builds from the root-level project.
- The app launches and its menu-bar item and Settings scene are available on the target Mac.
- The menu-bar app launches and displays live device rates from the root-level project.
- Workflow and phase-plan documents live under `hl-docs/desktop/`; the repository root has no README.

## 9. Implementation Steps (Component Audit)

### A. Project And Source Layout

- [VERIFY] `MacUtilities.xcodeproj/`:
  - **Target Anchor:** `MacUtilities.xcodeproj/project.pbxproj` and its workspace metadata.
  - [x] Keep the project and scheme at the repository root; retain the existing `Mac Utilities` target and deployment settings.
- [VERIFY] `MacUtilities/`:
  - **Target Anchor:** `MacUtilities/Mac_UtilitiesApp.swift`, `MacUtilities/ContentView.swift`, and `MacUtilities/Assets.xcassets/`.
  - [x] Keep the app entry point, views, and assets in the root-level source folder.
- [x] Leave developer distribution signing and target-Mac installation checks to Phase 04. No app-group or Network Extension configuration is required for the device-only release.

### B. Monitoring Layer

- [x] Do not add a Network Extension target. Per-app attribution is deferred in Phase 02 until a supported report handoff is proven.

### C. Client / UI Layer

- [x] Preserve the current `MenuBarExtra` and Settings scene; functional UI changes belong to Phase 03.
- [x] Keep first-release status focused on device-counter availability; do not imply that per-app attribution only needs user setup.

### D. Tests And Configuration

- [VERIFY] `MacUtilities.xcodeproj/project.pbxproj`:
  - **Target Anchor:** Existing app target and shared scheme.
  - [x] Confirm the project remains app-only until later phases establish the monitoring and testing architecture.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Incorrect project-relative paths can break Xcode indexing or the build; all app project files are expected at the repository root.
- **Operational Risks:** This phase's local ad-hoc build does not establish that the complete app has been functionally verified on the target MacBook.
- **Rollback Approach:** Revert only the configuration changes that prevent the root-level project from building; retain verified signing and capability findings in the workflow blocker record.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacUtilities.xcodeproj -scheme "Mac Utilities" -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO`
- **Targeted Tests:** No test target exists in the current project; this phase verifies the starter app build and launch.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| Existing scaffold | Build and launch the root-level app | Menu-bar item runs; the Settings scene is declared and builds | Build output, source inspection, and target-Mac screenshot of live menu-bar rates |
| Project references | Open the root-level project in Xcode | Sources and assets resolve from `MacUtilities/` | Xcode navigator or successful build |
| Menu-bar rates | Launch the root-level app and observe its menu-bar item | The app remains running and shows changing device download/upload rates | Screenshot with live menu-bar item |

### C. Evidence To Capture

- Successful Xcode build output for the root-level project.
- Screenshot showing the running root-level app with live device rates in the menu bar.
- The app entry point's compiled `Settings` scene; a separate visual capture of the Settings window was not recorded.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-13
- **Completed At:** 2026-10-13
- **Blockers Encountered:** None for the root project foundation. Target-Mac install verification is tracked in Phase 04; Phase 02 remains deferred pending supported durable app attribution.
- **Notes:** The project is at `MacUtilities.xcodeproj/`, source is at `MacUtilities/`, and platform plans are under `hl-docs/desktop/`. Xcode license acceptance and first-launch setup completed; the root app builds and displays live device rates. Command-line builds select Xcode with `DEVELOPER_DIR`.
