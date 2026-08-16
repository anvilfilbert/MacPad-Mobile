# PhonePad 1.0 Design

## Summary

PhonePad is the universal iPhone and iPad sibling of MacPad: a small native plain-text editor with multiple Tabs, direct Apple Files editing, MacPad-compatible text fidelity, and explicit protection against data loss. PhonePad preserves MacPad's stable capabilities and safety guarantees through native iOS and iPadOS interactions rather than copying desktop layout or code.

PhonePad 1.0 requires iOS or iPadOS 18 or newer. Its first TestFlight-upload-ready archive is version `1.0.0`, build `1`, with bundle identifier `com.anvilfilbert.PhonePad`.

## Product Contract

### Included

- Plain-text editing with native undo, redo, cut, copy, paste, delete, and select all.
- New, Open, Save, Save As, and Print.
- One app window containing multiple Tabs on both iPhone and iPad.
- Find, Find Next, Find Previous, Replace, and Replace All.
- Go to Line and localized Time/Date insertion.
- Per-Tab font, zoom, word-wrap, and status-bar settings during the current app run.
- Status showing one-based line and column, zoom, line ending, and encoding.
- Direct editing of original Files selected through Apple Files.
- External Open from Files or another app's Share Sheet for a Supported Text File.
- Explicit File Conflict handling when another process or provider changes an open File.
- Manual Document Recovery for never-saved Documents and unsaved edits to existing Files.
- Touch, hardware keyboard, pointer, Dynamic Type, VoiceOver, Light Mode, and Dark Mode support.

### Deliberate platform deviations from MacPad

- PhonePad never restores prior Tabs or editor UI state at launch.
- PhonePad supports one app window only, including on iPad.
- New Documents use UTF-8 with Unix `LF`, not Windows `CRLF`.
- PhonePad uses native iPhone and iPad controls instead of desktop menus and window chrome.

### Excluded from 1.0

- Session Restore or automatic reopening of recovery items.
- Multiple app windows or independent iPad scenes.
- Rich text, attachments, Markdown rendering, syntax highlighting, or proprietary document formats.
- An app-owned document library, inbox, or file-provider service.
- Accounts, analytics, telemetry, ads, third-party crash reporting, or PhonePad cloud services.
- Cross-device recovery synchronization or backup migration.
- A generic Share Extension for arbitrary selected text, links, or webpages.
- An outward Share command. The required Share Sheet integration is External Open into PhonePad.
- Copying, linking, or porting GPL-covered MacPad source or tests.

## User Experience

### Launch and app structure

An ordinary launch starts with exactly one fresh `Untitled` Tab. A cold External Open starts with only the requested File Tab, or an unsaved Tab when the supplied item is read-only or ephemeral. Prior Tabs, active selection, font, zoom, word wrap, and status visibility are never reconstructed. If preserved work exists, the action menu shows a recovery-count badge without interrupting launch.

Closing the final Tab immediately creates a fresh `Untitled` Tab, so the editor always has an active Document. PhonePad does not show a separate home or library screen.

### Adaptive layout

The layout keeps the same hierarchy on iPhone and iPad:

1. Native top toolbar with the current title, New Tab, and an action menu. The iPad toolbar also shows Open; compact iPhone width places Open in the action menu.
2. Persistent horizontally scrollable Tab Strip.
3. Plain-text editor occupying all remaining content space.
4. Adaptive bottom status bar.

The Tab Strip uses one 44-point interaction row with no additional vertical chrome. Compact Tab capsules are 28 points high and centered within that row. Each Tab cell has separate, nonoverlapping 44-point-high regions for selection and Close; the Close region is 44 points wide, and the title region is at least 44 points wide. This is the minimum touch-safe height and avoids the previous oversized Tab treatment.

The active Tab shows its title, unsaved indicator, and Close control. Inactive Tabs show their titles. Long-press exposes Close and Close Other Tabs. Tabs support drag reordering. iPad adds labels and horizontal space but no sidebar, second navigation row, or second window.

The iPhone status bar uses compact labels such as `Ln 5, Col 37`, `100%`, and `UTF-8 · LF`. iPad shows expanded labels. Status visibility is independently toggleable per Tab.

### Editing behavior

