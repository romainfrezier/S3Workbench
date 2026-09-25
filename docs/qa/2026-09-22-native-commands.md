# Native command QA — 2026-09-22

Additional evidence for [#15](https://github.com/romainfrezier/S3Workbench/issues/15)
and [#19](https://github.com/romainfrezier/S3Workbench/issues/19), following the
[September 21 checks](2026-09-21-native.md). Neither issue is closed by this pass.
No product code changed.

## Environment

- macOS 27 beta (26A5425a), Apple Silicon.
- Existing local Debug app, About version 0.7.0 (19), not the published release.
- Executable SHA-256: `18c33609aa0b4ea5b9777f48f496a769b7a62c7d1be4abd07a960a0151087dcd`.
  The hash matches the September 21 app; strict deep ad-hoc signature verification
  passed again. Native sources, tests, package, packaging and scripts remain
  equivalent to `develop` at `a68a6b369321f17f85de92444e5934bcf12c1f8c`.
- Same retained loopback MinIO fixture and restricted synthetic `integration/`
  root. Only fixture names are included below.
- Native accessibility and keyboard input; no VoiceOver speech-output check.

## Observed checks

| Scenario | Result |
| --- | --- |
| Empty selection | File > Download is disabled. Object > Quick Look, Copy Object Key, Copy S3 URI and Delete are disabled. |
| Prefix selection | Selecting `a/` leaves File > Download disabled. |
| Search focus | Command-F focuses the search field while browsing `a/`. |
| Back through menu | Navigate > Back is enabled with search focus. Invoking it returns from `a/` to the restricted root and keeps search focus. |
| Delete confirmation | Select `alpha.txt`, then Command-Backspace: the destructive confirmation opens. File > Download and Upload are disabled during the confirmation. Cancel keeps the file and selection; no delete is sent. |
| Single-file menu download | File > Download is enabled for `alpha.txt` and opens the native destination panel. Cancelling preserves selection and metadata. No download is started by this panel. |
| Quick Look | With `alpha.txt` selected in the table, Space opens Quick Look and displays `alpha QA payload`. The close button returns to the browser. |
| Multiple-file toolbar download | Select `alpha.txt`, then Shift-Down to add `bravo.txt`. The More menu enables Download and Delete while disabling Quick Look, single-object copy actions and Rename. Download opens the destination panel; cancelling preserves both selected rows. |
| Create another scene | Command-N creates a second SwiftUI scene. macOS groups the two scenes as native tabs; the observed IDs end in AppWindow-1 and AppWindow-2. The new scene initially opens the other pre-existing local fixture connection; it is then switched to the restricted QA connection. |
| Independent search and navigation | In scene 2, open `a/`, use Command-F and submit `same`: one indexed result appears, with 1,011 objects indexed. Scene 1 still shows the root, its empty search field and both selected files. |
| Active-scene download | Command-S in scene 1 opens its destination panel. Cancel preserves both selected files. Switching to scene 2 still shows `a/`, query `same`, one result and no selection. Command-S there opens no panel. |
| Reveal in Prefix | Right-click the `same.txt` search result in scene 2; Reveal in Prefix clears the search and selects that object in `a/`. |
| Cleanup and refresh | Close only the newly created scene. Scene 1 retains its root and both selected files. Command-R reloads that root and clears the selection, returning to the initial no-selection state. |

## Network evidence

The [sanitized trace](2026-09-22-command-api-trace.jsonl) records nine requests
with only UTC timestamp, API name and HTTP status: six ListObjectsV2, two
HeadObject and one GetObject; all returned HTTP 200.

- 03:34:53: entering `a/` in the first scene.
- 03:35:13: returning through Navigate > Back.
- 03:35:25: metadata for the selected `alpha.txt`.
- 03:35:57: the one GetObject belongs to Quick Look.
- 03:36:34–35: selecting the restricted connection and entering `a/` in scene 2.
- Until 03:37:21, the indexed query, switching tabs and destination-panel
  cancellation add no request to this fixture.
- 03:37:21: Reveal in Prefix lists the prefix and obtains object metadata.
- 03:37:40: final Command-R lists the current prefix once.

No DeleteObject, DeleteObjects, PutObject or multipart mutation appears in the
trace. The initial connection in the new scene points to a different local
fixture; that fixture's requests are outside this trace. No claim of zero
requests across all configured connections follows from these counters.

## Back shortcut investigation and limits

Injecting `super+bracketleft` with search focus did not navigate, despite an
enabled Back menu item. The menu action succeeded in the same state. A separate
read-only source review followed the shortcut declaration through focused-scene
context, command availability, the shared menu/toolbar dispatcher and
`WorkbenchViewModel.goBack`/`goForward`. There is no search-focus condition in
that route. This narrows the unproven behavior to shortcut delivery, keyboard
layout or native shortcut handling; it does not establish a product defect.
No speculative shortcut change was made. A physical-keyboard check is still
needed, including Forward and other focus states.

These checks establish two independent scenes presented as tabs, not every
separate-window/focus arrangement. No concurrent index rebuild, cancellation,
failed rebuild, VoiceOver, Finder drag, transfer Cancel/Retry, stable-macOS or
released-package validation was performed. Destination panels were cancelled;
completed downloads remain covered by the separate September 21 evidence.
Unit tests, full provider suites and packaging were not rerun for this
report-only change.

The original scene remains open at the restricted root with no selection.
The test scene and Quick Look panel were closed; the trace container was
stopped. The retained MinIO fixture remains running and unpaused. No connection,
preference or remote object was changed or removed. The primary checkout stays
clean on `develop`; this report is prepared in a separate worktree.
