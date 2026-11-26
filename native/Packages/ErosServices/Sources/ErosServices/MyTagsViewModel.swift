import Foundation
import Observation
import ErosCore

@MainActor @Observable public final class MyTagsViewModel {
    public private(set) var snapshot:MyTagsSnapshot?
    public private(set) var collections:[MyTagsSet]=[]
    public private(set) var requestedSetID:String?
    public private(set) var fromCache=false
    public private(set) var cacheSaveFailed=false
    public private(set) var loading=false
    public private(set) var error:AppError?
    public let scope:SessionScope
    private let repository:any MyTagsRepository
    private let sessions:any SessionProvider
    private var revision=UUID()
    private var work:Task<Void,Never>?
    public init(repository:any MyTagsRepository,sessions:any SessionProvider,scope:SessionScope) { self.repository=repository;self.sessions=sessions;self.scope=scope }
    public var selectedSetID:String? { requestedSetID ?? snapshot?.page.selectedSetID }
    private func current() async -> Bool { (try? await sessions.current().scope)==scope }
    private func clearForSessionChange() { revision=UUID();work?.cancel();work=nil;snapshot=nil;collections=[];loading=false;fromCache=false;cacheSaveFailed=false;error = .staleSession }
    public func validateScope() async -> Bool {
        guard await current() else { clearForSessionChange();return false };return true
    }
    public func start() async { await load(setID:requestedSetID) }
    public func refresh() async { guard !loading else { return };await load(setID:requestedSetID) }
    public func select(_ setID:String) async {
        guard collections.contains(where:{$0.id==setID}),setID != selectedSetID else { return };await load(setID:setID)
    }
    private func load(setID:String?) async {
        work?.cancel();revision=UUID();let ticket=revision
        if requestedSetID != setID { snapshot=nil;fromCache=false }
        requestedSetID=setID;loading=true;error=nil;cacheSaveFailed=false
        let task=Task { [self] in
            defer { if revision==ticket { loading=false;work=nil } }
            guard await current() else { if revision==ticket { clearForSessionChange() };return }
            if snapshot==nil,let cached=try? await repository.cached(scope:scope,setID:setID) {
                guard !Task.isCancelled,revision==ticket,await current() else { return }
                snapshot=cached;collections=cached.page.sets;fromCache=true
            }
            do {
                let result=try await repository.fetch(scope:scope,setID:setID)
                try Task.checkCancellation();guard revision==ticket else { return }
                guard await current() else { clearForSessionChange();return }
                snapshot=result.snapshot;collections=result.snapshot.page.sets;fromCache=false;cacheSaveFailed=result.cacheSaveFailed
            } catch is CancellationError {} catch AppError.cancelled {} catch {
                guard !Task.isCancelled,revision==ticket else { return }
                guard await current() else { clearForSessionChange();return }
                self.error=error as? AppError ?? .parseMismatch
                if snapshot != nil { fromCache=true }
            }
        }
        work=task;await withTaskCancellationHandler { await task.value } onCancel:{task.cancel()}
    }
    public func acceptWriteReadback(_ value:MyTagsSnapshot,cacheSaveFailed:Bool) async {
        guard await current(),value.page.site==scope.storage.site,value.page.selectedSetID==selectedSetID else{return}
        snapshot=value;collections=value.page.sets;fromCache=false;self.cacheSaveFailed=cacheSaveFailed
    }
    public func cancel() { revision=UUID();work?.cancel();work=nil;loading=false }
}
