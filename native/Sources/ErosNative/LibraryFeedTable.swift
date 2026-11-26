import SwiftUI
import UIKit
import Observation
import ErosCore
import ErosServices

/// A root points only to the currently selected source's concrete table.
@MainActor final class LibraryRootListActions: ObservableObject {
    private weak var table: LibraryFeedTableController?

    func attach(_ candidate: LibraryFeedTableController) {
        if candidate.ownsCurrentSource { table = candidate }
    }
    func detach(_ candidate: LibraryFeedTableController) {
        if table === candidate { table = nil }
    }
    var isAvailable: Bool { table?.isAvailable == true }
    func perform(_ input: LibraryListRefreshCycle.Input,
        while eligible: @escaping @MainActor () -> Bool = { true }) {
        table?.receive(input, while: eligible)
    }
    func prepareNavigation() { table?.prepareNavigationViewport() }
    func cancel() { table?.retire() }
    func cancelObsoleteSource() {
        if let table, !table.ownsCurrentSource { table.retire() }
    }
}

struct LibraryPaginationRow: Equatable {
    let pages: Int
    let items: Int
    let loading: Bool
    let refreshing: Bool
    let needsRefresh: Bool
    let hasNext: Bool
    let canLoad: Bool
    let offersContinue: Bool
    let error: AppError?
}

struct LibraryFeedRow: Identifiable, Equatable {
    enum ID: Hashable { case empty, initialError, refreshError, rules, downloadUnavailable, gallery(GalleryKey), footer }
    enum Value: Equatable {
        case empty
        case error(AppError, busy: Bool)
        case rules(AccountID, hidden: Int, revealed: Bool, error: String?)
        case downloadUnavailable
        case gallery(GallerySummary, SessionScope, GalleryDownloadStatus?)
        case footer(LibraryPaginationRow)
    }
    let id: ID
    let value: Value
}

struct LibraryFeedTable: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    let actions: LibraryRootListActions
    let safeAreaInsets: EdgeInsets
    let rows: [LibraryFeedRow]
    let currentRows: @MainActor () -> [LibraryFeedRow]
    let ownsSource: @MainActor () -> Bool
    let enabled: Bool
    let canRefresh: @MainActor () -> Bool
    let refresh: @MainActor () async -> Void
    let render: @MainActor (LibraryFeedRow) -> AnyView
    let didDrag: @MainActor () -> Void
    let nearEndChanged: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> LibraryFeedTableController {
        LibraryFeedTableController()
    }
    func updateUIViewController(_ controller: LibraryFeedTableController, context: Context) {
        controller.update(self, environment: context.environment, colorScheme: colorScheme)
    }
    static func dismantleUIViewController(_ controller: LibraryFeedTableController, coordinator: ()) {
        controller.detach()
    }
}

@MainActor @Observable
private final class LibraryFeedAppearance {
    var colorScheme: ColorScheme = .light
}

private struct LibraryFeedHostedRow: View {
    let content: AnyView
    let environment: EnvironmentValues
    let appearance: LibraryFeedAppearance

    var body: some View {
        // UIHostingConfiguration owns a separate SwiftUI root. Keep its color
        // scheme live even when the row data and its environment snapshot are unchanged.
        content.environment(\.colorScheme, appearance.colorScheme)
            .environment(\.self, environment)
    }
}

/// The table, system refresh control, row snapshot and motion belong to the
/// same source. The table extends under the bars; UIKit keeps resting content
/// within the safe area even while the refresh control adjusts its own inset.
@MainActor final class LibraryFeedTableController: UIViewController, UITableViewDelegate, LibraryRefreshSurface {
    private let table = UITableView(frame: .zero, style: .plain)
    private let control = UIRefreshControl()
    private weak var navigationScrollOwner: UIViewController?
    private let cycle = LibraryListRefreshCycle()
    private var input: LibraryFeedTable?
    private var rowEnvironment: EnvironmentValues?
    private let rowAppearance = LibraryFeedAppearance()
    private var dataSource: UITableViewDiffableDataSource<Int, LibraryFeedRow.ID>!
    private var rowSnapshot = LibraryFeedSnapshot<LibraryFeedRow>()
    private enum ScrollPurpose {
        case top
        case reveal(height: CGFloat)
    }
    private struct ScrollCompletion {
        let id = UUID()
        let purpose: ScrollPurpose
        let corrected: Bool
        let action: @MainActor () -> Void
    }
    private var pendingScroll: ScrollCompletion?
    private var scrollPresentationObserver: CADisplayLink?
    private var returningControl: UUID?
    private var nearEnd = false

