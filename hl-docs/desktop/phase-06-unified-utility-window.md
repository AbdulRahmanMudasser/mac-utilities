# Phase 06 - Unified Utility Window

## 1. Phase Purpose

Provide one reusable Mac Utilities window for Connection and Settings, with shared design conventions, reliable foregrounding and explicit diagnostic cleanup.

## 2. Feature Objective

- **Phase Goal:** Replace separate Settings and Connection Check windows with one resizable AppKit window and a left sidebar.
- **User Or System Outcome:** Settings and Check select the requested section, dismiss the tray popover and foreground the same window. Navigating between sections preserves results and running checks.
- **In Scope:** Window ownership, routing, popover dismissal, resize/reopen behavior, diagnostic lifecycle, centralized UI styling, simple explanations, accessible controls and regression verification.
- **Out Of Scope:** A Usage sidebar section, new diagnostic measurements, app attribution, historical analytics, changed daily-counter semantics and public binary distribution.

## 3. Project Topology & Dependencies

- **Local Tracker:** [Execution Workflow](./execution-workflow.md)
- **Product Source:** [Mac Utilities PRD](../mac-utilities-prd.md)
- **Prerequisites (Blocked By):** [Phase 03](./phase-03-menu-controls-settings.md) menu controls and [Phase 05](./phase-05-connection-quality-checks.md) diagnostics.
- **Downstream Tasks (Unlocks):** Future utility sections can reuse the shared window and style definitions; no additional section is currently approved.
- **Target Git Commit Prefix:** `feat(window): ...` or `refactor(ui): ...` for the corresponding implementation scope.
- **Project Profile(s):** Native macOS SwiftUI/AppKit desktop application (high confidence).
- **Applicable Development Standards:** Shared UI conventions in Section 7 and `MacUtilities/UtilityStyle.swift`; common engineering fallback baseline from `check-implementation/references/common-baseline.md`. No AGENTS.md or separate repository development standards were found.

## 4. Ownership And Delivery Notes

- **Owner:** Product Developer
- **Priority:** High
- **Target Window:** Completed 2026-10-14 after the final tray interaction and equal-font confirmation.
- **Related PRD Section:** Functional Requirements FR-7, FR-12 and FR-13; Acceptance Criteria.
- **Related Build Plan Section:** Not applicable; the execution workflow owns current delivery status.

## 5. Infrastructure & Environment Requirements

- **Environment Variables:** No new runtime environment variables or credentials.
- **Database/Index Changes:** None. UsageMonitor continues owning daily aggregates and preferences; diagnostic results remain in the app session.
- **Feature Flags / Config Switches:** Existing Debug-only `--settings` and `--connection-check` launch arguments open the requested section for verification and start no traffic. Retain App Sandbox and existing network client/server entitlements.
- **Seed / Fixture Requirements:** Controlled diagnostic operations and native test windows for routing, cancellation, resize, hosting cleanup and popover dismissal.
- **Required Reusable Utilities:** `UtilityWindowCoordinator`, `UtilityStyle`, `UtilityPanel`, `UtilityScrollContent`, `UtilityValueRow`, `utilityCardBackground()` and `handPointer()`.

## 6. API & Data Contract Specifications

- **Endpoint / Event:** No new backend or network measurement endpoint. Settings, Check and application reopen route through `UtilityWindowCoordinator.present(_:)`.
- **Request Schema:** A `UtilitySection` value selects Connection or Settings. Normal startup creates no utility window.
- **Response Schema:** The coordinator reuses one window, selects the requested section, restores a minimized window and foregrounds it.
- **Local Contract:** UsageMonitor and ConnectionDiagnostics retain their existing ownership. Switching sections does not cancel diagnostics. Closing the shared window cancels active checks and releases transient hosted views; reopening rebuilds those views while preserving session results.
- **Popover Ownership:** `MenuBarPopoverWindowAccessor` is mounted only in the tray ContentView background. It captures its enclosing window through AppKit view attachment and updates. The coordinator holds that window weakly and calls `orderOut(nil)` before presenting the utility window; it does not enumerate windows or match private class names.
- **Activation Contract:** Presentation requests regular activation; close and shutdown restore accessory mode. Automated tests inject activation operations to verify these requests without promoting the test host into the Dock.

