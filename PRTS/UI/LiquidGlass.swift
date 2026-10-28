/// Liquid Glass surfaces for iOS 26+, with the previous material look on iOS 17–25.

import SwiftUI

extension View {
    /// Glass behind the receiver. `interactive` adds the system press response; it does not add a gesture.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// Dark glass for dense technical text; keeps the old 65% black panel contrast on older systems.
    @ViewBuilder
    func readableGlassPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(iOS 26, *) {
            glassEffect(Glass.regular.tint(.black.opacity(0.55)), in: shape)
        } else {
            background(.black.opacity(0.65), in: shape)
        }
    }
}

extension View {
    /// System glass button on iOS 26+; the previous bordered styles on older systems.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Groups neighbouring glass so the shapes blend as one layer on iOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