    private struct NavigationViewport {
        let id: UUID
        let contentInset: UIEdgeInsets
        let adjustedInset: UIEdgeInsets
        let offset: CGPoint
        var restorationRequested = false
    }
    private var navigationViewport: NavigationViewport?
    private var updatingNavigationViewport = false
    private var scheduledViewportRestore: UUID?

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let transition = navigationScrollOwner?.transitionCoordinator,
              let viewport = navigationViewport else { return }
        transition.animate(alongsideTransition: nil) { [weak self, weak transition] _ in
            self?.restoreNavigationViewportIfVisible(id: viewport.id, completing: transition)
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let transition = navigationScrollOwner?.transitionCoordinator,
              let viewport = navigationViewport else { return }
        transition.animate(alongsideTransition: nil) { [weak self, weak transition] _ in
            self?.restoreNavigationViewportIfVisible(id: viewport.id, completing: transition)
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let id = navigationViewport?.id { restoreNavigationViewportIfVisible(id: id) }
    }
    func prepareNavigationViewport() {
        guard isAvailable, cycle.phase == .idle, returningControl == nil, !control.isRefreshing else { return }
        // A new accepted push owns a new lease even if an old return is settling.
        let saved = navigationViewport
        navigationViewport = NavigationViewport(id: UUID(), contentInset: saved?.contentInset ?? table.contentInset,
            adjustedInset: saved?.adjustedInset ?? table.adjustedContentInset, offset: saved?.offset ?? table.contentOffset)
        #if DEBUG
        NativeUITrace.shared.event("library.viewport.hold", ["top": table.adjustedContentInset.top, "y": table.contentOffset.y])
        #endif
    }
    private func restoreNavigationViewportIfVisible(id: UUID,
        completing: (any UIViewControllerTransitionCoordinator)? = nil) {
        guard let saved = navigationViewport, saved.id == id,
              let owner = navigationScrollOwner, owner.navigationController?.topViewController === owner,
              viewIfLoaded?.window != nil else { return }
        if let current = owner.transitionCoordinator, current !== completing { return }
        navigationViewport?.restorationRequested = true
        scheduleNavigationViewportRestoration()
    }
    private func scheduleNavigationViewportRestoration() {
        guard let saved = navigationViewport, saved.restorationRequested,
              scheduledViewportRestore != saved.id, automaticInsetsMatch(saved) else { return }
        scheduledViewportRestore = saved.id
        // UIKit may adjust contentOffset after its adjusted-inset callback.
        // Finish after that layout transaction, with the lease still protecting
        // any offset callbacks. This is not an animation timer or a touch gate.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.scheduledViewportRestore == saved.id { self.scheduledViewportRestore = nil }
            guard self.navigationViewport?.id == saved.id, self.automaticInsetsMatch(saved),
                  let owner = self.navigationScrollOwner,
                  owner.navigationController?.topViewController === owner else { return }
            self.maintainNavigationViewport()
            self.navigationViewport = nil
            #if DEBUG
            NativeUITrace.shared.event("library.viewport.restore", ["top": self.table.adjustedContentInset.top,
                "y": self.table.contentOffset.y])
            #endif
        }
    }
    private func automaticInsetsMatch(_ saved: NavigationViewport) -> Bool {
        let current = table.adjustedContentInset, base = table.contentInset
        return abs(current.top - base.top - saved.adjustedInset.top + saved.contentInset.top) < 0.5
            && abs(current.bottom - base.bottom - saved.adjustedInset.bottom + saved.contentInset.bottom) < 0.5
    }

