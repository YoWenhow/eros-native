import SwiftUI
import UIKit
import ErosCore

@MainActor @Observable
final class SearchFilterSheetContext: Identifiable {
    let id = UUID()
    let scope: SessionScope
    var draft: SearchFilterDraft
    fileprivate var scrollPosition = ScrollPosition(edge: .top)
    @ObservationIgnored fileprivate var scrollMemory = SearchFilterScrollMemory()

    init(scope: SessionScope, draft: SearchFilterDraft) {
        self.scope = scope
        self.draft = draft
    }
}

struct SearchFilterSheet: View {
    @Bindable var context: SearchFilterSheetContext
    let preferencesMessage: String?
    let onApply: @MainActor (SearchFilterDraft, SessionScope) throws -> Void
    @State private var message: String?
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var showingError = false
    @FocusState private var pageField: PageField?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private enum PageField: Hashable { case minimum, maximum }

    var body: some View {
        NavigationStack {
            ScrollView {
                filterSections
                    .padding(.horizontal, SearchFilterLayout.cardMargin)
                    .padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollPosition($context.scrollPosition)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: SearchFilterScrollGeometry.self) { geometry in
                SearchFilterScrollGeometry(geometry)
            } action: { _, geometry in
                geometryChanged(geometry, userMoving: followsUser(scrollPhase))
            }
            .onScrollPhaseChange { old, new, change in
                scrollPhase = new
                if followsUser(new) || (new == .idle && followsUser(old)) {
                    geometryChanged(SearchFilterScrollGeometry(change.geometry), userMoving: true)
                }
            }
            .onChange(of: pageField) { _, field in
                if field != nil && scenePhase == .active { context.scrollMemory.releaseRestoration() }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    resumeScrollPosition()
                } else {
                    context.scrollMemory.suspend()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                context.scrollMemory.suspend()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                resumeScrollPosition()
            }
            .onDisappear { context.scrollMemory.suspend() }
            .alert("无法应用筛选", isPresented: $showingError) {
                Button("好", role: .cancel) {}
            } message: { Text(message ?? "请检查筛选条件。") }
            .navigationTitle("高级筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("应用") { apply() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { pageField = nil }
                }
            }
        }
    }

    private var filterSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let preferencesMessage {
                group { row(Text(preferencesMessage).foregroundStyle(.secondary)) }
            }
            if let message {
                group { row(Text(message).foregroundStyle(.red).accessibilityLabel("筛选错误：" + message)) }
            }
            group("类别", footer: "选中的类别会显示，取消选中的类别会排除。") {
                categoryTags
                    .padding(SearchFilterLayout.cardMargin - SearchFilterLayout.tagHitInset)
            }
            group("内容") {
                row(Toggle("仅含种子（torrent）", isOn: $context.draft.requireTorrent), divider: true)
                row(Toggle("包含已删除内容（Expunged）", isOn: $context.draft.includeExpunged), divider: true)
                row(Toggle("限制最低评分", isOn: $context.draft.ratingEnabled), divider: context.draft.ratingEnabled)
                if context.draft.ratingEnabled {
                    row(Picker("最低评分", selection: $context.draft.minimumRating) {
                        ForEach(SearchMinimumRating.allCases, id: \.self) { rating in
                            Label("\(rating.rawValue) 星", systemImage: "star").tag(rating)
                        }
                    }.pickerStyle(.menu))
                }
            }
            group("页数", footer: "留空表示不限，允许 0；最少页数不能大于最多页数。") {
                row(Toggle("限制页数", isOn: $context.draft.pageRangeEnabled), divider: context.draft.pageRangeEnabled)
                if context.draft.pageRangeEnabled {
                    row(TextField("最少页数（可留空）", text: $context.draft.minimumPageCount)
                        .keyboardType(.numberPad)
                        .focused($pageField, equals: .minimum), divider: true)
                    row(TextField("最多页数（可留空）", text: $context.draft.maximumPageCount)
                        .keyboardType(.numberPad)
                        .focused($pageField, equals: .maximum))
                }
            }
            group("忽略站点过滤", footer: "只影响本次搜索，不修改网站上的账号设置。") {
                row(Toggle("忽略语言过滤", isOn: $context.draft.disableLanguageFilter), divider: true)
                row(Toggle("忽略上传者过滤", isOn: $context.draft.disableUploaderFilter), divider: true)
                row(Toggle("忽略标签过滤", isOn: $context.draft.disableTagFilter))
            }
            group(footer: "重置只修改当前表单，点击“应用”后生效。每个排除类别和开关计 1 项，评分和页数范围各计 1 项。") {
                Button(role: .destructive) {
                    context.draft.reset()
                    message = nil
                } label: {
                    row(Text("重置筛选").foregroundStyle(.red))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func group<Content: View>(_ title: String? = nil, footer: String? = nil,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func row<Content: View>(_ content: Content, divider: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content.padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            if divider { Divider().padding(.leading, 16) }
        }
    }

    private var categoryTags: some View {
        let selection = context.draft.includedCategories
        return SearchCategoryTagGrid {
            ForEach(SearchCategory.filterOrder, id: \.self) { category in
                SearchCategoryTag(category: category, selected: selection.contains(category)) {
                    var categories = context.draft.includedCategories
                    if categories.remove(category) == nil { categories.insert(category) }
                    context.draft.includedCategories = categories
                }
            }
        }
    }

    private func followsUser(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    private func geometryChanged(_ geometry: SearchFilterScrollGeometry, userMoving: Bool) {
        guard scenePhase == .active, UIApplication.shared.applicationState == .active else { return }
        if let target = context.scrollMemory.observe(geometry, userMoving: userMoving, editing: pageField != nil) {
            scroll(to: target)
        }
    }

    private func resumeScrollPosition() {
        scrollPhase = .idle
        scroll(to: context.scrollMemory.resume())
    }

    private func scroll(to offset: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { context.scrollPosition.scrollTo(y: offset) }
    }

    private func apply() {
        message = nil; showingError = false
        do {
            try onApply(context.draft, context.scope)
            dismiss()
        } catch let error as SearchFilterDraftError {
            switch error {
            case .invalidMinimumPageCount: message = "最少页数请输入有效的非负整数。"
            case .invalidMaximumPageCount: message = "最多页数请输入有效的非负整数。"
            case .reversedPageRange: message = "最少页数不能大于最多页数。"
            case .unsupportedCategory, .unsupportedRating: message = "筛选值不受支持，请重置后重试。"
            }
        } catch AppError.scopeMismatch {
            message = "账号或站点已切换，请取消并重新打开筛选。"
        } catch { message = "筛选暂未保存，请重试。" }
        if message != nil { showingError = true }
    }
}

private struct SearchFilterScrollGeometry: Equatable {
    let offset: CGFloat
    let maximumOffset: CGFloat
    let hasLayout: Bool

    init(_ geometry: ScrollGeometry) {
        let insets = geometry.contentInsets
        maximumOffset = max(0, geometry.contentSize.height + insets.top + insets.bottom - geometry.containerSize.height)
        offset = min(max(0, geometry.contentOffset.y + insets.top), maximumOffset)
        hasLayout = geometry.containerSize.height > 0 && geometry.contentSize.height > 0
    }
}

/// A restore remains tied to the last user position until the next drag or
/// edit, so a second layout during activation cannot replace it with the top.
private struct SearchFilterScrollMemory {
    private var offset: CGFloat = 0
    private var active = false
    private var restoring = false

    mutating func resume() -> CGFloat {
        active = true
        restoring = true
        return offset
    }

    mutating func suspend() {
        active = false
        restoring = false
    }

    mutating func releaseRestoration() { restoring = false }

    mutating func observe(_ geometry: SearchFilterScrollGeometry, userMoving: Bool, editing: Bool) -> CGFloat? {
        guard active, geometry.hasLayout else { return nil }
        if userMoving || (editing && !restoring) {
            offset = geometry.offset
            restoring = false
            return nil
        }
        guard restoring else { return nil }
        let target = min(offset, geometry.maximumOffset)
        return abs(target - geometry.offset) > 0.5 ? target : nil
    }
}

private enum SearchFilterLayout {
    static let cardMargin: CGFloat = 20
    static let tagSpacing = cardMargin / 3
    // The transparent halves of each gap extend the buttons' tap area.
    static let tagHitInset = tagSpacing / 2
    static let tagAspectRatio: CGFloat = 14.0 / 5.0

    static func lineHeight(for tagHeight: CGFloat) -> CGFloat { tagHeight * 3 / 5 }
    static func fontSize(for lineHeight: CGFloat) -> CGFloat { lineHeight * 15 / 20 }
}

private struct SearchCategoryTag: View {
    let category: SearchCategory
    let selected: Bool
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let color = GalleryCategoryPalette.color(for: category.rawValue, scheme: scheme) ?? Color.secondary
        let fill = contrast == .increased ? Color.primary : color
        let foreground: Color = selected ? (contrast == .increased ? Color(uiColor: .systemBackground) : .white) : .primary
        Button(action: toggle) {
            shape.fill(selected ? fill : fill.opacity(0.12))
                .aspectRatio(SearchFilterLayout.tagAspectRatio, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        let lineHeight = SearchFilterLayout.lineHeight(for: geometry.size.height)
                        Text(category.label)
                            .font(.system(size: SearchFilterLayout.fontSize(for: lineHeight), weight: .semibold))
                            .foregroundStyle(foreground)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: geometry.size.width, height: lineHeight)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(SearchFilterLayout.tagHitInset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(category.label))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "显示" : "排除")
    }
}

private struct SearchCategoryTagGrid: Layout {
    private static let columns = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(0, proposed)
        } else {
            width = (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0) * CGFloat(Self.columns)
        }
        let cell = cellSize(width: width)
        let rows = (subviews.count + Self.columns - 1) / Self.columns
        return CGSize(width: width, height: cell.height * CGFloat(rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cellSize(width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index % Self.columns) * cell.width
            let y = bounds.minY + CGFloat(index / Self.columns) * cell.height
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: cell.width, height: cell.height))
        }
    }

    private func cellSize(width: CGFloat) -> CGSize {
        let cellWidth = max(0, width / CGFloat(Self.columns))
        let faceWidth = max(0, cellWidth - SearchFilterLayout.tagSpacing)
        return CGSize(width: cellWidth, height: faceWidth / SearchFilterLayout.tagAspectRatio + SearchFilterLayout.tagSpacing)
    }
}

private extension SearchCategory {
    static let filterOrder: [Self] = [
        .doujinshi, .manga, .artistCG, .gameCG,
        .western, .nonH, .imageSet, .cosplay,
        .asianPorn, .misc,
    ]

    var label: String {
        switch self {
        case .doujinshi: "同人志"
        case .manga: "漫画"
        case .artistCG: "画师CG"
        case .gameCG: "游戏CG"
        case .western: "西方"
        case .nonH: "非成人"
        case .imageSet: "图集"
        case .cosplay: "角色扮演"
        case .asianPorn: "亚洲色情"
        case .misc: "杂项"
        }
    }
}
