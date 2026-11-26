import Foundation
import ErosCore

public struct ReaderPrefetchPresentation: Equatable, Sendable {
    public enum Layout: Equatable, Sendable { case single, spread, continuous }
    public let source: UUID
    public let layout: Layout

    public init(source: UUID, layout: Layout) {
        self.source = source
        self.layout = layout
    }
}

public struct ReaderPrefetchViewport: Equatable, Sendable {
    public let pages: [Int]
    public let ready: Bool

    public init(pages: [Int], ready: Bool) {
        self.pages = pages
        self.ready = ready
    }
}

/// Owns speculative subscriptions for one presented reader.
@MainActor public final class ReaderPrefetchSession {
    public typealias LoadPage = @MainActor @Sendable (PageIndex) async -> Bool

    private struct Flight {
        let page: Int
        let presentation: ReaderPrefetchPresentation
        let task: Task<Void, Never>
    }

    private var presentation: ReaderPrefetchPresentation?
    private var viewport: ReaderPrefetchViewport?
    private var loadPage: LoadPage?
    private var pageCount = 0
    private var limit: Int
    private var active = false
    private var memoryWarningPages: [Int]?
    private var finished: Set<Int> = []
    private var pausedWindow = false
    private var flight: Flight?

    public init(limit: Int = AppPreferences().readerPrefetchPages) {
        self.limit = AppPreferences.readerPrefetchPageRange.contains(limit) ? limit : 0
    }

    public var visiblePages: [Int] { viewport?.pages ?? [] }
    var isPrefetching: Bool { flight != nil }

    public func present(_ value: ReaderPrefetchPresentation) {
        guard presentation != value else { return }
        resetViewport()
        presentation = value
    }

    public func report(_ value: ReaderPrefetchViewport, pageCount: Int,
                       for expected: ReaderPrefetchPresentation, load: @escaping LoadPage) {
        guard presentation == expected else { return }
        guard viewport != value || self.pageCount != pageCount else { return }
        viewport = value
        self.pageCount = pageCount
        loadPage = load
        if !value.pages.isEmpty, value.pages != memoryWarningPages { memoryWarningPages = nil }
        refreshWindow()
    }

    public func setLimit(_ value: Int) {
        guard AppPreferences.readerPrefetchPageRange.contains(value), value != limit else { return }
        limit = value
        refreshWindow()
    }

    public func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if !value, let viewport { self.viewport = ReaderPrefetchViewport(pages: viewport.pages, ready: false) }
        pausedWindow = false
        reconcile()
    }

    /// An offline display can reuse the bitmap being prepared for this page.
    public func waitForPrefetch(of page: PageIndex) async {
        guard let flight, flight.presentation == presentation, flight.page == page.value else { return }
        await flight.task.value
    }

    public func cancelPrefetch(of page: PageIndex) {
        guard let flight, flight.presentation == presentation, flight.page == page.value else { return }
        flight.task.cancel()
    }

    public func handleMemoryWarning() {
        memoryWarningPages = visiblePages
        reconcile()
    }

    public func close() {
        active = false
        presentation = nil
        resetViewport()
    }

    private var window: [Int] {
        ReaderPrefetchWindow.pages(after: visiblePages, pageCount: pageCount, limit: limit)
    }

    private func resetViewport() {
        viewport = nil
        loadPage = nil
        pageCount = 0
        finished.removeAll()
        pausedWindow = false
        memoryWarningPages = nil
        flight?.task.cancel()
    }

    private func refreshWindow() {
        finished.formIntersection(window)
        pausedWindow = false
        reconcile()
    }

    private func reconcile() {
        guard active, limit > 0, memoryWarningPages == nil,
              let presentation, let viewport, let loadPage else {
            flight?.task.cancel()
            return
        }
        let pages = window
        if let flight {
            // A speculative page becoming visible can hand its ticket to the
            // visible request. The rest of the window waits for the viewport.
            let keepPage = viewport.ready ? pages.contains(flight.page) : viewport.pages.contains(flight.page)
            if flight.presentation != presentation || !keepPage { flight.task.cancel() }
            return
        }
        guard viewport.ready, !pausedWindow,
              let value = pages.first(where: { !finished.contains($0) }),
              let page = try? PageIndex(value) else { return }
        let task = Task(priority: .utility) { [weak self] in
            let completed = Task.isCancelled ? false : await loadPage(page)
            self?.finish(page: value, presentation: presentation, completed: completed, cancelled: Task.isCancelled)
        }
        flight = Flight(page: value, presentation: presentation, task: task)
    }

    private func finish(page: Int, presentation expected: ReaderPrefetchPresentation, completed: Bool, cancelled: Bool) {
        // A replacement waits until the previous pipeline consumer exits.
        flight = nil
        if !cancelled, presentation == expected, window.contains(page) {
            if completed { finished.insert(page) }
            else { pausedWindow = true }
        }
        reconcile()
    }
}
