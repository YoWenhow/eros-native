import Foundation
import Observation
import ErosCore
import ErosNetworking

public enum ClipboardAppPhase:Sendable {case active,inactive,background}
/// One snapshot per real foreground session; transient inactive/active permission cycles do not reread.
@MainActor @Observable public final class ForegroundClipboardPrompt {
    public private(set) var checking=false
    public private(set) var candidates:[GalleryLinkCandidate]=[]
    @ObservationIgnored private var foreground=false
    @ObservationIgnored private var epoch=UUID()
    @ObservationIgnored private var reading:Task<Void,Never>?
    @ObservationIgnored private var expiry:Task<Void,Never>?
    private let clock:any ErosCore.Clock
    public init(clock:any ErosCore.Clock = SystemNetworkClock()) {self.clock=clock}
    public func phase(_ phase:ClipboardAppPhase,provider:any ClipboardLinkProvider,
                      allowsPresentation:@escaping @MainActor () -> Bool) {
        switch phase {
        case .inactive:return
        case .background:
            foreground=false;suppress()
        case .active:
            guard !foreground else{return}
            foreground=true;suppress()
            let token=epoch;checking=true
            reading=Task {
                defer {if epoch==token {reading=nil;checking=false}}
                do {
                    let values=try await ClipboardLinkReader().read(provider:provider)
                    try Task.checkCancellation()
                    guard foreground,epoch==token,allowsPresentation() else{return}
                    candidates=values
                    expiry=Task {
                        do {
                            try await clock.sleep(seconds:10)
                            try Task.checkCancellation()
                            if foreground,epoch==token {suppress()}
                        } catch {if epoch==token {suppress()}}
                    }
                } catch {}
            }
        }
    }
    /// Hide/invalidate without creating another read opportunity in the current foreground session.
    public func suppress() {
        epoch=UUID();reading?.cancel();reading=nil;expiry?.cancel();expiry=nil;candidates=[];checking=false
    }
    public func take(_ candidate:GalleryLinkCandidate) -> ExternalLinkTarget? {
        guard candidates.contains(candidate) else{return nil}
        let target=candidate.target;suppress();return target
    }
}
/// Distinct presentations avoid old reader disappearance clearing a newer reader or another Tab.
@MainActor @Observable public final class ReaderPresentationTracker {
    private struct Presentation {let tab:Int;let generation:UUID}
    private var entries:[UUID:Presentation]=[:]
    public init() {}
    public func set(id:UUID,tab:Int,generation:UUID,visible:Bool) {
        if visible {entries[id]=Presentation(tab:tab,generation:generation)}
        else {entries.removeValue(forKey:id)}
    }
    public func isReading(tab:Int,generation:UUID) -> Bool {
        entries.values.contains{$0.tab==tab && $0.generation==generation}
    }
    public func reset() {entries=[:]}
}
