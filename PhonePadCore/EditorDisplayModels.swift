import Foundation

public enum PhonePadFontFamily: Equatable, Sendable {
    case monospacedSystem
    case named(postScriptName: String)
}

public struct PhonePadTabDisplaySettings: Equatable, Sendable {
    public static let initial = PhonePadTabDisplaySettings(
        fontFamily: .monospacedSystem,
        zoomPercent: 100,
        wordWrapEnabled: true,
        statusVisible: true
    )

    public let fontFamily: PhonePadFontFamily
    public let zoomPercent: Int
    public let wordWrapEnabled: Bool
    public let statusVisible: Bool

    init(
        fontFamily: PhonePadFontFamily,
        zoomPercent: Int,
        wordWrapEnabled: Bool,
        statusVisible: Bool
    ) {
        self.fontFamily = fontFamily
        self.zoomPercent = zoomPercent
        self.wordWrapEnabled = wordWrapEnabled
        self.statusVisible = statusVisible
    }
}

public struct EditorTextPosition: Equatable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public enum PhonePadEditorDisplayError: Error, Equatable, Sendable {
    case invalidFontPostScriptName
    case invalidZoomPercent(Int)
    case invalidDynamicTypeBasePointSize(Double)
    case lineOutOfBounds(requested: Int, available: Int)
    case textOffsetOutOfBounds(Int)
    case textOffsetSplitsCharacter(Int)
}

extension PhonePadEditorDisplayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFontPostScriptName:
            return "Selected font is unavailable. Choose another font and retry."
        case let .invalidZoomPercent(zoomPercent):
            return "Zoom \(zoomPercent)% is invalid. Choose 80% through 500% in 10% steps."
        case .invalidDynamicTypeBasePointSize:
            return "Dynamic Type produced an invalid editor font size. Change Text Size and retry."
        case let .lineOutOfBounds(requested, available):
            return "Line \(requested) is outside this Document. Enter a line from 1 through \(available)."
        case let .textOffsetOutOfBounds(offset):
            return "Editor selection offset \(offset) is outside the current Document. Place the insertion point in the Document and retry."
        case let .textOffsetSplitsCharacter(offset):
            return "Editor selection offset \(offset) splits a text character. Move the insertion point and retry."
        }
    }
}

public func setActiveTabFontFamily(
    state: PhonePadState,
    fontFamily: PhonePadFontFamily
) throws -> PhonePadState {
    if case let .named(postScriptName) = fontFamily,
       postScriptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw PhonePadEditorDisplayError.invalidFontPostScriptName
    }
    let current = state.activeTab.displaySettings
    return replacingActiveTabDisplaySettings(
        state: state,
        displaySettings: PhonePadTabDisplaySettings(
            fontFamily: fontFamily,
            zoomPercent: current.zoomPercent,
            wordWrapEnabled: current.wordWrapEnabled,
            statusVisible: current.statusVisible
        )
    )
}

public func setActiveTabZoomPercent(
    state: PhonePadState,
    zoomPercent: Int
) throws -> PhonePadState {
    try validateZoomPercent(zoomPercent)
    let current = state.activeTab.displaySettings
    return replacingActiveTabDisplaySettings(
        state: state,
        displaySettings: PhonePadTabDisplaySettings(
            fontFamily: current.fontFamily,
            zoomPercent: zoomPercent,
            wordWrapEnabled: current.wordWrapEnabled,
            statusVisible: current.statusVisible
        )
    )
}

public func setActiveTabWordWrapEnabled(
    state: PhonePadState,
    isEnabled: Bool
) throws -> PhonePadState {
    let current = state.activeTab.displaySettings
    return replacingActiveTabDisplaySettings(
        state: state,
        displaySettings: PhonePadTabDisplaySettings(
            fontFamily: current.fontFamily,
            zoomPercent: current.zoomPercent,
            wordWrapEnabled: isEnabled,
            statusVisible: current.statusVisible
        )
    )
}

public func setActiveTabStatusVisible(
    state: PhonePadState,
    isVisible: Bool
) throws -> PhonePadState {
    let current = state.activeTab.displaySettings
    return replacingActiveTabDisplaySettings(
        state: state,
        displaySettings: PhonePadTabDisplaySettings(
            fontFamily: current.fontFamily,
            zoomPercent: current.zoomPercent,
            wordWrapEnabled: current.wordWrapEnabled,
            statusVisible: isVisible
        )
    )
}

public func renderedEditorPointSize(
    dynamicTypeBasePointSize: Double,
    zoomPercent: Int
) throws -> Double {
    guard dynamicTypeBasePointSize.isFinite,
          dynamicTypeBasePointSize > 0 else {
        throw PhonePadEditorDisplayError.invalidDynamicTypeBasePointSize(
            dynamicTypeBasePointSize
        )
    }
    try validateZoomPercent(zoomPercent)
    let zoomedPointSize = dynamicTypeBasePointSize
        * Double(zoomPercent)
        / 100
    return min(96, max(11, zoomedPointSize))
}

public func editorTextPosition(
    text: String,
    utf16Offset: Int
) throws -> EditorTextPosition {
    guard utf16Offset >= 0,
          utf16Offset <= text.utf16.count else {
        throw PhonePadEditorDisplayError.textOffsetOutOfBounds(utf16Offset)
    }
    let utf16Index = text.utf16.index(
        text.utf16.startIndex,
        offsetBy: utf16Offset
    )
    guard let textIndex = String.Index(utf16Index, within: text) else {
        throw PhonePadEditorDisplayError.textOffsetSplitsCharacter(
            utf16Offset
        )
    }

    var line = 1
    var column = 1
    for character in text[..<textIndex] {
        switch character {
        case "\n", "\r", "\r\n":
            line += 1
            column = 1
        default:
            column += 1
        }
    }
    return EditorTextPosition(line: line, column: column)
}

public func editorUTF16OffsetForLine(
    text: String,
    oneBasedLine: Int
) throws -> Int {
    let utf16 = text.utf16
    var index = utf16.startIndex
    var utf16Offset = 0
    var currentLine = 1
    var requestedOffset: Int? = oneBasedLine == 1 ? 0 : nil

    while index < utf16.endIndex {
        let codeUnit = utf16[index]
        index = utf16.index(after: index)
        utf16Offset += 1

        if codeUnit == 0x0D,
           index < utf16.endIndex,
           utf16[index] == 0x0A {
            index = utf16.index(after: index)
            utf16Offset += 1
        } else if codeUnit != 0x0A,
                  codeUnit != 0x0D {
            continue
        }

        currentLine += 1
        if currentLine == oneBasedLine {
            requestedOffset = utf16Offset
        }
    }

    guard let requestedOffset else {
        throw PhonePadEditorDisplayError.lineOutOfBounds(
            requested: oneBasedLine,
            available: currentLine
        )
    }
    return requestedOffset
}

private func validateZoomPercent(_ zoomPercent: Int) throws {
    guard (80 ... 500).contains(zoomPercent),
          zoomPercent.isMultiple(of: 10) else {
        throw PhonePadEditorDisplayError.invalidZoomPercent(zoomPercent)
    }
}

private func replacingActiveTabDisplaySettings(
    state: PhonePadState,
    displaySettings: PhonePadTabDisplaySettings
) -> PhonePadState {
    let activeTab = state.activeTab
    let updatedTab = PhonePadTab(
        id: activeTab.id,
        document: activeTab.document,
        displaySettings: displaySettings
    )
    let tabs = state.tabs.map { tab in
        tab.id == activeTab.id ? updatedTab : tab
    }
    return PhonePadState(tabs: tabs, activeTabID: activeTab.id)
}
