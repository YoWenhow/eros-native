import SwiftUI

struct AccessibleGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if opaque || contrast == .increased {
            content.background(Color(uiColor: .systemBackground), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.45), lineWidth: 1))
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}
extension View {
    func accessibleGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        modifier(AccessibleGlass(shape: shape, interactive: interactive))
    }
}
