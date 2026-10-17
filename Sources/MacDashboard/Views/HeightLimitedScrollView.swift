import SwiftUI

/// Measure the natural content height, then scroll only when it exceeds the current display.
struct HeightLimitedScrollView<Content: View>: View {
    let width: CGFloat
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: min(contentHeight ?? maximumHeight, maximumHeight))
    }
}
