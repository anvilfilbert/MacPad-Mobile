import PhonePadCore
import SwiftUI

struct PhonePadTabStrip: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledInteractionHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var scaledCapsuleHeight: CGFloat = 28
    @GestureState private var tabDragState: PhonePadTabDragState?
    @State private var tabFrames: [TabID: CGRect] = [:]

    let tabs: [PhonePadTab]
    let activeTabID: TabID
    let interactionDisabled: Bool
    let onSelect: (TabID) -> Void
    let onMove: (TabID, PhonePadCore.TabPlacement) -> Void
    let onMoveError: (Error) -> Void
    let onClose: (TabID) -> Void
    let onCloseOthers: (TabID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                        tabCell(
                            tab,
                            tabPosition: tabIndex + 1
                        )
                            .id(tab.id)
                            .offset(
                                x: tabDragState?.tabID == tab.id
                                    ? tabDragState?.translation.width ?? 0
                                    : 0
                            )
                            .zIndex(tabDragState?.tabID == tab.id ? 1 : 0)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(tabStripCoordinateSpaceName))
                            } action: { updatedFrame in
                                tabFrames = tabFrames.merging(
                                    [tab.id: updatedFrame],
                                    uniquingKeysWith: { _, latestFrame in
                                        latestFrame
                                    }
                                )
                            }
                    }
                }
                .padding(.horizontal, 8)
                .frame(minHeight: interactionHeight)
                .coordinateSpace(name: tabStripCoordinateSpaceName)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("phonepad.tab-strip")
            .onChange(of: activeTabID) { _, updatedTabID in
                if let animation = phonePadTabScrollAnimation(
                    accessibilityReduceMotion: accessibilityReduceMotion
                ) {
                    withAnimation(animation) {
                        proxy.scrollTo(updatedTabID, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(updatedTabID, anchor: .center)
                }
            }
        }
    }

    private func tabCell(
        _ tab: PhonePadTab,
        tabPosition: Int
    ) -> some View {
        let isActive = tab.id == activeTabID
        let activeCloseControl = phonePadActiveTabCloseControl(tabID: tab.id)
        let contextCloseControl = phonePadTabContextCloseControl(tabID: tab.id)
        let contextCloseOthersControl = phonePadTabContextCloseOtherTabsControl(
            tabID: tab.id
        )
        return HStack(spacing: 0) {
            Button {
                onSelect(tab.id)
            } label: {
                HStack(spacing: 6) {
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .accessibilityHidden(true)
                    }
                    Text(tab.document.title)
                        .lineLimit(1)
                    if tab.document.isUnsaved {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                }
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 10)
                .frame(
                    minWidth: 44,
                    maxWidth: 220,
                    minHeight: interactionHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(tabIdentifier(prefix: "phonepad.tab.select", tabID: tab.id))
            .accessibilityLabel(tab.document.title)
            .accessibilityValue(recoveryAccessibilityValue(tab.document.recoveryState))
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .contextMenu {
                Button(role: .destructive) {
                    performPhonePadTabCloseAction(
                        contextCloseControl.action,
                        onClose: onClose,
                        onCloseOthers: onCloseOthers
                    )
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .accessibilityIdentifier(
                    contextCloseControl.accessibilityIdentifier
                )

                Button(role: .destructive) {
                    performPhonePadTabCloseAction(
                        contextCloseOthersControl.action,
                        onClose: onClose,
                        onCloseOthers: onCloseOthers
                    )
                } label: {
                    Label(
                        "Close Other Tabs",
                        systemImage: "rectangle.stack.badge.minus"
                    )
                }
                .disabled(tabs.count == 1)
                .accessibilityIdentifier(
                    contextCloseOthersControl.accessibilityIdentifier
                )
            }

            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .frame(width: 44)
                .frame(minHeight: interactionHeight)
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
                .gesture(tabReorderGesture(tabID: tab.id))
                .allowsHitTesting(!interactionDisabled)
                .accessibilityElement()
                .accessibilityIdentifier(
                    tabIdentifier(prefix: "phonepad.tab.drag", tabID: tab.id)
                )
                .accessibilityLabel("Reorder Tab")
                .accessibilityValue(
                    phonePadTabAccessibilityValue(
                        title: tab.document.title,
                        tabPosition: tabPosition,
                        tabCount: tabs.count
                    )
                )
                .accessibilityHint("Swipe up or down to move this Tab earlier or later.")
                .accessibilityAdjustableAction { direction in
                    moveTabWithAccessibility(
                        tabID: tab.id,
                        direction: direction
                    )
                }

            if isActive {
                Button {
                    performPhonePadTabCloseAction(
                        activeCloseControl.action,
                        onClose: onClose,
                        onCloseOthers: onCloseOthers
                    )
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44)
                        .frame(minHeight: interactionHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    activeCloseControl.accessibilityIdentifier
                )
                .accessibilityLabel("Close Tab")
                .accessibilityValue(tab.document.title)
            }
        }
        .frame(minHeight: interactionHeight)
        .background(
            Capsule()
                .fill(isActive ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.10))
                .overlay {
                    if isActive {
                        Capsule()
                            .strokeBorder(.primary, lineWidth: 1)
                    }
                }
                .frame(height: capsuleHeight)
        )
        .disabled(interactionDisabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(tabIdentifier(prefix: "phonepad.tab.item", tabID: tab.id))
        .accessibilityLabel(tab.document.title)
        .accessibilityValue(recoveryAccessibilityValue(tab.document.recoveryState))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func tabReorderGesture(tabID: TabID) -> some Gesture {
        DragGesture(
            minimumDistance: 8,
            coordinateSpace: .named(tabStripCoordinateSpaceName)
        )
        .updating($tabDragState) { value, state, _ in
            state = PhonePadTabDragState(
                tabID: tabID,
                translation: value.translation
            )
        }
        .onEnded { value in
            do {
                let placement = try phonePadTabPlacement(
                    draggedTabID: tabID,
                    dropX: value.location.x,
                    orderedTabIDs: tabs.map(\.id),
                    tabFrames: tabFrames
                )
                onMove(tabID, placement)
            } catch {
                onMoveError(error)
            }
        }
    }

    private func moveTabWithAccessibility(
        tabID: TabID,
        direction: AccessibilityAdjustmentDirection
    ) {
        let moveDirection: PhonePadTabMoveDirection
        switch direction {
        case .decrement:
            moveDirection = .earlier
        case .increment:
            moveDirection = .later
        @unknown default:
            onMoveError(PhonePadTabPlacementError.unsupportedAccessibilityAdjustment)
            return
        }
        do {
            if let placement = try phonePadAdjacentTabPlacement(
                tabID: tabID,
                direction: moveDirection,
                orderedTabIDs: tabs.map(\.id)
            ) {
                onMove(tabID, placement)
            }
        } catch {
            onMoveError(error)
        }
    }

    private func tabIdentifier(prefix: String, tabID: TabID) -> String {
        "\(prefix).\(tabID.rawValue.uuidString.lowercased())"
    }

    private func recoveryAccessibilityValue(
        _ recoveryState: DocumentRecoveryState
    ) -> String {
        switch recoveryState {
        case .clean:
            return "Clean"
        case .checkpointPending:
            return "Protecting edits"
        case .recoveryUnavailable:
            return "Recovery unavailable"
        case .protectedUnsaved:
            return "Edits protected"
        }
    }

    private var interactionHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? max(44, scaledInteractionHeight)
            : 44
    }

    private var capsuleHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? max(28, scaledCapsuleHeight)
            : 28
    }
}

