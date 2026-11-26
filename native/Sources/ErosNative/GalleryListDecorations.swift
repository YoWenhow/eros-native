import SwiftUI
import ErosCore
import ErosServices

enum GalleryCategoryPalette {
    // Exact light/dark RGB values from lib/const/theme_colors.dart: ThemeColors.catColor.
    private static let colors: [String: (UInt32, UInt32)] = [
        "Doujinshi": (0xF44336,0x913127), "Manga": (0xFF9800,0xCE7138),
        "Artist CG": (0xFBC02D,0xCA913A), "Game CG": (0x4CAF50,0x739170),
        "Western": (0x8BC34A,0xA99E68), "Non-H": (0x2196F3,0x70A8CB),
        "Image Set": (0x3F51B5,0x3B5D9D), "Cosplay": (0x9C27B0,0x62399C),
        "Asian Porn": (0x9575CD,0x963C7F), "Misc": (0xF06292,0xBC5B7B),
        "Private": (0x5A5A5D,0x464649)
    ]
    static func color(for category: String, scheme: ColorScheme) -> Color? {
        guard let pair = colors[category] else { return nil }
        let rgb = scheme == .dark ? pair.1 : pair.0
        return Color(red: Double((rgb >> 16) & 255)/255, green: Double((rgb >> 8) & 255)/255, blue: Double(rgb & 255)/255)
    }
}

struct GalleryCategoryBadge: View {
    let category: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .caption2) private var fontSize: CGFloat = 10

    var body: some View {
        let color = GalleryCategoryPalette.color(for: category, scheme: scheme)
        TranslatedCategoryText(category: category).font(.system(size: fontSize))
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(contrast == .increased || color == nil ? Color.primary : .white)
            .padding(.horizontal, 4).padding(.vertical, 2.5)
            .background(contrast == .increased ? Color(uiColor: .systemBackground) : (color ?? Color(uiColor: .systemBackground)),
                in: RoundedRectangle(cornerRadius: 4))
            .overlay { if contrast == .increased { RoundedRectangle(cornerRadius: 4).stroke(Color.primary, lineWidth: 1) } }
    }
}

struct GalleryStars: View {
    let rating: Double?
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5) { index in
                Image(systemName: "star.fill").foregroundStyle(Color(uiColor: .systemGray3))
                    .overlay(alignment: .leading) {
                        Image(systemName: "star.fill").foregroundStyle(Color(red: 1, green: 150.0/255, blue: 46.0/255))
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: 12 * min(1, max(0, (rating ?? 0) - Double(index))))
                            }
                    }
                    .frame(width: 12, height: 12)
            }
        }.font(.system(size: 12)).accessibilityElement(children: .ignore)
            .accessibilityLabel(rating.map { String(format: "评分 %.1f / 5", $0) } ?? "暂无评分")
    }
}

struct CompactListTags: View {
    let groups: [TagGroup]
    @ObservedObject private var preferences = PreferencesStore.shared
    @ObservedObject private var catalog = TranslationSettingsModel.shared
    @State private var snapshot: TranslationReadSnapshot?
    @ScaledMetric(relativeTo: .caption2) private var fontSize: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var tagRowHeight: CGFloat = 14
    private struct LookupID: Hashable { let keys: [TagTranslationKey]; let version: String? }
    private var keys: [TagTranslationKey] {
        groups.flatMap { group in group.tags.compactMap { try? TagTranslationKey(namespace: group.namespace ?? "", original: $0) } }
    }
    private var lookupID: LookupID { LookupID(keys: Array(keys.prefix(512)), version: catalog.installed?.hash) }
    private var labels: [String] {
        groups.flatMap { group in group.tags.map { original in
            let key = try? TagTranslationKey(namespace: group.namespace ?? "", original: original)
            return TagTranslationPresentation.text(original: original, translated: key.flatMap { snapshot?.entries[$0]?.localizedText }, mode: preferences.value.tagTranslationDisplay)
        } }
    }
    var body: some View {
        ThreeRowTagLayout {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(verbatim: label).font(.system(size: fontSize)).lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }
        }.frame(height: tagRowHeight * 3 + 6, alignment: .topLeading)
            .clipped().frame(maxWidth: .infinity, alignment: .leading)
            .task(id: lookupID) {
                let value = await catalog.lookup(lookupID.keys)
                if !Task.isCancelled { snapshot = value }
            }
    }
}

/// Measures actual SwiftUI children on the first layout pass; no zero-width state bootstrap.
private struct ThreeRowTagLayout: Layout {
    struct Cache {
        var sizes: [CGSize]
        var width: CGFloat?
        var boxes: [(Int, CGRect)] = []
        var height: CGFloat = 0
    }
    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }
    private func plan(_ width: CGFloat, cache: inout Cache) {
        guard cache.width != width else { return }
        cache.width = width
        cache.boxes = []
        cache.height = 0
        guard width > 0 else { return }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var row = 0
        for (index, size) in cache.sizes.enumerated() {
            let w = min(width, size.width)
            if x > 0 && x + w > width {
                row += 1
                if row == 3 { break }
                y += rowHeight + 3
                x = 0
                rowHeight = 0
            }
            cache.boxes.append((index, CGRect(x: x, y: y, width: w, height: size.height)))
            x += w + 4
            rowHeight = max(rowHeight, size.height)
        }
        cache.height = cache.boxes.isEmpty ? 0 : y + rowHeight
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 240
        plan(width, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        plan(bounds.width, cache: &cache)
        for (index, rect) in cache.boxes {
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: rect.width, height: rect.height))
        }
        for index in cache.boxes.count..<subviews.count {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 1000), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: 0))
        }
    }
}

struct GalleryListLoadingStatus: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().accessibilityHidden(true)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

struct GalleryCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct OpenGalleryKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (GalleryDetailRoute) -> Void = { _ in }
}
extension EnvironmentValues {
    var openGallery: @MainActor @Sendable (GalleryDetailRoute) -> Void {
        get { self[OpenGalleryKey.self] }
        set { self[OpenGalleryKey.self] = newValue }
    }
}