The editor starts with the 14-point monospaced system font, 100% zoom, word wrap enabled, and status visible. Each Tab owns its current font family, zoom, word-wrap, and status settings. Dynamic Type scales the 100% base size; zoom changes in 10% steps from 80% through 500%, clamps the rendered font to 11–96 points, and can reset to 100%. The native system font picker changes the active Tab's family only.

Find and Replace use the native text-system interaction while preserving explicit commands for next, previous, single replacement, and replacement of all matches. An empty search term never performs replacement. Replace All participates in the active editor's undo history.

The SwiftUI editor bridge never replaces `UITextView` content during an active marked-text composition. Programmatic state updates preserve selection and undo history, and Replace All forms one undo group.

Before a Tab switch, Close, recovery selection, or External Open changes the active Document, PhonePad asks `UITextView` to commit marked text on the main actor and waits for its delegate update. The action proceeds only after the committed text passes size validation and a recovery checkpoint is scheduled; otherwise it stays on the current Tab with a specific error. An incoming URL remains queued during this transition. PhonePad never drops or replaces an in-progress composition.

Go to Line accepts a one-based line number within the current Document. Invalid or out-of-range input produces a specific validation message and does not move the selection. Time/Date inserts a localized short date and time using the device's current locale, calendar, and time zone at invocation.

Print sends the active Document's current text, including unsaved edits, to the native print interaction. Print failure does not alter the Document or File.

### Tab closing

Closing a clean Tab closes immediately. Closing an unsaved Tab presents Save, Discard, and Cancel:

- Save writes and verifies the File, then terminates recovery. A failure to terminate recovery leaves the Tab open with a specific cleanup error even though the File is already saved.
- Discard terminates recovery, then closes the Tab. A failure leaves the Tab open and reports the error.
- Cancel leaves the Tab and recovery item unchanged.

Close Other Tabs applies the same rule to each affected unsaved Tab and aborts the remaining close operation when the user cancels.

## Files and Text Fidelity

### File entry points

Manual Open presents Apple's document picker for both `public.plain-text` and generic `public.data`, allowing extensionless or generically typed Files to reach PhonePad's strict byte validation. PhonePad's document-type declaration remains limited to the existing `public.plain-text` type with the Editor role and `LSHandlerRank` Alternate, sets `LSSupportsOpeningDocumentsInPlace` to `YES`, and does not export or redeclare Apple's type. This makes PhonePad eligible as an Open target for compatible plain-text File representations from Files and other apps without a Share Extension. The sending app and system control Share Sheet availability and ordering, so PhonePad cannot guarantee that every sender exposes its item as a File.

An External Open follows the same validation, identity, and safety path as Open. Durable writable access edits the original File in place. Read-only or ephemeral input opens as an unsaved Document labeled with the supplied display name and requires Save As; PhonePad never creates a persistent inbox copy. If the File is already open, PhonePad activates the existing Tab and performs no second recovery prompt. Otherwise, if a pending recovery item exists for that File, PhonePad offers Recover Edits, Discard and Open File, or Cancel; it never hides or duplicates the unsaved version.

File identity separates a stable provider resource identifier, when available, from its mutable standardized locator URL. A provider-reported move that retains the stable identifier is continuity and updates only the locator. A stable-identifier mismatch is a File Conflict. When no stable identifier exists, a locator change is ambiguous and becomes a File Conflict rather than assumed continuity. Recovery resolves its security-scoped bookmark before comparing identity in a later run.

Before PhonePad binds a File to a Tab, reattaches a recovered Document through Locate Original, or accepts a Save As target, it compares active File identities and all other pending recovery items. An ordinary duplicate Open activates the existing Tab. Recovered text that collides with an active File opens only as a detached unsaved copy requiring Save As; Locate Original leaves it detached and can activate the existing Tab. A Save As target owned by another Tab or recovery item is rejected and routes the user to that item. The current Tab may target its own File, in which case Save As applies the selected encoding through the normal conflict-safe Save path. At most one Tab is ever bound to a File.

### Supported Text Files

