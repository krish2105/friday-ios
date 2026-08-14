import SwiftUI

// Surfaces, split by layer.
//
// Apple's Liquid Glass guidance is explicit: glass belongs to the control layer
// floating above content, never to content itself. Glass cannot sample other
// glass, so stacking it also samples badly. Hence two distinct surfaces here —
// `glassSurface` for things that float, `contentSurface` for things that don't.

extension View {
    /// Floating control surface — real Liquid Glass.
    ///
    /// Use only for controls that sit above content. Group several of these in
    /// a `GlassEffectContainer` so they share a sampling region.
    func glassSurface(cornerRadius: CGFloat = 26) -> some View {
        glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// Content panel — deliberately not glass.
    ///
    /// A solid, faintly raised surface with a hairline edge. Reads as part of
    /// the page rather than floating above it.
    func contentSurface(cornerRadius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(FridayTheme.groundRaised.opacity(0.92)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 16)
    }
}