    var ownsCurrentSource: Bool { input?.ownsSource() == true }
    var isAvailable: Bool { ownsCurrentSource && viewIfLoaded?.window != nil }
    private var restingTopY: CGFloat { -table.adjustedContentInset.top }
    private var visibleScrollY: CGFloat { table.layer.presentation()?.bounds.minY ?? table.contentOffset.y }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        table.contentInsetAdjustmentBehavior = .always
        setContentScrollView(table, for: [.top, .bottom])
        table.alwaysBounceVertical = true
        table.keyboardDismissMode = .onDrag
        table.backgroundColor = .systemGroupedBackground
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 172
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "feed")
        dataSource = UITableViewDiffableDataSource(tableView: table) { [weak self] table, path, id in
            let cell = table.dequeueReusableCell(withIdentifier: "feed", for: path)
            guard let self, let row = self.rowSnapshot[id], let input = self.input, let environment = self.rowEnvironment else {
                cell.contentConfiguration = nil
                return cell
            }
            cell.selectionStyle = .none
            cell.backgroundColor = .clear
            let content = LibraryFeedHostedRow(content: input.render(row), environment: environment,
                appearance: self.rowAppearance)
            cell.contentConfiguration = UIHostingConfiguration { content.id(row.id) }.margins(.all, 0)
            return cell
        }
        table.refreshControl = control
        control.addTarget(self, action: #selector(pulled), for: .valueChanged)
    }

    func update(_ input: LibraryFeedTable, environment: EnvironmentValues, colorScheme: ColorScheme) {
        loadViewIfNeeded()
        self.input = input
        updateContentSafeArea()
        rowEnvironment = environment
        if rowAppearance.colorScheme != colorScheme { rowAppearance.colorScheme = colorScheme }
        input.actions.attach(self)
        connectNavigationScroll()
        if !input.enabled || !ownsCurrentSource {
            if cycle.phase != .idle { retire() }
        }
        control.isEnabled = input.enabled && (cycle.phase != .idle || input.canRefresh())
        if cycle.phase == .idle { applyRows(input.rows) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        connectNavigationScroll()
        maintainNavigationViewport()
        scheduleNavigationViewportRestoration()
    }

    private func connectNavigationScroll() {
        guard ownsCurrentSource, let tableView = viewIfLoaded, tableView.window != nil,
              let page = nativeNavigationPage(containing: tableView),
              page.navigation.topViewController === page.owner, page.owner !== self else { return }

        let newOwner = navigationScrollOwner !== page.owner
        if newOwner {
            disconnectNavigationScroll()
            navigationScrollOwner = page.owner
        }
        // The bar observes the hosting navigation page while the table keeps its refresh control.
        if newOwner || page.owner.contentScrollView(for: .top) !== table {
            page.owner.setContentScrollView(table, for: .top)
        }
    }

    private func disconnectNavigationScroll() {
        let owner = navigationScrollOwner
        navigationScrollOwner = nil
        if let owner, owner.contentScrollView(for: .top) === table {
            owner.setContentScrollView(nil, for: .top)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateContentSafeArea()
    }

    private func maintainNavigationViewport() {
        guard let saved = navigationViewport, !updatingNavigationViewport else { return }
        updatingNavigationViewport = true
        defer { updatingNavigationViewport = false }
        let automatic = UIEdgeInsets(top: table.adjustedContentInset.top - table.contentInset.top,
            left: table.adjustedContentInset.left - table.contentInset.left,
            bottom: table.adjustedContentInset.bottom - table.contentInset.bottom,
            right: table.adjustedContentInset.right - table.contentInset.right)
        let needed = UIEdgeInsets(top: saved.adjustedInset.top - automatic.top,
            left: saved.adjustedInset.left - automatic.left,
            bottom: saved.adjustedInset.bottom - automatic.bottom,
            right: saved.adjustedInset.right - automatic.right)
        if table.contentInset != needed { table.contentInset = needed }
        if table.contentOffset != saved.offset { table.setContentOffset(saved.offset, animated: false) }
    }

    private func updateContentSafeArea() {
        guard let insets = input?.safeAreaInsets else { return }
        // Preserve SwiftUI's status/error banners without counting UIKit's bars twice.
        let system = view.safeAreaInsets
        let additional = additionalSafeAreaInsets
        let top = max(0, insets.top - max(0, system.top - additional.top))
        let bottom = max(0, insets.bottom - max(0, system.bottom - additional.bottom))
        let needed = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if needed != additional { additionalSafeAreaInsets = needed }
    }

    private func applyRows(_ observed: [LibraryFeedRow]? = nil) {
        guard cycle.phase == .idle, returningControl == nil, !control.isRefreshing,
              ownsCurrentSource, let input, !rowSnapshot.isApplying else { return }
        let rows = observed ?? input.currentRows()
        guard let changed = rowSnapshot.begin(rows) else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, LibraryFeedRow.ID>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id))
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.rowSnapshot.finish()
            self.applyRows()
        }
    }

    @objc private func pulled() {
        guard control.isRefreshing, cycle.phase != .refreshing else { return }
        guard isAvailable, input?.enabled == true, input?.canRefresh() == true,
              !LibraryTabActions.hasPresentedModal else {
            finishRefresh()
            return
        }
        receive(.pull)
    }

    func receive(_ kind: LibraryListRefreshCycle.Input,
        while eligible: @escaping @MainActor () -> Bool = { true }) {
        guard let input else { return }
        cycle.receive(kind, on: self, isCurrent: { [weak self] in
            guard let self, let current = self.input, self.isAvailable, current.enabled, eligible(),
                  !LibraryTabActions.hasPresentedModal else { return false }
            return kind == .scrollToTop || current.canRefresh()
        }, refresh: input.refresh)
    }

    func moveToRestingTop(completion: @escaping @MainActor () -> Void) {
        guard pendingScroll == nil else { completion(); return }
        table.interruptUserScrollForTab()
        scroll(to: .top) { [weak self] in
            completion()
            self?.applyRows()
        }
    }

    func showRefresh(completion: @escaping @MainActor () -> Void) {
        // UIKit already presented the same control when the gesture triggered it.
        guard !control.isRefreshing else { completion(); return }
        let initialHeight = control.bounds.height
        control.beginRefreshing()
        table.layoutIfNeeded()
        let fittedHeight = control.sizeThatFits(CGSize(width: table.bounds.width, height: 0)).height
        let height = max(initialHeight, control.bounds.height, fittedHeight)
        scroll(to: .reveal(height: height), completion: completion)
    }

    func finishRefresh() {
        guard control.isRefreshing else { applyRows(); return }
        let id = UUID()
        returningControl = id
        // Commit the next row snapshot after the system has closed the inset.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.returningControl == id else { return }
            self.returningControl = nil
            self.applyRows()
        }
        control.endRefreshing()
        CATransaction.commit()
    }

    private func scrollTarget(for purpose: ScrollPurpose) -> CGFloat {
        switch purpose {
        case .top:
            return restingTopY
        case .reveal(let height):
            return CGFloat(LibraryListRefreshCycle.programmaticRevealY(
                adjustedTopInset: Double(table.adjustedContentInset.top),
                safeAreaTop: Double(table.safeAreaInsets.top),
                controlHeight: Double(height)
            ))
        }
    }

    private func layoutScrollHierarchy() {
        // The navigation bar can still be expanding after the table reaches its old top.
        navigationScrollOwner?.navigationController?.viewIfLoaded?.layoutIfNeeded()
        table.layoutIfNeeded()
    }

    private func scroll(to purpose: ScrollPurpose, corrected: Bool = false,
        completion: @escaping @MainActor () -> Void) {
        layoutScrollHierarchy()
        let y = scrollTarget(for: purpose)
        if abs(table.contentOffset.y - y) <= 0.5, abs(visibleScrollY - y) <= 0.5 {
            completion()
            return
        }
        pendingScroll = ScrollCompletion(purpose: purpose, corrected: corrected, action: completion)
        if abs(table.contentOffset.y - y) > 0.5 {
            let offset = CGPoint(x: table.contentOffset.x, y: y)
            table.setContentOffset(offset, animated: !UIAccessibility.isReduceMotionEnabled)
        }
        if !table.isScrollAnimating { completeScroll() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        completeScroll()
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        maintainNavigationViewport()
        scheduleNavigationViewportRestoration()
        if !scrollView.isScrollAnimating { completeScroll() }
    }

    private func completeScroll() {
        guard let id = pendingScroll?.id else { return }
        // Let UIKit finish its callback before starting the next scroll.
        Task { @MainActor [weak self] in
            guard let self, let pending = self.pendingScroll, pending.id == id,
                  !self.table.isScrollAnimating else { return }
            self.layoutScrollHierarchy()
            let arrival = LibraryListRefreshCycle.scrollArrival(
                contentY: Double(self.table.contentOffset.y), visibleY: Double(self.visibleScrollY),
                targetY: Double(self.scrollTarget(for: pending.purpose)), corrected: pending.corrected
            )
            if arrival == .waitForPresentation {
                self.observeScrollPresentation()
                return
            }
            self.stopObservingScrollPresentation()
            self.pendingScroll = nil
            if arrival == .correct {
                self.scroll(to: pending.purpose, corrected: true, completion: pending.action)
            } else {
                pending.action()
            }
        }
    }

    private func observeScrollPresentation() {
        guard scrollPresentationObserver == nil else { return }
        scrollPresentationObserver = NativeScrollFrames.observe(self) { owner in
            guard owner.isAvailable else { owner.retire(); return }
            guard abs(owner.visibleScrollY - owner.table.contentOffset.y) <= 0.5 else { return }
            owner.stopObservingScrollPresentation()
            owner.completeScroll()
        }
    }

    private func stopObservingScrollPresentation() {
        scrollPresentationObserver?.invalidate()
        scrollPresentationObserver = nil
    }

    func cancelRefreshMotion() {
        stopObservingScrollPresentation()
        if pendingScroll != nil {
            pendingScroll = nil
            if table.isScrollAnimating { table.stopScrollingAndZooming() }
        }
        finishRefresh()
    }

    func retire() { cycle.cancel(on: self) }

    func detach() {
        input?.actions.detach(self)
        retire()
        input = nil
        disconnectNavigationScroll()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if let pending = pendingScroll {
            stopObservingScrollPresentation()
            pendingScroll = nil
            switch pending.purpose {
            case .top:
                cycle.interruptReturnToTop()
                applyRows()
            case .reveal:
                pending.action()
            }
        }
        input?.didDrag()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        maintainNavigationViewport()
        let visibleBottom = scrollView.bounds.maxY - scrollView.safeAreaInsets.bottom
        let next = scrollView.contentOffset.y > restingTopY && visibleBottom >= scrollView.contentSize.height - 600
        guard next != nearEnd else { return }
        nearEnd = next
        Task { @MainActor [weak self] in
            guard let self, self.nearEnd == next, self.ownsCurrentSource else { return }
            self.input?.nearEndChanged(next)
        }
    }
}