PhonePad accepts a regular File no larger than exactly 25 MiB (`25 * 1024 * 1024` bytes) whose bytes pass plain-text validation. File-content validation is independent of filename extension after the system supplies a URL. An explicitly resolved rich-text, package, or non-data content type is rejected; an unknown or generic data type proceeds to byte validation. Directory, package, symbolic-link, device, rich-text, binary-like, unsupported, and oversized inputs fail before creating a Tab.

Before decoding, PhonePad rejects exact signatures for UTF-32, RTF/URTF, PDF, binary property lists, ZIP and gzip archives, common raster images, and Mach-O executables. After decoding, it also rejects text whose first non-whitespace characters form an RTF or URTF header. These checks prevent extensionless rich or binary formats from passing through the single-byte fallback. Other undeclared byte streams that pass the deterministic decoder and control rules are treated as Windows-1252 or ISO-8859-1; PhonePad does not claim to infer an unmarked legacy encoding that bytes cannot identify.

Decoding occurs before decoded-text validation so valid UTF-16 NUL bytes are not mistaken for binary data. It uses this deterministic order:

1. UTF-8 with byte-order mark.
2. UTF-16 little-endian or big-endian with byte-order mark.
3. Strict UTF-8.
4. Windows-1252.
5. ISO-8859-1 when Windows-1252 decoding fails.

After decoding, PhonePad rejects NUL scalars. It counts C0 controls other than tab, line feed, form feed, and carriage return, plus DEL and C1 controls; content is binary-like when that count exceeds the greater of eight scalars or one percent of decoded scalars. This deterministic threshold is part of compatibility tests.

Windows-1252 and ISO-8859-1 overlap, so their original label cannot always be inferred from bytes. Ambiguous input uses Windows-1252, and Save As can explicitly select either legacy encoding. PhonePad never rewrites a clean File, so exact source bytes remain untouched until the user edits and invokes Save.

PhonePad normalizes line endings to `LF` inside the editor. It records the dominant source line ending—Windows `CRLF`, Unix `LF`, or classic-Mac `CR`—and restores that style on Save. A tie uses the first observed line ending. Existing Files retain their chosen encoding and detected line ending unless the user deliberately chooses another encoding in Save As. Text that cannot be represented in the selected encoding produces an error rather than substitution or lossy conversion.

New Documents default to UTF-8 without a byte-order mark and Unix `LF`. An edit is accepted only while the complete text has at least one lossless supported encoding no larger than 25 MiB, ensuring the Document always has a valid Save As path. Save and Save As reject an output representation above 25 MiB. Recovery permits a UTF-8 content payload up to 75 MiB, the maximum three-byte expansion of a 25 MiB supported Windows-1252 File.

### Explicit Save and conflict handling

Editing, backgrounding, suspension, and termination never write to the original File. Save is the only operation that writes current text back to its existing File. Save on a never-saved or read-only Document invokes Save As.

PhonePad records a SHA-256 digest and stable identity for the exact File opened or successfully saved. Open, presenter callbacks, foreground reconciliation, and Save also query unresolved `NSFileVersion` conflict versions when the provider supports them. PhonePad never deletes or marks those versions resolved. A digest or stable-identity mismatch, ambiguous locator move, or unresolved provider version is a File Conflict and blocks Save. PhonePad offers:

- Discard Edits and Reload Current, explicitly terminating recovery before reloading. An unresolved provider-version conflict remains blocked until the user resolves it in Files or the provider.
- Save As, preserving both versions.
- Cancel, leaving the Tab and recovery item unchanged.

PhonePad never knowingly overwrites a detected conflict, auto-merges, resolves provider versions, or converts the external version. The final conflict checks and safe-save replacement occur inside one coordinated write accessor using `options: []` for the existing logical File. Foundation explicitly excludes `.forReplacing` from this content-update case, even when the implementation writes another File and renames it into place; `.forReplacing` remains appropriate only for operations such as Save As that may replace a distinct destination item. PhonePad encodes and stages replacement bytes on the destination volume, then requests coordinated replacement. A successful replacement is not trusted until a coordinated read verifies the intended digest; only then does PhonePad update the clean baseline and terminate recovery. Coordination closes the race for cooperating writers, but an uncoordinated writer or provider can still race, so PhonePad makes no absolute overwrite or remote-atomicity guarantee.

