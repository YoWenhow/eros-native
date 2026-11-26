import Foundation
import Observation
import ErosCore

/// At most seven independent feeds, all belonging to one explicitly activated session.
/// F03b owns UI/selection persistence and must use these scoped operations for requests.
@MainActor @Observable
public final class LibrarySourcesViewModel {
    public private(set) var selected: LibrarySourceSelection = .browse
    public private(set) var activeScope: SessionScope?
    public private(set) var authenticated = false
    public private(set) var preferencesMessage: String?
    private var myTagsRevision:UInt64=0
    private let preferences: LibrarySourcePreferences?
    private let feeds: [LibrarySourceSelection: LibraryViewModel]

    public init(repository: any GalleryRepository, preferences: LibrarySourcePreferences? = nil) {
        self.preferences = preferences
        feeds = Dictionary(uniqueKeysWithValues: LibrarySourceSelection.all.map {
            ($0, LibraryViewModel(repository: repository))
        })
    }
    public var current: LibraryViewModel { state(for: selected) }
    public func state(for source: LibrarySourceSelection) -> LibraryViewModel { feeds[source]! }

    /// Only the host session owner calls this; selecting a source cannot activate another scope.
    public func activate(scope: SessionScope, authenticated: Bool = false) {
        if activeScope == scope {
            if self.authenticated != authenticated { state(for: .watched).reset() }
            self.authenticated = authenticated
            return
        }
        reset(); activeScope = scope; self.authenticated = authenticated
        do {
            let restored = try preferences?.load(scope: scope.storage) ?? .browse
            selected = restored
        } catch { preferencesMessage = "已保存的来源无法恢复，当前使用浏览。重新选择来源可保存新偏好。" }
    }
    public var requiresLogin: Bool {
        selected == .watched && (!authenticated || current.initialError == .authenticationRequired || current.initialError == .staleSession || current.refreshError == .authenticationRequired || current.refreshError == .staleSession)
    }
    public func reset() {
        myTagsRevision=0
        for feed in feeds.values { feed.reset() }
        selected = .browse; activeScope = nil; authenticated = false; preferencesMessage = nil
    }
    public func select(_ source: LibrarySourceSelection, scope: SessionScope) async throws {
        try validate(scope)
        try preferences?.save(source, scope: scope.storage)
        preferencesMessage = nil
        if selected != source { current.suspend(); selected = source }
        await loadValidated(scope: scope)
    }
    public func load(scope: SessionScope) async throws {
        try validate(scope)
        await loadValidated(scope: scope)
    }
    private func loadValidated(scope: SessionScope) async {
        guard !requiresLogin else { return }
        await current.loadIfNeeded(scope: scope, query: selected.query)
    }
    public func refresh(scope: SessionScope) async throws {
        try validate(scope)
        guard selected != .watched || authenticated else { return }
        await current.refresh(scope: scope, query: selected.query, preservingItems: true)
    }
    public func refreshWatchedAfterMyTags(revision:UInt64,scope:SessionScope) async throws {
        try validate(scope);guard revision>myTagsRevision else{return};myTagsRevision=revision
        state(for:.watched).reset()
        if selected == .watched,authenticated {await loadValidated(scope:scope)}
    }
    public func loadMore(scope: SessionScope) async throws {
        try validate(scope)
        guard selected != .watched || authenticated else { return }
        // Consume only a cursor supplied by the current response. Never synthesize page+1.
        await current.loadMore()
    }
    private func validate(_ scope: SessionScope) throws {
        guard activeScope == scope else { throw AppError.scopeMismatch }
    }
}
