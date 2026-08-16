import SwiftUI

struct PhonePadEditingMenu: View {
    let toolController: PhonePadEditorToolController
    let mutationDisabled: Bool
    let interactionDisabled: Bool
    let onErrorMessage: (String?) -> Void

    var body: some View {
        Menu {
            Button("Undo") {
                perform {
                    try toolController.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityIdentifier("phonepad.edit.undo")
            .disabled(mutationDisabled)

            Button("Redo") {
                perform {
                    try toolController.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityIdentifier("phonepad.edit.redo")
            .disabled(mutationDisabled)

            Divider()

            Button("Cut") {
                perform {
                    try toolController.cutSelection()
                }
            }
            .keyboardShortcut("x", modifiers: .command)
            .accessibilityIdentifier("phonepad.edit.cut")
            .disabled(mutationDisabled)

            Button("Copy") {
                perform {
                    try toolController.copySelection()
                }
            }
            .keyboardShortcut("c", modifiers: .command)
            .accessibilityIdentifier("phonepad.edit.copy")

            Button("Paste") {
                perform {
                    try toolController.paste()
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            .accessibilityIdentifier("phonepad.edit.paste")
            .disabled(mutationDisabled)

            Button("Delete") {
                perform {
                    try toolController.deleteSelection()
                }
            }
            .accessibilityIdentifier("phonepad.edit.delete")
            .disabled(mutationDisabled)

            Button("Select All") {
                perform {
                    try toolController.selectAll()
                }
            }
            .keyboardShortcut("a", modifiers: .command)
            .accessibilityIdentifier("phonepad.edit.select-all")
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        .accessibilityIdentifier("phonepad.edit.menu")
        .disabled(interactionDisabled)
    }

    private func perform(_ command: () throws -> Void) {
        do {
            try command()
            onErrorMessage(nil)
        } catch {
            onErrorMessage(error.localizedDescription)
        }
    }
}

struct PhonePadPrivacySheet: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("MacPad Mobile") {
                    Text("MacPad Mobile does not collect usage, document, pasteboard, or print data.")
                }

                Section("Pasteboard") {
                    Text("Copy and Cut send selected text to Apple’s system pasteboard only after your explicit command. Paste reads text from that pasteboard only after your explicit command. Universal Clipboard may sync it according to your Apple device settings.")
                        .accessibilityIdentifier(
                            "phonepad.privacy.pasteboard"
                        )
                }

                Section("Printing") {
                    Text("Print hands the current Document text to Apple’s system print interaction only after your explicit command.")
                        .accessibilityIdentifier("phonepad.privacy.print")
                }
            }
            .navigationTitle("Privacy")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("phonepad.privacy.done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.privacy.sheet")
    }
}
