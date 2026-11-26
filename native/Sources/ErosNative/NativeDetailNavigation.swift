import SwiftUI
import ErosCore

struct DetailTransitionSource: Hashable {
    enum Item: Hashable {
        case gallery(GalleryKey)
        case download(UUID)
    }

    let item: Item
    let namespace: Namespace.ID

    func transition(reduceMotion: Bool) -> AnyNavigationTransition {
        if reduceMotion { return AnyNavigationTransition(.crossFade) }
        return AnyNavigationTransition(.zoom(sourceID: item, in: namespace))
    }
}

extension View {
    func detailTransitionSource(_ source: DetailTransitionSource) -> some View {
        modifier(DetailTransitionSourceModifier(source: source))
    }
}

struct GalleryDetailRoute: Hashable {
    let id = UUID()
    let reference: GalleryReference
    let scope: SessionScope
    let source: DetailTransitionSource?
    let summary: GallerySummary?
    let download: DownloadLibraryItem?
    let waitsForInitialJapaneseTitle: Bool
    let prepareNavigation: (@MainActor @Sendable () -> Void)?

    init(reference: GalleryReference, scope: SessionScope, source: DetailTransitionSource? = nil,
         summary: GallerySummary? = nil, download: DownloadLibraryItem? = nil,
         waitsForInitialJapaneseTitle: Bool = false,
         prepareNavigation: (@MainActor @Sendable () -> Void)? = nil) {
        self.reference = reference
        self.scope = scope
        self.source = source
        self.summary = download?.summary ?? summary
        self.download = download
        self.waitsForInitialJapaneseTitle = waitsForInitialJapaneseTitle
        self.prepareNavigation = prepareNavigation
    }

    // The list snapshot is initial display data for this push. It cannot change path identity.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct DownloadDetailRoute: Hashable {
    let id = UUID()
    let jobID: UUID
    let scope: SessionScope
    let source: DetailTransitionSource
    let item: DownloadLibraryItem?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct DetailTransitionSourceModifier: ViewModifier {
    let source: DetailTransitionSource
    func body(content: Content) -> some View {
        content.matchedTransitionSource(id: source.item, in: source.namespace)
    }
}