## 7. UX / Behavioral Expectations

- **User-Facing Change:** The sidebar contains Connection and Settings. The tray remains ordered Connection Health / Check, Current Speed, Today's Usage and footer controls. Quit is a power icon with tooltip and accessibility label.
- **Connection:** Keep the title in the window bar, and status/Cancel outside the scrolling results. Result rows sit directly in their section card without nested backgrounds or double padding. Loaded reply times and reading counts share one line; counts use smaller secondary metadata text. Network Used resolves macOS interface display names, with a labeled raw fallback or Not Reported.
- **Timestamp Convention:** Both checks use a body-sized Last Checked label/date row. A completed check without tool errors uses a green checkmark; probe, web-fallback or speed-test errors use an orange warning. Green indicates completion, not guaranteed Internet quality.
- **Explanation Convention:** Short introductory paragraphs omit provider names while result groups retain endpoint identity. Preserve probe timing, reply counts, endpoint limits, RPM meaning and missed-reply caveats. The speed-test confirmation uses two short paragraphs covering variable data allowance use, possible slowdown, inclusion in Today's Usage while monitoring is on, the one-minute limit and cancellation. Omit generic post-result explanation paragraphs.
- **Settings:** Keep Monitoring, Readiness/time zone, General, Display, Today's Usage and About. Remove the Privacy section. Reset Today's Counters sits below and outside the totals card, right-aligned within Today's Usage. About is one icon/name/version row without the Network Activity subtitle.
- **Shared Design Convention:** `UtilityStyle.swift` owns typography, semantic status colors, control sizes, dimensions and spacing for the window, sidebar, switches, unit picker, About row, menu-bar label, confirmations and compact popover. Connection and Settings use headline titles, body rows/status, callout explanations and caption metadata except body-sized Last Checked rows. Both sections and the tray use `utilityCardBackground()`.
- **Compact Popover Convention:** `UtilityStyle.Popover` owns its compact dimensions and small controls. Speed and usage values share one semibold, monospaced-digit body font without automatic shrinking; their labels share one callout font.
- **Scroll And Resize Convention:** `UtilityScrollContent` fills the detail area, with padding inside the viewport and the scroll indicator at its trailing edge. The fixed Connection footer has matching page padding. Use the centralized 620 × 420-point minimum and 860 × 660-point default window sizes. Section headers adapt when their action cannot fit alongside the title.
- **Accessibility / Platform Constraints:** Preserve readable labels, selected sidebar state, Command-1/Command-2 navigation, button roles and hand pointers. Show a running indicator beside Connection without obscuring its accessible button identity.

## 8. Acceptance Criteria

- Normal startup opens no utility window. Settings selects Settings; Check selects Connection.
- Opening or foregrounding either section dismisses only its menu-bar popover first, including repeated requests.
- Repeated requests reuse one window, foreground it and restore it from minimized state.
- Navigation preserves diagnostic results and running checks; close and quit stop active diagnostics.
- Close releases transient view state; reopen restores the same window and retained session results.
- Compact and expanded sizes remain stable across navigation and reopening, without clipping or hosting-driven shrinkage.
- All app-owned UI surfaces use shared design definitions, with consistent speed/usage value and label fonts.
- Connection and Settings share card, typography and scroll conventions; status/Cancel remain visible.
- Automated window tests verify activation requests without repeatedly adding the test host to the Dock.
- Required automated, build, signature and functional verification evidence is recorded; any unperformed checks remain explicitly pending.

## 9. Implementation Steps (Component Audit)

### A. Project And Data Layer

