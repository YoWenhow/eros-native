import SwiftUI
import ErosCore
import ErosServices

/// Each launch gets a fresh navigation identity, even for repeated terms.
struct SearchResultsRoute: Hashable {
    let id = UUID()
    let scope: SessionScope
    let terms: String
    let filters: SearchFilterSelection?

    init(scope: SessionScope, terms: String, filters: SearchFilterSelection? = nil) {
        self.scope = scope
        self.terms = terms
        self.filters = filters
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct OnlineSearchView: View {
    @ObservedObject var model: OnlineLibraryModel
    let presentFilters: @MainActor (SearchFilterSheetContext) -> Void
    let openResults: @MainActor (SearchResultsRoute) -> Void

    var body: some View {
        Group {
            if model.localOnly && !model.profileSwitching {
                LocalOnlyContentView()
            } else if let error = model.preparationError {
                NativeStateView(title: "暂时无法搜索", message: error, symbol: "exclamationmark.triangle",
                    action: { Task { await model.refresh() } })
            } else if let search = model.search, let scope = model.state?.scope, let services = model.services {
                SearchContentView(search: search, scope: scope, previews: model.previews, services: services,
                    presentFilters: presentFilters, openResults: openResults)
                    .onAppear { search.reloadSavedFilters(scope: scope) }
            } else {
                StartupActivity()
            }
        }
        .navigationTitle("搜索")
    }
}

struct SearchResultsView: View {
    @State private var search: SearchViewModel
    let previews: PreviewImageLoader
    let services: AppContainer
    let route: SearchResultsRoute

    init(services: AppContainer, previews: PreviewImageLoader, route: SearchResultsRoute) {
        self.services = services
        self.previews = previews
        self.route = route
        _search = State(initialValue: SearchViewModel(repository: services.galleries, preferences: SearchFilterPreferences()))
    }

    var body: some View {
        SearchContentView(search: search, scope: route.scope, previews: previews, services: services)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { search.startResults(terms: route.terms, scope: route.scope, filters: route.filters) }
            .nativeTabPage(routeID: route.id,
                nonScrolling: search.submittedTerms == nil ||
                    (search.results.hasLoaded && search.results.items.isEmpty && search.results.initialError == nil))
    }
}

private struct SearchContentView: View {
    @Bindable var search: SearchViewModel
    let scope: SessionScope
    let previews: PreviewImageLoader
    let services: AppContainer
    var presentFilters: (@MainActor (SearchFilterSheetContext) -> Void)? = nil
    var openResults: (@MainActor (SearchResultsRoute) -> Void)? = nil
    @FocusState private var inputFocused: Bool
    @State private var searchPresented = false
    @State private var showingAssistance = false
    @State private var draftOnDeparture: String?
    @State private var searchNavigation = NativeSearchPage.Navigation()
    @State private var filterSheet: SearchFilterSheetContext?
    @State private var filterError: String?

    var body: some View {
        Group {
            if let terms = search.submittedTerms {
                let submission = search.submissionID
                OnlineFeedView(feed: search.results, site: scope.storage.site, previews: previews,
                    downloadLibrary: services.downloadLibrary,
                    refresh: { await search.refresh(scope: scope) },
                    emptyTitle: "没有搜索结果", emptyMessage: "请调整关键词或搜索表达式后重新提交。",
                    resultLabel: search.validationMessage ??
                        ("当前搜索：" + (terms.isEmpty ? "仅筛选" : terms) + " · 筛选 \(search.appliedFilters.activeCount) · 结果 \(search.results.resultCountText)"),
                    onResultTap: finishEditing,
                    onResultDrag: finishEditing)
                    .task(id: submission) {
                        // Resume an interrupted load on return, preserving accepted rows or an explicit retry state.
                        guard !search.results.hasLoaded, search.results.initialError == nil else { return }
                        await search.refresh(scope: scope, submission: submission)
                    }
            } else {
                ContentUnavailableView("输入搜索内容", systemImage: "magnifyingglass",
                    description: Text(search.validationMessage ?? "输入后点击键盘上的搜索。支持关键词和网站搜索表达式。"))
                    .onTapGesture(perform: finishEditing)
            }
        }
        // Preserve list identity and scroll position, but don't draw results behind
        // the translucent keyboard while the editing surface is visible.
        .opacity(showingAssistance ? 0 : 1)
        .accessibilityHidden(showingAssistance)
        .allowsHitTesting(!showingAssistance)
        .overlay(alignment: .top) {
            if showingAssistance {
                SearchAssistOverlay(draft: search.draft, scope: scope, services: services, choose: submit)
            }
        }
        .background { Color(uiColor: .systemBackground).ignoresSafeArea() }
        .background(NativeSearchPage(navigation: searchNavigation))
        .searchable(text: $search.draft, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "关键词或搜索表达式")
        .searchPresentationToolbarBehavior(openResults == nil ? .avoidHidingContent : .automatic)
        .searchFocused($inputFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { submit(search.draft) }
        .onChange(of: inputFocused) { _, focused in
            // System interruptions can remove focus without cancelling the search.
            if focused { showingAssistance = true }
        }
        .onChange(of: searchPresented) { _, presented in
            if !presented { showingAssistance = false; searchNavigation.cancel() }
        }
        .onAppear(perform: restoreDraft)
        .onDisappear(perform: leaveSearch)
        .onChange(of: scope) {
            draftOnDeparture = nil
            finishEditing()
            searchPresented = false
            filterSheet = nil
            filterError = nil
        }
        .sheet(item: $filterSheet) { sheet in
            SearchFilterSheet(context: sheet, preferencesMessage: search.preferencesMessage, onApply: applyFilters)
        }
        .alert("无法打开筛选", isPresented: Binding(get: { filterError != nil }, set: { if !$0 { filterError = nil } })) {
            Button("好", role: .cancel) { filterError = nil }
        } message: { Text(filterError ?? "") }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    finishEditing()
                    do {
                        let sheet = SearchFilterSheetContext(scope: scope, draft: try search.filterDraft())
                        if let presentFilters {
                            presentFilters(sheet)
                        } else {
                            filterSheet = sheet
                        }
                    } catch {
                        filterError = "当前筛选无法编辑，请重新打开搜索页。"
                    }
                } label: {
                    Label("筛选 \(search.appliedFilters.activeCount)", systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("高级筛选，已应用 \(search.appliedFilters.activeCount) 项")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘", systemImage: "keyboard.chevron.compact.down", action: finishEditing)
            }
        }
    }

    private func submit(_ terms: String) {
        #if DEBUG
        NativeUITrace.shared.event("search.submit", ["root": openResults != nil,
            "scopeMatches": search.activeScope == scope, "length": terms.count,
            "focused": inputFocused, "presented": searchPresented])
        #endif
        search.draft = terms
        if let openResults {
            guard search.validateDraft(scope: scope) else { return }
            let route = SearchResultsRoute(scope: scope, terms: terms, filters: search.appliedFilters)
            searchNavigation.perform {
                // UIKit owns the push; closing its search presentation here starts a competing dismissal.
                // Preserve the draft; only a page removed from its native stack ends search.
                if draftOnDeparture == nil { draftOnDeparture = search.draft }
                finishEditing()
                openResults(route)
            }
        } else if search.submitDraft(scope: scope) != nil {
            finishEditing()
        }
    }

    private func finishEditing() {
        showingAssistance = false
        inputFocused = false
        // A new query on this page must not cancel or reset its native search field.
    }

    private func leaveSearch() {
        searchNavigation.finishDeparture()
        searchNavigation.cancel()
        if draftOnDeparture == nil { draftOnDeparture = search.draft }
        finishEditing()
        #if DEBUG
        NativeUITrace.shared.event("search.depart", ["length": draftOnDeparture?.count ?? 0])
        #endif
    }

    private func restoreDraft() {
        guard let draftOnDeparture else { return }
        searchNavigation.perform {
            // An interactive return may still be cancelled, and UIKit can clear its search field
            // while settling that transition. Restore only after this page is actually current.
            search.draft = draftOnDeparture
            self.draftOnDeparture = nil
            #if DEBUG
            NativeUITrace.shared.event("search.restore", ["length": search.draft.count])
            #endif
        }
    }

    private func applyFilters(_ draft: SearchFilterDraft, scope: SessionScope) throws {
        try search.applyFilters(draft, scope: scope)
    }
}