If a provider cannot support the required staging or replacement flow, PhonePad fails without attempting an in-place truncate and directs the user to Save As. If a provider reports failure, PhonePad retains recovery, follows any system-reported relocated-original locator, re-reads the destination, and reports whether it contains the original bytes, intended bytes, or an unexpected third version. It never claims unchanged content without verification.

### Save As

Save As first asks for a filename containing one nonempty path component with no slash or NUL scalar. The values `.` and `..` are invalid, and the standardized result must remain a direct child of the selected directory. Provider-specific filename restrictions remain authoritative and surface as typed errors. The user also selects a supported encoding before Apple's folder picker appears.

While the returned directory security scope is active, PhonePad creates a temporary directory bookmark and constructs the child target. It rejects directory, package, symbolic-link, and special-file collisions. It checks active Tab and pending-recovery identities. For an existing regular File, it records a coordinated identity-and-digest snapshot, stops security scope, then offers Replace or Cancel; no security scope remains active during user interaction. Cancel discards the temporary bookmark without changing the Document or recovery.

After confirmation, PhonePad resolves the temporary directory bookmark, restarts security scope, and rechecks the direct-child relationship, target type, target identity and digest, active Tabs, and pending recovery inside the final coordinated accessor. An absent target that appeared, an existing target that changed, or a new identity collision aborts before writing and requires a fresh decision. Otherwise PhonePad performs a staged create or verified replacement and verifies the resulting digest.

PhonePad creates the resulting File bookmark before releasing scope. If bookmark creation fails after a verified write, the title retains the chosen display name and PhonePad reports that a copy was saved but cannot remain attached. The Tab becomes a clean detached Document at the verified baseline; prior recovery terminates through the normal cleanup marker, Close needs no unsaved prompt, and the next edit begins new recovery and requires Save As. A failure before verified output leaves the Document unsaved with its existing recovery intact.

## Document Recovery

### Recovery contract

Document Recovery is device-local loss prevention, not Session Restore or document storage. It covers:

- Never-saved Documents containing unsaved text.
- Unsaved edits to existing Files.

Active recovery items never expire automatically. They remain until a successful Save or explicit Discard. A Document that has become unsaved stays unsaved even if later edits happen to reproduce its clean baseline; Save or Discard is still required, so recovery cannot silently disappear. PhonePad implements no recovery synchronization and requests backup exclusion for every artifact, but that system metadata is not a guarantee against platform-managed backup or migration. Uninstalling PhonePad independently removes its current app container and recovery data.

The recovery list is opened from the action menu's count badge. New never-saved Documents use numbered labels (`Untitled`, `Untitled 2`, and so on). File-backed items and detached read-only or ephemeral External Opens use a protected last-known display name without a path. Every row shows last-edited time and a specific unsaved or access status, but never a content preview. Selecting an item creates a normal unsaved Tab with default editor UI settings; it does not restore selection, font, zoom, word wrap, status visibility, Tab order, or active-Tab state. File identity collision rules run before the recovered Tab is attached.

### Storage and access

Each active recovery item is one versioned, strictly decoded envelope containing at most 64 KiB of metadata and a UTF-8 editor-content payload. Metadata and content are never written as independently replaceable files. The recovery store retains the last verified generation as a temporary backup while it writes, protects, excludes, promotes, and re-verifies a new generation. Only after the final envelope passes complete-protection and backup-exclusion checks may the prior generation be deleted. A failure restores or preserves the last verified generation as canonical and records any residual path for cleanup retry; PhonePad never deletes the only verified checkpoint or reports an edit as protected when persistence failed.

The first transition to unsaved schedules an immediate checkpoint. Later edits use a 300-millisecond quiet-period debounce plus a maximum two-second checkpoint interval while the scene is active, so continuous typing cannot postpone recovery indefinitely. Scene inactivity and background entry request a final checkpoint using available background execution time, but complete protection, process termination, or iOS scheduling may prevent it. PhonePad records a failed background checkpoint when possible and surfaces it on the next foreground. All edits since the last successful checkpoint may be lost; PhonePad makes no fixed or zero-loss guarantee for an ungraceful termination.