- [MODIFY] `MacUtilities/Mac_UtilitiesApp.swift`:
  - **Target Anchor:** Shared StateObjects and application delegate.
  - [x] Retain one UsageMonitor, ConnectionDiagnostics and UtilityWindowCoordinator.
  - [x] Route application reopen through the existing coordinator and run diagnostic/window cleanup on quit.
  - [x] Preserve current-day storage and diagnostic session ownership.

### B. Monitoring Layer

- [MODIFY] `MacUtilities/UtilityWindow.swift`:
  - **Target Anchor:** `UtilityWindowCoordinator` and `MenuBarPopoverWindowAccessor`.
  - [x] Create the utility window lazily and reuse it for both sections.
  - [x] Dismiss only the weakly captured popover before utility presentation.
  - [x] Preserve diagnostics during navigation; cancel on close/quit and clear transient hosted views.
  - [x] Pin the NSHostingController inside a plain AppKit container on all four edges, disable hosting sizing options and synchronize container bounds on resize.
  - [x] Restore accessory mode on close/shutdown and expose injectable activation operations for tests.

### C. Client / UI Layer

- [MODIFY] `MacUtilities/UtilityStyle.swift`:
  - **Target Anchor:** Shared tokens, panels, value rows, scroll content and card background.
  - [x] Centralize window and popover typography, spacing, colors, control sizes and dimensions.
  - [x] Reuse shared cards and scroll layout; retain compact popover density.
- [MODIFY] `MacUtilities/ContentView.swift`:
  - **Target Anchor:** Tray content and Settings/Check actions.
  - [x] Preserve approved section order and route both actions through the coordinator.
  - [x] Mount the popover window accessor and use equal, nonshrinking speed/usage fonts.
- [MODIFY] `MacUtilities/Mac_UtilitiesApp.swift` and `MacUtilities/Diagnostics/ConnectionCheckView.swift`:
  - **Target Anchor:** Settings controls, Connection results and confirmation sheets.
  - [x] Apply centralized styling, simplified explanations and semantic Last Checked rows.
  - [x] Preserve reset placement, compact About, adaptive section headers, fixed status footer and accessibility.

### D. Tests And Configuration

- [MODIFY] `Mac UtilitiesTests/UtilityWindowTests.swift`:
  - **Target Anchor:** Coordinator, hosting and activation regression tests.
  - [x] Cover first/repeated routing, singleton reuse, minimized restore, close/reopen, navigation, cancellation and unrelated window events.
  - [x] Cover compact/expanded bounds, bounded constraints and controller release.
  - [x] Cover popover registration/dismissal and activation requests without changing the test host's policy.
- [x] Run the supported suite and signed Release build; verify the Release bundle signature.
- [x] Visually verify actual tray clicks dismiss the popover before opening or foregrounding both sections.
- [x] Inspect the final equal-size numeric layout in the real tray after the no-shrinking change.

## 10. Risks And Rollback Notes

- **Implementation Risks:** Hosting size ownership, transient sheet state, window lifecycle and activation can regress if multiple owners are introduced. Retain the singleton coordinator, pinned hosting container and explicit close/shutdown behavior.
- **Operational Risks:** Automated tests cover controlled AppKit windows and injected activation requests, not operating-system focus or the real MenuBarExtra interaction; the final tray behavior and layout were visually confirmed by the user. Dock caching may still produce stale entries even though tests no longer repeatedly request regular activation.
- **Rollback Approach:** Restore the previous window/UI implementation and rebuild the personal app while preserving UsageMonitor storage. No data migration or network configuration rollback is required.

## 11. Verification Protocol (Definition of Done)

### A. Automated Suite

