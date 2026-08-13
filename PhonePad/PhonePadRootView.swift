import PhonePadCore
import SwiftUI

struct PhonePadRootView: View {
    @ObservedObject private var model: PhonePadAppModel

    init(model: PhonePadAppModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            PhonePadTextEditor(
                text: Binding(
                    get: { model.activeText },
                    set: { model.editActiveDocument(text: $0) }
                )
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.root")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let recoveryError = model.recoveryError {
                Text(recoveryError)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red)
                    .accessibilityIdentifier("phonepad.recovery-error")
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.state.tabs, id: \.id) { tab in
                    Text(tab.document.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("phonepad.tab.item")
                        .accessibilityLabel(tab.document.title)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("phonepad.tab-strip")
    }
}