Any failed checkpoint places the Tab in a persistent `Recovery Unavailable` state after the current marked-text composition commits. Current text remains in memory, the last verified checkpoint remains recoverable, and the editor stops accepting further text mutations. Copy and selection remain available. Retry Recovery, Save, or Save As first retries the required checkpoint; File writing begins only after that succeeds. Discard remains available without a checkpoint. A banner identifies whether newer in-memory edits are unprotected; a toast alone is insufficient.

For an existing File, the recovery envelope stores a security-scoped bookmark rather than a raw URL and retains the established File identity, clean byte digest, encoding, and line-ending style. Before writing any unsaved Document, PhonePad forces a current recovery checkpoint containing a pending-Save record and intended output digest, creating the envelope if the debounce has not yet run. Save As additionally records the selected directory bookmark and filename until cleanup, allowing an interrupted operation to be reconciled without persisting a raw URL. If this preparatory checkpoint fails, PhonePad does not begin the File write. A clean empty Document may be saved without a recovery envelope because it contains no unsaved User Content.

Open, External Open, and Save As callbacks keep security scope active while creating a bookmark and performing coordinated I/O, then balance it immediately. Later operations resolve the bookmark, reject or refresh stale data explicitly, start security scope, coordinate access, and stop scope. Bookmark creation failure leaves current text intact and produces a specific error; a durable File-backed Tab is not claimed without durable access.

Save and Discard use the same terminal transition whenever an active recovery envelope exists. Before any such Tab becomes clean or closes, PhonePad atomically replaces its active envelope with a content-free cleanup marker. A Tab with no recovery artifact needs no marker. Failure leaves the Tab open with text mutation disabled and Retry Cleanup available. The marker is not shown as recoverable work and its deletion is retried safely because it contains no User Content. Conflict resolution that discards edits completes this transition before reloading external bytes.

If a Save verified the intended File bytes but could not write the cleanup marker, the active envelope and its pending-Save record remain. At the next launch, PhonePad may finish that already-authorized cleanup only when the resolved destination identity and digest still match the pending output. A destination still matching the clean baseline means the write did not happen and the item remains recoverable; any other result preserves the item with a cleanup-unresolved or conflict status and requires explicit recovery or Discard. This prevents stale recovery after a successful Save without deleting ambiguous work.

If a bookmark is stale or access is denied, PhonePad preserves the recovered text and offers Locate Original or Save As. Locate Original requires a new user selection, validates it, checks active Tabs and all other recovery identities, then applies normal File Conflict rules. A collision never creates a second File binding; the recovered Tab stays detached and can be saved elsewhere.

Corrupt or unsupported-version recovery data is reported explicitly and retained until the user chooses Discard Recovery. PhonePad does not silently skip, reinterpret, or automatically delete it.

The recovery state machine is closed as follows:

| State | Persisted artifact | Text mutation | Exit |
| --- | --- | --- | --- |
| Clean | None or content-free cleanup marker | Enabled; first edit enters Protected Unsaved | Edit, Close |
| Protected Unsaved | Active verified envelope | Enabled | Save, Save As, Discard, checkpoint failure |
| Recovery Unavailable | Last verified envelope or none | Disabled after composition commit | Successful retry, successful retry followed by Save or Save As, Discard |
| Cleanup Required | Active envelope plus in-memory terminal intent; a pending-Save record persists Save intent | Disabled | Retry Cleanup only |

File Conflict is an orthogonal Document condition: it retains the current recovery state and offers Reload Current, Save As, or Cancel unless Recovery Unavailable or Cleanup Required first requires its own safe exit. Cleanup-marker deletion failure does not enter Cleanup Required because the marker contains no User Content; deletion retries independently while the Tab may close.

## Architecture

PhonePad uses one native Xcode project with no third-party runtime dependencies.

### Targets

**PhonePad app target**

- SwiftUI lifecycle, toolbar, Tab Strip, status bar, sheets, menus, alerts, and accessibility.
- One narrowly scoped `UIViewRepresentable` around UIKit `UITextView`.
- App command routing, document-picker presentation, External Open routing, and print interaction.

**PhonePadCore library target**

- Immutable, strictly typed Document, Tab, recovery, encoding, line-ending, File identity, digest, metrics, and error models.
- Pure functions for decoding, encoding, normalization, metrics, state transitions, and conflict decisions.
- No SwiftUI, UIKit, persistence, global mutable state, or platform service calls.

