import Foundation
import Observation
import ErosCore

public enum DownloadLibraryViewError: String, Sendable { case staleSession, conflict, unavailable, primaryHasRetainedCopies }
@MainActor @Observable public final class DownloadLibraryViewModel {
    public private(set) var scope: SessionScope
    public private(set) var target: DownloadLibraryTarget = .all
    public private(set) var sort = DownloadSort()
    public private(set) var items: [DownloadLibraryItem] = []
    public private(set) var folders: [DownloadFolder] = []
    public private(set) var counts: [DownloadLibraryTarget:Int] = [:]
    public private(set) var selection: Set<UUID> = []
    public private(set) var visibleAnchor: UUID?
    public private(set) var busyIDs: Set<UUID> = []
    public private(set) var loading = false
    public private(set) var hasLoaded = false
    public private(set) var error: DownloadLibraryViewError?
    public private(set) var polling = false
    private let repository: any DownloadLibraryReading
    private let controls: any DownloadLibraryControlling
    private let sessions: any SessionProvider
    private let waitForPoll: @Sendable () async throws -> Void
    private var revision=UUID()
    private var dirty=true
    private var dirtyRevision=UUID()
    public private(set) var sortSaving=false
    private var operations: [UUID:UUID] = [:]
    private var pollTask: Task<Void,Never>?
    private var activity=UUID()
    public init(repository: any DownloadLibraryReading, controls: any DownloadLibraryControlling,
                sessions: any SessionProvider, scope: SessionScope,
                waitForPoll: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for:.seconds(1)) }) {
        self.repository=repository; self.controls=controls; self.sessions=sessions; self.scope=scope; self.waitForPoll=waitForPoll
    }
    public func items(matchingTitle fragment: String) -> [DownloadLibraryItem] {
        fragment.isEmpty ? items : items.filter { $0.summary.titleContains(fragment) }
    }

    public func setSelection(_ ids: Set<UUID>) { selection=ids.intersection(Set(items.map(\.jobID))) }
    public func setVisibleAnchor(_ id: UUID?) { visibleAnchor=id.flatMap { id in items.contains { $0.jobID == id } ? id : nil } }
    public func markDirty() { dirty=true; dirtyRevision=UUID() }
    public func setScope(_ scope: SessionScope) {
        guard scope != self.scope else { return }
        setActivity(visible:false,foreground:false)
        revision=UUID(); loading=false; hasLoaded=false
        self.scope=scope; target = .all; sort=DownloadSort(); items=[]; folders=[]; counts=[:]
        selection=[]; visibleAnchor=nil; busyIDs=[]; operations=[:]; sortSaving=false; error=nil; dirty=true
    }
    public func selectTarget(_ target: DownloadLibraryTarget) async {
        guard target != self.target else { return }
        revision=UUID(); hasLoaded=false; self.target=target; selection=[]; visibleAnchor=nil; items=[]; dirty=true
        await refresh(force:true)
    }
    private func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
    private func present(_ failure: any Error) {
        if failure as? AppError == .staleSession {
            error = .staleSession; items=[]; folders=[]; counts=[:]; selection=[]; visibleAnchor=nil
        } else if failure as? DownloadLibraryError == .conflict { error = .conflict }
        else if failure as? DownloadLibraryError == .primaryHasRetainedCopies { error = .primaryHasRetainedCopies }
        else { error = .unavailable }
    }
    public func refresh(force: Bool = false) async {
        guard busyIDs.isEmpty, !sortSaving else { dirty=true; return }
        let ticket=UUID(), scope=scope, target=target, needsFull=force || dirty, dirtyTicket=dirtyRevision
        revision=ticket; loading = !hasLoaded
        defer { if revision == ticket { loading=false } }
        do {
            try await check(scope)
            let result=try await repository.load(target:target,scope:scope,force:needsFull)
            try await check(scope)
            guard revision == ticket, self.scope == scope else { return }
            if result.target != self.target { selection=[]; visibleAnchor=nil }
            // Do not invalidate SwiftUI rows during a swipe for identical poll results.
            if self.target != result.target { self.target=result.target }
            if sort != result.sort { sort=result.sort }
            if folders != result.folders { folders=result.folders }
            if counts != result.counts { counts=result.counts }
            if items != result.items {
                items = result.items
                let ids = Set(items.map(\.jobID))
                let retainedSelection = selection.intersection(ids)
                if retainedSelection != selection { selection = retainedSelection }
                if let anchor = visibleAnchor, !ids.contains(anchor) { visibleAnchor = nil }
            }
            if dirtyRevision == dirtyTicket { dirty=false }; hasLoaded=true; error=nil
        } catch is CancellationError {} catch AppError.cancelled {} catch {
            if revision == ticket, self.scope == scope { present(error) }
        }
    }
    public func setSort(_ value: DownloadSort) async {
        guard !sortSaving, busyIDs.isEmpty else { return }
        let ticket=UUID(), scope=scope, target=target
        revision=ticket; sortSaving=true; loading=false
        var saved=false
        do {
            try await check(scope)
            try await repository.saveSort(value,target:target,scope:scope)
            try await check(scope)
            saved=true
            if revision == ticket, self.scope == scope { sort=value; dirty=true; error=nil }
        } catch is CancellationError {} catch {
            if revision == ticket, self.scope == scope { present(error) }
        }
        if self.scope == scope {
            sortSaving=false
            if saved && (revision == ticket || self.target != target) { await refresh(force:true) }
        }
    }
    public func operate(_ action: DownloadLibraryControl, id: UUID) async {
        guard items.contains(where: { $0.jobID == id }), !busyIDs.contains(id) else { return }
        let operation=UUID(), scope=scope
        operations[id]=operation; busyIDs.insert(id); revision=UUID(); loading=false
        do {
            try await check(scope)
            try await controls.control(action,id:id,scope:scope)
            try await check(scope)
            if self.scope == scope { error=nil }
        } catch is CancellationError {} catch {
            if self.scope == scope { present(error) }
        }
        guard operations[id] == operation else { return }
        operations.removeValue(forKey:id); busyIDs.remove(id); dirty=true
        // A failed control keeps its error until an explicit refresh; success refreshes once.
        if error == nil, busyIDs.isEmpty { await refresh(force:true) }
    }
    /// Delete only the confirmed IDs still in this list, returning the number left undeleted.
    public func deleteSelected(_ selection: Set<UUID>) async -> Int {
        guard !sortSaving, busyIDs.isEmpty else { return selection.count }
        let ids = items.map(\.jobID).filter(selection.contains)
        guard let firstID = ids.first else { return 0 }

        let operation = UUID(), scope = scope
        for id in ids { operations[id] = operation }
        busyIDs.formUnion(ids)
        revision = UUID()
        loading = false

        var remaining = ids.count
        var staleSession = false
        for id in ids {
            do {
                try await check(scope)
                guard operations[id] == operation else { return remaining }
                try await controls.control(.delete, id: id, scope: scope)
                try await check(scope)
                remaining -= 1
            } catch AppError.staleSession {
                staleSession = true
                break
            } catch is CancellationError {
                break
            } catch {
                // A failure on one job does not prevent deleting other confirmed jobs.
                continue
            }
        }

        guard operations[firstID] == operation else { return remaining }
        for id in ids { operations.removeValue(forKey: id) }
        busyIDs.subtract(ids)
        markDirty()
        if staleSession {
            present(AppError.staleSession)
        } else if !Task.isCancelled {
            await refresh(force: true)
        }
        return remaining
    }
    /// D09 must call on visibility/scene transitions; no timer starts in init.
    public func setActivity(visible: Bool, foreground: Bool, refreshImmediately: Bool = true) {
        let shouldPoll=visible && foreground
        guard shouldPoll != polling else { return }
        activity=UUID(); let ticket=activity
        pollTask?.cancel(); pollTask=nil; polling=shouldPoll
        if !shouldPoll { revision=UUID(); loading=false; return }
        pollTask=Task { [weak self, waitForPoll] in
            if !refreshImmediately {
                do { try await waitForPoll() } catch { return }
            }
            while !Task.isCancelled {
                guard self?.activity == ticket else { return }
                await self?.refresh()
                guard !Task.isCancelled, self?.activity == ticket else { return }
                do { try await waitForPoll() } catch { break }
            }
        }
    }
    isolated deinit { pollTask?.cancel() }
}