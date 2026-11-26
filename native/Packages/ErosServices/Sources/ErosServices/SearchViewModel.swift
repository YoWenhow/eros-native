import Foundation
import Observation
import ErosCore

/// Draft edits never send requests. Only explicit submission establishes a query.
@MainActor @Observable
public final class SearchViewModel {
    public var draft = "" {
        didSet { validationMessage = nil }
    }
    public private(set) var submittedQuery: GalleryQuery?
    public var submittedTerms: String? { submittedQuery?.terms }
    public private(set) var appliedFilters = SearchFilterSelection()
    public private(set) var validationMessage: String?
    public private(set) var preferencesMessage: String?
    public private(set) var activeScope: SessionScope?
    public let results: LibraryViewModel
    public private(set) var submissionID = UUID()
    private let history:SearchHistoryStore
    private let preferences: SearchFilterPreferences?
    public init(repository: any GalleryRepository, preferences: SearchFilterPreferences? = nil, history:SearchHistoryStore = SearchHistoryStore()) {
        results = LibraryViewModel(repository: repository); self.preferences = preferences; self.history=history
    }
    public func activate(scope: SessionScope) {
        guard activeScope != scope else { return }
        resetForScopeChange()
        activeScope = scope
        reloadSavedFilters(scope: scope)
    }

    /// The search entry reads the latest preferences after visiting a result page.
    /// A result keeps the filters with which it was submitted.
    public func reloadSavedFilters(scope: SessionScope) {
        guard activeScope == scope, submittedQuery == nil else { return }
        do {
            appliedFilters = try preferences?.load(scope: scope.storage) ?? SearchFilterSelection()
            preferencesMessage = nil
        } catch {
            appliedFilters = SearchFilterSelection()
            preferencesMessage = "已保存的筛选暂时无法读取，当前使用默认条件。重新应用可保存新条件。"
        }
    }

    /// Initialize a new result page once. Gallery tags use the saved filters for
    /// their scope, while a submission from the search entry carries its selection.
    public func startResults(terms: String, scope: SessionScope, filters: SearchFilterSelection?) {
        guard activeScope == nil else { return }
        activate(scope: scope)
        if let filters { appliedFilters = filters }
        draft = terms
        stageQuery(scope: scope)
    }
    public func filterDraft() throws -> SearchFilterDraft {
        try SearchFilterDraft(query: appliedFilters.query(terms: ""))
    }
    /// A stale sheet cannot change another session's preferences or results.
    public func saveFilters(_ value: SearchFilterDraft, scope: SessionScope) throws {
        guard activeScope == scope else { throw AppError.scopeMismatch }
        let selection = try SearchFilterSelection(query: value.normalizedQuery(replacing: GalleryQuery()))
        try preferences?.save(selection, scope: scope.storage)
        appliedFilters = selection
        validationMessage = nil
        preferencesMessage = nil
    }
    @discardableResult public func applyFilters(_ value: SearchFilterDraft, scope: SessionScope) throws -> UUID {
        try saveFilters(value, scope: scope)
        return stageQuery(scope: scope)
    }

    public func validateDraft(scope: SessionScope) -> Bool {
        guard activeScope == scope else { return false }
        let valid = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appliedFilters.activeCount > 0
        validationMessage = valid ? nil : "请输入搜索内容或设置筛选条件。"
        return valid
    }

    @discardableResult public func submitDraft(scope: SessionScope) -> UUID? {
        guard validateDraft(scope: scope) else { return nil }
        return stageQuery(scope: scope)
    }

    @discardableResult private func stageQuery(scope: SessionScope) -> UUID {
        let query = appliedFilters.query(terms: draft)
        history.record(query.terms, scope: scope.storage)
        submittedQuery = query
        validationMessage = nil
        submissionID = UUID()
        results.reset()
        return submissionID
    }

    public func submit(scope: SessionScope) async {
        guard let submission = submitDraft(scope: scope) else { return }
        await refresh(scope: scope, submission: submission)
    }
    public func refresh(scope: SessionScope, submission expected: UUID? = nil) async {
        guard activeScope == scope, expected == nil || expected == submissionID, let query = submittedQuery else { return }
        await results.refresh(scope: scope, query: query)
    }
    public func resetForScopeChange() {
        submissionID = UUID(); results.reset(); submittedQuery = nil; validationMessage = nil; preferencesMessage = nil
        activeScope = nil; appliedFilters = SearchFilterSelection()
    }
    public func clear() { submissionID = UUID(); draft = ""; results.reset(); submittedQuery = nil; validationMessage = nil }
}