**Test targets**

- Core and real-filesystem integration coverage.
- Accessibility-identifier-driven UI coverage.
- A test-only External Open host with stable accessibility identifiers and durable, read-only, and generic-data File fixtures; it is excluded from the PhonePad archive.

### Connectors

Reference types are limited to interfaces with Apple systems:

- A File access connector owns security-scoped access, `NSFileCoordinator`, `NSFilePresenter`, bounded reads, coordinated writes, folder-based Save As, bookmarks, and provider-change notifications.
- A recovery-store connector owns protected paths, atomic persistence, backup exclusion, enumeration, and deletion.
- A print connector presents the system print interaction.

Connectors accept and return structured values and typed errors. They do not mutate caller-owned models. App state transitions return new values, and UI observation is isolated from core rules.

The File connector uses `NSFileCoordinator` and `NSFilePresenter` directly instead of `UIDocument`, because PhonePad's explicit-Save contract must not inherit automatic document writes. Each presented File uses a serial presenter queue. During Open, PhonePad registers the presenter before the final coordinated read and removes it if validation fails. On foreground return, PhonePad re-registers presenters before coordinated reconciliation. This ordering leaves no unobserved gap between the accepted baseline and presentation.

Presenter move and version callbacks schedule serialized reconciliation and never Save, replace content, or resolve `NSFileVersion` conflicts. The File connector removes every presenter before background suspension. Save and foreground reconciliation query unresolved provider conflict versions when supported in addition to identity and digest.

## Data Flows

### New and Edit

`New Tab` → create immutable untitled Document state → show active Tab → edit returns updated state → mark unsaved → schedule protected recovery write.

### Open and External Open

User or system URL → commit active marked text → start security scope → perform preliminary locator collision check → create a security-scoped bookmark → register a provisional File presenter → coordinate bounded read and unresolved-version query → validate Supported Text File → decode and detect line ending → compute digest and stable identity → perform final active-Tab and recovery collision check → stop security scope → accept or activate one File-backed Tab. A failure or duplicate removes the provisional presenter. Read-only, ephemeral, or non-bookmarkable input removes the presenter and becomes an unsaved Document requiring Save As.

### Save

Save command → encode without loss and enforce output size → force recovery checkpoint with pending output digest for unsaved content → resolve bookmark and start security scope → query unresolved versions and perform identity-and-digest check plus replacement in one coordination → block on conflict → perform coordinated digest verification → stop security scope → replace recovery with a cleanup marker → return clean Document state → retry marker deletion independently.

### Save As

Save As command → choose validated filename and supported encoding → encode without loss and enforce output size → present Apple's folder picker → start selected-directory scope → preflight direct-child target, type, identities, recovery index, and optional replacement snapshot → create temporary directory bookmark and stop scope → obtain Replace or Cancel decision → force recovery checkpoint with pending destination and digest for unsaved content → resolve bookmark and restart scope → repeat all checks inside coordinated create or replacement → verify output → create resulting File bookmark → stop scope → terminate recovery → return clean File-backed or clean detached state.

### Recovery

Menu badge → enumerate and strictly decode active envelopes → show metadata-only list → select item → commit current marked text → validate and decode payload → resolve bookmark when present → check active File and recovery identities → create a File-backed or collision-detached unsaved Tab with default UI settings → retain recovery until Save or Discard.

### App lifecycle

Scene becomes inactive or enters background → remove every File presenter → request a best-effort recovery checkpoint → never write an original File. Scene returns to foreground → resolve bookmark and start scope for each File-backed Tab → re-register its presenter → coordinate stable-identity, locator, digest, and unresolved-version reconciliation → mark a File Conflict when needed → stop scope. No lifecycle transition invokes Save.

## Error Model

Every expected failure maps to a specific typed error with an actionable user message. Categories include:

- File unavailable, permission denied, security scope exhausted, or provider offline.
- File not regular, unsupported type, binary-like content, or size above 25 MiB.
- Unsupported encoding or unrepresentable output text.
- File Conflict caused by a content or identity change.
- Coordinated read, write, replacement, or print failure.
- Bookmark creation, resolution, or staleness.
- Recovery protection, exclusion, serialization, version, corruption, capacity, or cleanup failure.
- Pasteboard or marked-text commit failure.

