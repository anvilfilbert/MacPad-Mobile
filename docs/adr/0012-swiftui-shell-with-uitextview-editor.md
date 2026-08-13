# SwiftUI shell with a UIKit text editor

PhonePad uses SwiftUI for its universal app shell, adaptive Tab Strip, sheets, commands, and state presentation, with one narrowly scoped `UIViewRepresentable` bridge around UIKit's `UITextView` for editing. Plain-text file rules, metrics, recovery, and conflict detection remain in a UI-independent Foundation core; this combination retains native iOS text-system behavior without forcing the entire app into UIKit or accepting `TextEditor` control limitations.
