# PhonePad

PhonePad is the iPhone and iPad sibling of MacPad: a plain-text editor with multiple simultaneously open documents.

## Language

**PhonePad**:
The universal iPhone and iPad sibling of MacPad, providing Capability Parity with the documented platform deviations.
_Avoid_: MacPad Mobile, MacPad for iOS

**Capability Parity**:
PhonePad provides MacPad's stable user outcomes and safety guarantees through native iPhone and iPad interactions. It does not imply copied desktop layout or controls, and excludes documented platform deviations.
_Avoid_: Pixel parity, desktop emulation

**Document**:
Plain-text content being edited, whether it is stored in a file or has not yet been saved.
_Avoid_: Note, page

**File**:
The persisted representation of a Document in a user-chosen Apple Files location. PhonePad edits Files in place rather than importing them into an app-owned library.
_Avoid_: Library item, imported copy

**Supported Text File**:
A regular File no larger than 25 MiB whose content is decodable and valid as supported plain text. Rich-text, binary, special, and oversized Files are outside PhonePad's domain.
_Avoid_: Document format, attachment

**External Open**:
A user-directed system request from Files or another app to open a Supported Text File in PhonePad. PhonePad edits a durable writable File in place; read-only or ephemeral input becomes an unsaved Document requiring Save As, never an inbox item.
_Avoid_: Share Extension, inbox import

**Save**:
The explicit user action that writes a Document's current text to its File. Editing and app lifecycle transitions never Save automatically.
_Avoid_: Autosave, recovery snapshot

**Discard**:
The explicit destructive choice that permanently removes unsaved work or unusable recovery data. Closing an unsaved Tab must offer Save, Discard, and Cancel.
_Avoid_: Close, delete

**File Conflict**:
A change in the content digest or stable provider identity of a File since PhonePad opened or saved it, an ambiguous locator move when no stable identity exists, or an unresolved provider conflict version. A provider move retaining the stable identity is continuity, not a File Conflict. A File Conflict must be resolved explicitly before PhonePad can write that File.
_Avoid_: Merge, latest version

**Tab**:
The editor workspace for one open Document during the current app run. All Tabs belong to PhonePad's single app window, and at least one Tab always exists while the app is running.
_Avoid_: Window

**Tab Strip**:
The persistent, horizontally scrollable row above the editor that shows open Tabs and identifies the active Tab.
_Avoid_: Document switcher, bottom navigation

**Session Restore**:
Automatic reconstruction of prior Tabs and their editor state after the app relaunches.
_Avoid_: Document recovery, autosave

**Document Recovery**:
Explicit reopening of device-local preserved unsaved work after PhonePad stops running, covering both never-saved Documents and unsaved edits to existing Files. Recovered Documents never open automatically and remain available until saved or explicitly discarded.
_Avoid_: Session Restore

**TestFlight-upload-ready Build**:
A signed release archive using an approved registered Bundle ID whose distribution configuration, metadata, and separately authorized Apple-connected validation have passed without a TestFlight upload. It becomes TestFlight-ready only after a separately approved upload finishes App Store Connect processing.
_Avoid_: TestFlight release, processed Build

**User Content**:
Document text, File metadata, recovery data, and editor activity handled by PhonePad. PhonePad never collects or independently transmits User Content; only an explicit user action may hand it to an Apple system service such as Files, the pasteboard, or printing.
_Avoid_: Analytics data, cloud account data
