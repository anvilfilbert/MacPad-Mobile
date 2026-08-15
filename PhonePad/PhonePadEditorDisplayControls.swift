import PhonePadCore
import SwiftUI

struct PhonePadEditorDisplayMenu: View {
    let settings: PhonePadTabDisplaySettings
    let displayMutationDisabled: Bool
    let insertionDisabled: Bool
    let onChooseFont: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onResetZoom: () -> Void
    let onToggleWordWrap: () -> Void
    let onToggleStatus: () -> Void
    let onGoToLine: () -> Void
    let onInsertTimeAndDate: () -> Void

    var body: some View {
        Menu {
            Button("Choose Font", action: onChooseFont)
                .disabled(displayMutationDisabled)
                .accessibilityIdentifier("phonepad.editor.font")

            Menu("Zoom") {
                Button("Zoom In", action: onZoomIn)
                    .disabled(
                        displayMutationDisabled
                            || settings.zoomPercent >= 500
                    )
                    .accessibilityIdentifier("phonepad.editor.zoom-in")

                Button("Zoom Out", action: onZoomOut)
                    .disabled(
                        displayMutationDisabled
                            || settings.zoomPercent <= 80
                    )
                    .accessibilityIdentifier("phonepad.editor.zoom-out")

                Button("Reset Zoom", action: onResetZoom)
                    .disabled(displayMutationDisabled)
                    .accessibilityIdentifier("phonepad.editor.zoom-reset")
            }

            Button(
                settings.wordWrapEnabled
                    ? "Turn Word Wrap Off"
                    : "Turn Word Wrap On",
                action: onToggleWordWrap
            )
            .disabled(displayMutationDisabled)
            .accessibilityIdentifier("phonepad.editor.word-wrap")

            Button(
                settings.statusVisible
                    ? "Hide Status Bar"
                    : "Show Status Bar",
                action: onToggleStatus
            )
            .disabled(displayMutationDisabled)
            .accessibilityIdentifier("phonepad.editor.status-visibility")

            Divider()

            Button("Go to Line", action: onGoToLine)
                .accessibilityIdentifier("phonepad.editor.go-to-line")

            Button("Time/Date", action: onInsertTimeAndDate)
                .disabled(insertionDisabled)
                .accessibilityIdentifier("phonepad.editor.time-date")
        } label: {
            Label("Editor", systemImage: "textformat")
        }
        .accessibilityIdentifier("phonepad.editor.menu")
    }
}

struct PhonePadEditorStatusBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let position: EditorTextPosition
    let settings: PhonePadTabDisplaySettings
    let encoding: TextFileEncoding
    let lineEnding: TextLineEnding

    var body: some View {
        HStack(spacing: 12) {
            Text(positionText)
                .accessibilityIdentifier("phonepad.status.position")

            Spacer(minLength: 4)

            Text("\(settings.zoomPercent)%")
                .accessibilityIdentifier("phonepad.status.zoom")

            Text(fileFormatText)
                .accessibilityIdentifier("phonepad.status.file-format")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.status")
    }

    private var positionText: String {
        horizontalSizeClass == .compact
            ? "Ln \(position.line), Col \(position.column)"
            : "Line \(position.line), Column \(position.column)"
    }

    private var fileFormatText: String {
        let encodingText = statusEncoding(encoding)
        let lineEndingText = statusLineEnding(lineEnding)
        if horizontalSizeClass == .compact {
            return "\(encodingText) · \(lineEndingText)"
        }
        return "Encoding \(encodingText) · Line Ending \(lineEndingText)"
    }

    private func statusEncoding(_ encoding: TextFileEncoding) -> String {
        switch encoding {
        case .utf8:
            return "UTF-8"
        case .utf8WithBOM:
            return "UTF-8 BOM"
        case .utf16LittleEndianWithBOM:
            return "UTF-16 LE"
        case .utf16BigEndianWithBOM:
            return "UTF-16 BE"
        case .windows1252:
            return "Windows-1252"
        case .iso88591:
            return "ISO-8859-1"
        }
    }

    private func statusLineEnding(_ lineEnding: TextLineEnding) -> String {
        switch lineEnding {
        case .crlf:
            return "CRLF"
        case .lf:
            return "LF"
        case .cr:
            return "CR"
        }
    }
}

struct PhonePadGoToLineSheet: View {
    @Binding var lineValue: String
    let errorMessage: String?
    let onCancellation: () -> Void
    let onConfirmation: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Line", text: $lineValue)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("phonepad.go-to-line.input")

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("phonepad.go-to-line.error")
                }
            }
            .navigationTitle("Go to Line")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancellation)
                        .accessibilityIdentifier("phonepad.go-to-line.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go", action: onConfirmation)
                        .accessibilityIdentifier("phonepad.go-to-line.confirm")
                }
            }
        }
        .accessibilityIdentifier("phonepad.go-to-line.sheet")
    }
}