- **Exact Command:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project 'MacUtilities.xcodeproj' -scheme 'Mac Utilities' -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/mac-utilities-prs CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES test`
- **Build Command:** Same arguments with `-configuration Release build` instead of `test`.
- **Signature Command:** `codesign --verify --deep --strict "$HOME/Applications/Mac Utilities.app"`
- **Targeted Tests:** UtilityWindowTests plus existing UsageMonitorTests and ConnectionDiagnosticsTests.

### B. Functional Verification Matrix

| State | Trigger Action | Expected Result | Evidence |
| :--- | :--- | :--- | :--- |
| First / Repeated Entry | Select Settings or Check from the tray | Popover dismisses; the same window opens or foregrounds the selected section | Controlled AppKit tests pass; user confirmed final tray interactions |
| Existing / Minimized Window | Present an existing utility window | Window reuses its identity, unminimizes and foregrounds | Window tests pass; earlier foregrounding inspection recorded |
| Navigation During Check | Switch sections while a check runs | Results and running work remain intact; sidebar shows running state | Automated lifecycle tests and earlier signed-app inspection |
| Close / Quit | Close the shared window or quit during a check | Child stops; transient hosted state releases; accessory mode is requested | Cancellation, cleanup and activation-request tests pass |
| Resize / Reopen | Resize, navigate, close and reopen | Stable window size, flexible content and bounded hosting constraints | Tests cover 620 × 420, 760 × 500 and 1100 × 800 points; earlier visual resize verification |
| Shared Styling | Inspect Settings, Connection and unit picker | Consistent shared fonts, cards, controls and scroll placement | Visually inspected after centralized-token changes |
| Last Checked / Disclosure | Complete a reply check and open the speed-test sheet | Body-sized semantic timestamp and short, accurate disclosure | Live 10/10 replies from both endpoints and green timestamp inspected; orange failure styling source-reviewed |
| Equal Tray Fonts | Inspect speed and usage values after removing shrinking | Same numeric font and same label font | Shared tokens and fixed-size rendering source-reviewed; user confirmed final tray layout |
| Test Host Activation | Run automated window tests | Policy requests are verified without promoting the test host into the Dock | Activation-request regression passes; test process exits normally |

### C. Evidence To Capture

- **Automated Result:** The full suite passed 51 tests / 66 executions with zero failures, skips or runtime warnings: `/tmp/mac-utilities-prs/Logs/Test/Test-Mac Utilities-2026.10.14_11-56-27-+0500.xcresult`. It covers counters, diagnostic parsing/runner behavior, window resizing/cleanup, popover registration/dismissal and injected activation requests.
- **Build And Signature:** Release 1.0.2 (build 4) built successfully and passed `codesign --verify --deep --strict` at `/tmp/mac-utilities-prs/Build/Products/Release/Mac Utilities.app`. The installed Release 1.0.1 (build 3) previously passed the same signature check and runs from `~/Applications/Mac Utilities.app`; the new build has not been installed.
- **Visual Evidence:** On 2026-10-14, computer use inspected the larger-font popover, short Connection paragraphs, speed-test confirmation, green Last Checked row, and subsequently Settings, unit picker and Connection after centralized-token changes. A live reply check returned 10/10 from each endpoint. The user confirmed the final tray dismissal and equal-font behavior. Earlier evidence covered compact/expanded resizing, foregrounding, retained results and cancellation.
- **Verification Limits:** AppKit tests do not independently prove operating-system focus or the real MenuBarExtra interaction; the user confirmed those final interactions and layout. Orange failure timestamps were source-reviewed rather than exercised with a live failed endpoint.
- **Runtime Cleanup:** Process inspection found one installed app process while multiple stale test/build icons appeared in the Dock. Dock refresh was performed. Automated window tests now inject activation operations; a subsequent suite completed normally and one installed Release instance remained.
- **Implementation Review:** Native SwiftUI/AppKit profile (high confidence), shared project conventions and common fallback baseline. No verified defect remains after correcting failed HTTPS-fallback timestamp status and data-use wording, and centralizing local style values. Automated tests do not prove real application focus or tray interaction.

## 12. Execution Notes

- **Status:** Completed
- **Started At:** 2026-10-13
- **Completed At:** 2026-10-14
- **Blockers Encountered:** None. Native menu-bar inspection had timed out during an earlier attempt; the user subsequently confirmed the final tray interactions and equal-font layout.
- **Notes:** Window ownership, shared styling, automated verification and user-confirmed tray behavior are complete. No additional implementation phase is queued.
