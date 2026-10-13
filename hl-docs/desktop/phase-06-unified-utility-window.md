# Phase 06 - Unified Utility Window

## 1. Purpose And Scope

Replace separate Settings and Connection Check windows with one reusable Mac Utilities window. A left sidebar contains Connection and Settings. Usage is deferred until it has useful content. Keep existing tray controls and counters; order Connection Health / Check above Current Speed and Today’s Usage, with footer controls last and Quit displayed as a power icon.

## 2. Responsibilities

- **Connection:** Manual reply checks, speed test, results, progress, confirmation, and Cancel. Results sit directly inside their section card without nested card backgrounds or double padding. Loaded reply times and reading counts share one line, separated by a middle dot; counts use smaller secondary metadata text. The speed-result rows have no horizontal separator. Network Used resolves macOS display names, retaining a labeled fallback for unknown identifiers and Not Reported for absent identifiers. Both checks use the same compact Last Checked label/date row in metadata typography; omit the generic post-result explanation paragraph.
- **Settings:** Monitoring, readiness/time zone, start at login, display units, counters/reset, and About. Remove the Privacy section from the view. Place Reset Today's Counters outside and below the totals card, right-aligned within Today's Usage. About uses a compact row with the app icon/name on the left and version on the right, without the Network Activity subtitle.
- **Shared UI Conventions:** `UtilityStyle.swift` owns 20-point page padding, 24-point section spacing, 12-point content spacing, 16-point card padding and 10-point corners. Both sections use `UtilityPanel` with headline section titles, body rows/status, callout explanations and caption metadata. Use regular control size, flowing explanatory paragraphs and the same heading/card alignment. Settings uses the shared scrollable panels rather than system Form spacing; the Connection status footer has no separator line. The tray remains outside this window styling scope.
- **Scroll Convention:** Both sections use `UtilityScrollContent`: the ScrollView fills the detail area and padding belongs to its content, placing the indicator at the trailing edge. Connection's fixed status footer has its own matching page padding; it does not inset the scroll viewport or indicator.
- **Product Source:** [PRD](../mac-utilities-prd.md)
- **Delivery Source:** [Execution Workflow](./execution-workflow.md)

## 3. Implementation Plan

1. Add a main-actor window coordinator owning one AppKit window and selected sidebar section. Create the window only on explicit request; foreground the same window on subsequent requests.
2. Route existing Settings and Check tray buttons through the coordinator without changing their presentation.
3. Host existing SwiftUI views inside the shared window; preserve diagnostic results when switching sections. A running check continues across sidebar changes with a visible running indicator in the sidebar; closing the window or quitting cancels it.
4. Remove old independent scenes and section-level close side effects. Restore accessory activation only after the shared window closes. Retain the same diagnostics controller and monitor across reopen. Preserve frame size, disable hosting-driven automatic sizing, and use a 620 × 420-point minimum content area. Pin the NSHostingController inside a plain AppKit container on all four edges, synchronize its container frame on resizing, and keep the SwiftUI root flexible. Section headers adapt when title and button cannot share a line.
5. Add focused routing/window lifecycle regression tests, run the entire supported suite, build Debug/Release, inspect visually, and review implementation against this plan.

## 4. Acceptance Criteria

- No utility window opens at normal startup. Settings selects Settings; Check selects Connection.
- Repeated requests reuse one window, foreground it, and unminimize it if needed.
- Sidebar switching preserves results and does not unexpectedly cancel a running check.
- Close cancels collection tests and permits clean reopen without a second window underneath.
- Quit cancels diagnostics. Settings and device monitoring remain functional.
- Sidebar controls have readable labels, selected state, keyboard support, and hand pointers. Long content scrolls; status/Cancel remain visible in Connection.

## 5. Verification And Evidence

- **Status:** Completed
- **Automated:** Latest recorded full-suite run passed 49 tests / 63 executions, zero failures or skips: `/tmp/mac-utilities-unified/Logs/Test/Test-Mac Utilities-2026.10.13_23-07-09-+0500.xcresult`. Coverage includes resize/reopen at 620 × 420, 760 × 500 and 1100 × 800 points, container/hosted-child bounds, bounded constraints, controller release after close, unrelated resize notifications, and network-name mapping. Later inline-count, explanatory-text removal, Last Checked, tray ordering, reset placement and version changes were Release-built and signature-checked; that earlier full-suite result is not evidence of a new suite run on version 1.0.1.
- **Visual:** Verified signed app Settings-first and Connection-first, both sidebar sections, Command-1/Command-2, selected accessibility state, and running button accessibility. A real reply check returned 10/10 from both endpoints and retained results across navigation. A real load check continued in Settings with a sidebar running indicator; closing from Settings stopped its subprocess. A temporary native preview of the exact tray ContentView verified unchanged layout, Settings/Check routing, close/reopen, and existing-window foregrounding; the preview was removed before final tests/build. Final sizing fix was visually verified across close/reopen and section switching, without clipping or shrinkage. Subsequent computer-use verification resized the real signed window down to compact size and back up, inspected both sections without clipping, and confirmed adaptive paragraph wrapping and controls remaining visible.
- **Build And Signature:** Debug/test and Release builds passed; installed Release signature verified with `codesign --verify --deep --strict`. Retained App Sandbox and network client/server entitlements. Current installed Release: 1.0.1 (build 3), verified against project settings and installed Info.plist. One Release instance runs from `~/Applications/Mac Utilities.app`; no diagnostic child remains. All other app instances were terminated before final testing/install.
- **Implementation Review:** Native macOS SwiftUI/AppKit profile (high confidence), common engineering fallback baseline; no repository AGENTS.md or separate development standards found. Reviewed coordinator, app entry/delegate, tray routing, existing section lifecycle and regression tests. All acceptance criteria fully satisfied. Fixed competing scenes, section-disappearance cancellation, sidebar spinner obscuring the button role, and hosting-driven window shrinkage. Frame ownership is explicit, transient hosting state clears on close, and shared measurement state survives navigation/reopen. Verdict: Implementation is technically correct and architecturally consistent; no unresolved blockers or decisions.
- **Blockers:** None.
