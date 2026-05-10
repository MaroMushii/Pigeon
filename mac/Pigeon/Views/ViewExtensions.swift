import SwiftUI

extension View {
    /// Applies Liquid Glass on macOS 26+; falls back to regularMaterial on earlier OS.
    @ViewBuilder
    func glassEffectIfAvailable<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Applies `.scrollEdgeEffectStyle(.soft, for: .top)` on macOS 26+; no-op on earlier OS.
    @ViewBuilder
    func softTopScrollEdgeEffect() -> some View {
        if #available(macOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// Applies `.scrollEdgeEffectStyle(.soft, for: .horizontal)` on macOS 26+; no-op on earlier OS.
    @ViewBuilder
    func softHorizontalScrollEdgeEffect() -> some View {
        if #available(macOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .horizontal)
        } else {
            self
        }
    }
}
