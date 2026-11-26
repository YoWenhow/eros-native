import Foundation
import Observation
import ErosCore

@MainActor @Observable public final class RemoteFavoritesViewModel {
    public private(set) var items: [GallerySummary] = []
    public private(set) var lastPageKeys: Set<GalleryKey> = []
    public private(set) var pagesLoaded = 0
    public var queryID: UUID { context.queryID }
    public private(set) var groups: [FavoriteGroup] = []
    public private(set) var loadingGroups = false
    public private(set) var titleQuery: String?
    public private(set) var loading = false
    public private(set) var error: AppError?
    public private(set) var next: PageCursor?
    public private(set) var groupID: String?
    public let scope: SessionScope
    private let repository: any RemoteFavoritesRepository
    private var context: RequestContext
    private var appearanceContext: RequestContext?
    private var consumed: Set<String> = []
    public init(repository: any RemoteFavoritesRepository, scope: SessionScope) {
        self.repository = repository; self.scope = scope; context = RequestContext(scope: scope, queryID: UUID())
    }
    public func loadGroupsIfNeeded() async {
        guard !Task.isCancelled, groups.isEmpty, !loadingGroups else { return }
        loadingGroups = true
        defer { loadingGroups = false }
        guard let groups = try? await repository.groups(scope: scope),
              !Task.isCancelled, self.groups.isEmpty else { return }
        self.groups = groups
    }

    public func loadOnAppearance(group: String? = nil, titleQuery: String? = nil, refreshAfterChild: Bool = false) async {
        let selectionChanged = groupID != group || self.titleQuery != titleQuery
        guard refreshAfterChild || selectionChanged || pagesLoaded == 0 else { return }
        // A different selection takes over immediately. Reappearing with the
        // same selection leaves a user-requested refresh or pagination in control.
        guard selectionChanged || !loading || appearanceContext == context else { return }
        await loadFirstPage(group: group, titleQuery: titleQuery, onAppearance: true)
    }

    public func refresh(group: String? = nil, titleQuery: String? = nil) async {
        await loadFirstPage(group: group, titleQuery: titleQuery, onAppearance: false)
    }

    private func loadFirstPage(group: String?, titleQuery: String?, onAppearance: Bool) async {
        guard !Task.isCancelled else { return }
        let ticket = RequestContext(scope: scope, queryID: UUID())
        context = ticket
        appearanceContext = onAppearance ? ticket : nil
        groupID = group
        self.titleQuery = titleQuery
        items = []; lastPageKeys = []; pagesLoaded = 0; next = nil; consumed = []; loading = true; error = nil
        defer {
            if context == ticket {
                loading = false
                appearanceContext = nil
            }
        }
        do {
            if groups.isEmpty || !onAppearance {
                let groups = try await repository.groups(scope: scope)
                try Task.checkCancellation()
                guard context == ticket else { return }
                self.groups = groups
            }
            let page = try await repository.list(request: FavoritesListRequest(groupID: group, titleQuery: titleQuery, context: ticket))
            try page.validate(current: ticket); try Task.checkCancellation()
            guard context == ticket else { return }
            for item in page.items { try item.reference.validate(scope: scope) }
            append(page.items); lastPageKeys = Set(page.items.map(\.reference.key)); pagesLoaded = 1; next = page.next
        } catch is CancellationError {
        } catch AppError.cancelled {
        } catch {
            if context == ticket, !Task.isCancelled { self.error = error as? AppError ?? .parseMismatch }
        }
    }
    public var retryNeedsRefresh: Bool { next == nil }
    public func retry() async {
        guard !loading else { return }
        if retryNeedsRefresh { await refresh(group: groupID, titleQuery: titleQuery) }
        else { await more() }
    }
    public func loadMoreIfCurrent(queryID: UUID, afterPage page: Int) async {
        guard self.queryID == queryID, pagesLoaded == page, error == nil else { return }
        await more()
    }

    public func more() async {
        guard !Task.isCancelled, !loading, let cursor = next else { return }
        guard !consumed.contains(cursor.opaque.value) else { next = nil; error = .parseMismatch; return }
        let ticket = context; loading = true; error = nil
        defer { if context == ticket { loading = false } }
        do {
            let page = try await repository.list(request: FavoritesListRequest(groupID: groupID, titleQuery: titleQuery, context: ticket, cursor: cursor))
            try page.validate(current: ticket); try Task.checkCancellation()
            guard context == ticket else { return }
            for item in page.items { try item.reference.validate(scope: scope) }
            consumed.insert(cursor.opaque.value); append(page.items); lastPageKeys = Set(page.items.map(\.reference.key)); pagesLoaded += 1; next = page.next
            if let next, consumed.contains(next.opaque.value) { self.next = nil; error = .parseMismatch }
        } catch is CancellationError {
        } catch AppError.cancelled {
        } catch {
            if context == ticket, !Task.isCancelled { self.error = error as? AppError ?? .parseMismatch }
        }
    }
    private func append(_ values: [GallerySummary]) {
        var merged = items
        var indices = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.reference.key, $0.offset) })
        for item in values {
            if let index = indices[item.reference.key] {
                if merged[index] != item { merged[index] = item }
            } else {
                indices[item.reference.key] = merged.count
                merged.append(item)
            }
        }
        items = merged
    }
}

@MainActor @Observable public final class RemoteFavoriteEditorModel {
    public private(set) var form: FavoritePopup?
    public private(set) var busy = false
    public private(set) var unconfirmed = false
    public private(set) var message: String?
    private let repository: any RemoteFavoritesRepository
    private let request: GalleryRequest
    public init(repository: any RemoteFavoritesRepository, request: GalleryRequest) { self.repository = repository; self.request = request }
    public func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { form = try await repository.popup(request: request); unconfirmed = false; message = nil }
        catch { message = "无法读取网站收藏状态，请重试或验证当前会话。" }
    }
    @discardableResult public func save(_ action: FavoriteAction) async -> Bool {
        guard !busy, !unconfirmed, form != nil else { return false }
        busy = true; message = nil; defer { busy = false }
        do {
            try await repository.mutate(request: FavoriteMutation(reference: request.reference, scope: request.scope, action: action))
            // Refresh displayed state only after the repository confirmed the write.
            do { form = try await repository.popup(request: request); message = "网站收藏已更新并核验。"; return true }
            catch { unconfirmed = true; message = "更新已核验，但状态刷新失败，请刷新核验后继续。" }
        } catch FavoriteWriteFailure.unconfirmed {
            unconfirmed = true; message = "操作结果未确认。请先刷新核验，避免重复提交。"
        } catch { message = "操作未完成，原显示状态保留。请刷新核验后重试。" }
        return false
    }
}