Messages identify the operation and File display name where available, explain why it failed, and state the safe next action. Errors retain the underlying system description for diagnostics without exposing private paths in normal UI. Transient provider reads may retry twice with visible warnings before raising the final error. Before retrying a failed write, PhonePad verifies the destination state: intended bytes mean the content write succeeded, the exact pre-write digest or verified absence permits at most two warned retries, and any third state raises a File Conflict. PhonePad has no silent fallback, silent recovery, automatic merge, or lossy conversion.

## Privacy and Security

- PhonePad has no account, network client, analytics, telemetry, ads, or third-party crash SDK and never independently transmits User Content.
- User Content otherwise exists only in memory, a user-selected Apple Files provider, or protected recovery storage. Explicit Copy or Cut places selected text on Apple's system pasteboard, which may participate in Universal Clipboard under the user's system settings; Paste reads it only after the user's command. Explicit Print hands current text to Apple's print interaction. PhonePad never monitors the pasteboard in the background.
- Apple Files providers may independently synchronize Files under their own terms; PhonePad does not operate that synchronization.
- Recovery content and bookmarks use complete file protection. PhonePad requests and verifies backup exclusion after every replacement and implements no recovery synchronization, while acknowledging that Apple controls platform backup and migration behavior.
- Security-scoped access is balanced and released immediately after each operation.
- No raw external URL is persisted.
- App Store Connect privacy answers must declare no collected data. `PrivacyInfo.xcprivacy` must declare only required-reason APIs actually used by the final binary and must not claim that a manifest alone proves no collection.
- English is the only 1.0 UI and TestFlight metadata language, but every user-facing string uses localization resources.

## Visual Identity and Apple Design

MacPad Mobile follows current Apple Human Interface Guidelines for navigation, touch targets, adaptive layout, typography, system materials, accessibility, and platform controls.

The app icon uses MacPad's document-and-pen `M` mark with a compact `MOBILE` badge in the established cyan-blue accent. The source MacPad visual reference has SHA-256 `b572225699c060beb2589b9dad3590b221cd3e45736aa6e51b03f0fa531a6a75`. MacPad Mobile supplies Apple-compliant 1024×1024 source artwork and appropriate default, dark, and tinted appearances without pre-masking rounded corners.

The interface adapts to orientation, iPad Split View width, system appearance, Dynamic Type, VoiceOver, Reduce Motion, hardware keyboard, and pointer input. At standard content sizes the Tab Strip remains 44 points high; at accessibility content sizes it grows only as needed to prevent clipping, while titles truncate before encroaching on Close targets. Toolbar and status content collapse into their documented compact forms before overlapping. Functional controls have stable accessibility identifiers and labels; color never carries unsaved, active, conflict, or recovery meaning alone.

## Verification

### Automated tests

- Every supported encoding, byte-order mark, and line-ending style, including mixed-ending selection rules.
- Strict rejection of NUL/control-heavy, UTF-32-marked, RTF/URTF, signed binary, rich-text-typed, special, and oversized Files; generic-data and extensionless plain-text acceptance; exact 25 MiB boundary.
- Lossless encode/decode and explicit unrepresentable-character failure.
- Immutable dirty-state, stable identity versus mutable locator, duplicate-open, recovery collision, unresolved-version, digest-conflict, line/column, and Tab transition behavior.
- Recovery versioning, single-envelope generations, prior-generation retention, complete-protection and backup-exclusion verification, checkpoint scheduling and failure lockout, bookmark lifecycle, pending-Save reconciliation, cleanup markers, corruption, retention, and every Save/Discard/reload cleanup transition.
- Real temporary Files for Open, Save, Save As, direct-child enforcement, special-target and duplicate-target rejection, absent-to-present races, external modification, failed replacement, relocated originals, and post-write digest verification.
- Editor integration coverage for marked text across Tab and URL transitions, selection, undo preservation, and one-group Replace All.
- Presenter coverage for registration-before-baseline, serial move/version callbacks, unresolved conflict versions, background removal, foreground re-registration-before-reconciliation, and the invariant that callbacks never Save or resolve versions.
- UI flows for compact Tabs, nonoverlapping accessibility frames, reordering, Close and Close Other Tabs, unsaved prompts, menus, recovery, find/replace, Go to Line, pasteboard commands, and External Open through the test host.
- Direct cold-launch assertions that ordinary launch creates one fresh `Untitled`, External Open creates no extra `Untitled`, no prior Tab state reopens, and no second app scene can be created.
- Byte-identity assertions that editing, inactivity, backgrounding, locking, and termination never alter an original File without Save.
- UI automation locates controls only by accessibility identifiers, not visible text.

