import SwiftUI
import ErosCore
import ErosServices

extension EnvironmentValues {
    @Entry var galleryTitleLookup: GalleryTitleLookup? = nil
}

struct GalleryTitleView<Content: View>: View {
    let summary: GallerySummary
    let scope: SessionScope
    @ViewBuilder var content: (String, GallerySourceTitles?) -> Content

    init(summary: GallerySummary, scope: SessionScope, @ViewBuilder content: @escaping (String) -> Content) {
        self.init(summary: summary, scope: scope, titleAndSource: { title, _ in content(title) })
    }

    init(summary: GallerySummary, scope: SessionScope,
         @ViewBuilder titleAndSource: @escaping (String, GallerySourceTitles?) -> Content) {
        self.summary = summary
        self.scope = scope
        content = titleAndSource
    }

    @ObservedObject private var preferences = PreferencesStore.shared
    @Environment(\.galleryTitleLookup) private var lookup
    @State private var loaded: (request: Request, titles: GallerySourceTitles)?

    private struct Request: Hashable {
        let lookup: ObjectIdentifier
        let scope: SessionScope
        let reference: GalleryReference
    }

    var body: some View {
        let request = lookup.map { Request(lookup: ObjectIdentifier($0), scope: scope, reference: summary.reference) }
        let sourceTitles = summary.sourceTitles ?? (loaded?.request == request ? loaded?.titles : nil)
        let title = DetailTitlePresentation(sourceTitles: sourceTitles, fallbackTitle: summary.title,
            preferred: preferences.value.galleryTitleStyle, showsSubtitle: false).primary

        content(title, sourceTitles)
            .task(id: summary.sourceTitles == nil ? request : nil) {
                guard summary.sourceTitles == nil, let request, let lookup, loaded?.request != request,
                      let titles = await lookup.titles(for: request.reference, scope: request.scope),
                      !Task.isCancelled else { return }
                loaded = (request, titles)
            }
    }
}