enum PhonePadTabCloseAction: Equatable, Sendable {
    case close(TabID)
    case closeOthers(TabID)
}

struct PhonePadTabCloseControl: Equatable, Sendable {
    let action: PhonePadTabCloseAction
    let accessibilityIdentifier: String
}

func performPhonePadTabCloseAction(
    _ action: PhonePadTabCloseAction,
    onClose: (TabID) -> Void,
    onCloseOthers: (TabID) -> Void
) {
    switch action {
    case let .close(tabID):
        onClose(tabID)
    case let .closeOthers(tabID):
        onCloseOthers(tabID)
    }
}

func phonePadActiveTabCloseControl(tabID: TabID) -> PhonePadTabCloseControl {
    PhonePadTabCloseControl(
        action: .close(tabID),
        accessibilityIdentifier: tabCloseIdentifier(
            prefix: "phonepad.tab.close",
            tabID: tabID
        )
    )
}

func phonePadTabContextCloseControl(tabID: TabID) -> PhonePadTabCloseControl {
    PhonePadTabCloseControl(
        action: .close(tabID),
        accessibilityIdentifier: tabCloseIdentifier(
            prefix: "phonepad.tab.menu.close",
            tabID: tabID
        )
    )
}

func phonePadTabContextCloseOtherTabsControl(
    tabID: TabID
) -> PhonePadTabCloseControl {
    PhonePadTabCloseControl(
        action: .closeOthers(tabID),
        accessibilityIdentifier: tabCloseIdentifier(
            prefix: "phonepad.tab.close-others",
            tabID: tabID
        )
    )
}

