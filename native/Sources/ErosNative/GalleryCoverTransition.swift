import SwiftUI

/// Register only the cover footprint. The system owns the navigation transition,
/// including interactive reversal, cancellation, and restoring the source view.
struct GalleryCoverSource<Content: View>: View {
    let source: DetailTransitionSource
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().matchedTransitionSource(id: source.item, in: source.namespace)
    }
}

struct GalleryRouteTransition: ViewModifier {
    let route: OnlineRoute
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content.navigationTransition(route.transitionSource?.transition(reduceMotion: reduceMotion)
            ?? AnyNavigationTransition(.automatic))
    }
}