Core and File-connector success paths use real temporary Files, real coordination, and the test-only External Open host. Deterministic injected failures cover only system conditions that cannot be safely produced, such as a post-replacement attribute failure. Third-party provider, system Share Sheet, protection-while-locked, and signing behavior remain recorded physical-device or Apple-service checks; test doubles never substitute for them.

### Manual device matrix

- At least one physical iPhone running iOS 18 or newer, plus repeatable compact-width coverage at 375 points or narrower, in portrait and landscape.
- At least one physical iPad running iPadOS 18 or newer, plus repeatable 11-inch-class full-screen and 375-point-or-narrower multitasking-window coverage.
- Touch, hardware keyboard, pointer, VoiceOver, Dynamic Type, Light Mode, and Dark Mode.
- Local Files, iCloud Drive, and at least one named third-party File provider; record device model, OS build, provider name, and provider version with results.
- External Open from Files and one sender app selected before the run; record sender name and version, supplied content type, durable/read-only representation, and expected in-place or detached result.
- Backgrounding, device locking, force termination, low-storage failure, provider-offline failure, and recovery after relaunch.

## TestFlight-upload-ready Acceptance Gate

A build is TestFlight-upload-ready only after the user separately authorizes required Apple Developer Portal and Apple-connected validation actions. Without that approval, work stops after local compile, tests, metadata checks, and an unsigned or development-signed generic-device archive and is reported as not yet TestFlight-upload-ready. After approval, all conditions below must hold:

- Debug and Release compile with zero warnings.
- Automated tests pass and required manual device checks are recorded.
- Deployment target is iOS/iPadOS 18.0 or newer.
- Bundle identifier is `com.anvilfilbert.PhonePad`.
- Marketing version is `1.0.0`; build number is `1`.
- App icon, launch presentation, actual required-reason API declarations, document types, opening-in-place declaration, signing, and entitlements validate.
- The Bundle ID exists in the authorized Apple Developer account, a valid Apple Developer Program team is selected, and App Store distribution signing succeeds. Team identifiers, certificates, and profiles are not committed.
- A Release archive for a generic iOS device is prepared using Xcode's `TestFlight & App Store` distribution route and can be validated or exported without developer-only entitlements.
- The user explicitly authorizes Xcode's Apple-connected Validate App operation, including any artifact transmission it requires, and validation completes without errors. This remains preflight and does not claim App Store Connect processing or TestFlight eligibility.
- Tracked source, assets, and configuration contain no MacPad source/tests, secrets, personal names or email addresses, signing team identifiers, device UDIDs, certificates, provisioning profiles, or absolute home-directory paths.
- No `LICENSE` file or package license declaration exists until the separate publication-and-license decision is made.

Developer Portal Bundle ID creation, signing-profile creation, Apple-connected validation, App Store Connect record creation, archive upload, TestFlight submission, and tester distribution are external actions and require explicit approval before each applicable stage. On an approved upload, `TestFlight & App Store` distribution must be selected rather than Internal Only. The Build becomes TestFlight-ready only after App Store Connect reports processing complete.

## Repository Boundary

All PhonePad code, tests, assets, and release configuration live in the independent private `anvilfilbert/PhonePad` repository. MacPad is an observable behavior and visual reference only. PhonePad does not modify MacPad or depend on its repository, package, build, release, GPL-covered source, or tests.

Whether PhonePad later becomes public and which license it adopts remain intentionally outside this design. Publication requires a separate decision and review before any repository visibility or license change.

## Decision References

The supporting architectural decisions are recorded in [`docs/adr`](../../adr), and canonical product terms are defined in [`CONTEXT.md`](../../../CONTEXT.md).