private func tabCloseIdentifier(prefix: String, tabID: TabID) -> String {
    "\(prefix).\(tabID.rawValue.uuidString.lowercased())"
}

func phonePadTabAccessibilityValue(
    title: String,
    tabPosition: Int,
    tabCount: Int
) -> String {
    "\(title), Tab \(tabPosition) of \(tabCount)"
}

private struct PhonePadTabDragState: Equatable {
    let tabID: TabID
    let translation: CGSize
}

enum PhonePadTabMoveDirection: Equatable {
    case earlier
    case later
}

enum PhonePadTabPlacementError: Error, Equatable {
    case draggedTabMissing(TabID)
    case tabFrameMissing(TabID)
    case unsupportedAccessibilityAdjustment
}

extension PhonePadTabPlacementError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .draggedTabMissing(tabID):
            return "Dragged Tab \(tabID.rawValue.uuidString) no longer exists. Refresh the Tab Strip and retry."
        case let .tabFrameMissing(tabID):
            return "Tab \(tabID.rawValue.uuidString) has no current layout position. Wait for the Tab Strip to finish laying out and retry."
        case .unsupportedAccessibilityAdjustment:
            return "The requested accessibility Tab movement is unsupported. Swipe up or down on the Reorder Tab control and retry."
        }
    }
}

func phonePadAdjacentTabPlacement(
    tabID: TabID,
    direction: PhonePadTabMoveDirection,
    orderedTabIDs: [TabID]
) throws(PhonePadTabPlacementError) -> PhonePadCore.TabPlacement? {
    guard let tabIndex = orderedTabIDs.firstIndex(of: tabID) else {
        throw .draggedTabMissing(tabID)
    }
    switch direction {
    case .earlier:
        guard tabIndex > orderedTabIDs.startIndex else {
            return nil
        }
        return .before(orderedTabIDs[tabIndex - 1])
    case .later:
        let nextIndex = tabIndex + 1
        guard nextIndex < orderedTabIDs.endIndex else {
            return nil
        }
        let followingIndex = nextIndex + 1
        guard followingIndex < orderedTabIDs.endIndex else {
            return .end
        }
        return .before(orderedTabIDs[followingIndex])
    }
}

func phonePadTabPlacement(
    draggedTabID: TabID,
    dropX: CGFloat,
    orderedTabIDs: [TabID],
    tabFrames: [TabID: CGRect]
) throws(PhonePadTabPlacementError) -> PhonePadCore.TabPlacement {
    guard orderedTabIDs.contains(draggedTabID) else {
        throw .draggedTabMissing(draggedTabID)
    }
    for tabID in orderedTabIDs where tabID != draggedTabID {
        guard let frame = tabFrames[tabID] else {
            throw .tabFrameMissing(tabID)
        }
        if dropX < frame.midX {
            return .before(tabID)
        }
    }
    return .end
}

private let tabStripCoordinateSpaceName = "phonepad.tab-strip.coordinate-space"

func phonePadTabScrollAnimation(
    accessibilityReduceMotion: Bool
) -> Animation? {
    guard !accessibilityReduceMotion else {
        return nil
    }
    return .easeInOut(duration: 0.2)
}
