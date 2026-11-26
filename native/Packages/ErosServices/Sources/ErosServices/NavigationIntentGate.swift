import Foundation
import ErosCore

/// A completion may only push onto the same still-visible source revision, once.
@MainActor public final class NavigationIntentGate {
    public struct Ticket: Hashable, Sendable {
        public let stackID:Int
        let revision:UUID
        let scope:SessionScope
        let id:UUID
    }
    private var selected=0
    private var revisions:[Int:UUID]=[:]
    private var pending:[UUID:Int]=[:]
    public init() {}
    public func select(_ stackID:Int) {
        if selected != stackID { invalidate(selected); selected=stackID }
    }
    public func invalidate(_ stackID:Int) { revisions[stackID]=UUID();pending=pending.filter{$0.value != stackID} }
    public func invalidateAll() { revisions=[:]; pending=[:] }
    public func begin(stackID:Int,scope:SessionScope) -> Ticket? {
        guard selected==stackID else{return nil}
        let revision=revisions[stackID] ?? UUID();revisions[stackID]=revision
        let ticket=Ticket(stackID:stackID,revision:revision,scope:scope,id:UUID());pending[ticket.id]=stackID
        return ticket
    }
    public func cancel(_ ticket:Ticket) { pending.removeValue(forKey:ticket.id) }
    public func isCurrent(_ ticket:Ticket,scope:SessionScope) -> Bool {
        selected==ticket.stackID && revisions[ticket.stackID]==ticket.revision && ticket.scope==scope && pending[ticket.id]==ticket.stackID
    }
    public func consume(_ ticket:Ticket,scope:SessionScope) -> Bool {
        guard isCurrent(ticket,scope:scope) else{return false}
        pending.removeValue(forKey:ticket.id);return true
    }
}
