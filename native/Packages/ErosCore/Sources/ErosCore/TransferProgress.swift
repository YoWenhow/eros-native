import Foundation

public enum TransferOwner:Hashable,Sendable {
    case reader(SessionScope,GalleryID,PageIndex)
    case download(StorageScope,UUID)
}
public struct TransferSnapshot:Sendable {
    public let received:Int64
    public let expected:Int64?
    public let isEstimated:Bool
    public let fraction:Double?
    public let bytesPerSecond:Double
}
/// Ephemeral byte telemetry only. No URL, token, file path or persisted history.
public final class TransferProgress:@unchecked Sendable {
    public static let shared=TransferProgress()
    private struct Entry {
        let owner:TransferOwner
        let started:TimeInterval
        var updated:TimeInterval
        var received:Int64=0
        var expected:Int64=0
        var isEstimated=false
        var samples:[(TimeInterval,Int64)]=[]
        var finished=false
    }
    private let lock=NSLock()
    private var entries:[String:Entry]=[:]
    public init() {}
    public func begin(id:String,owner:TransferOwner,replacing:Bool=true,now:TimeInterval=ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()};prune(now)
        if !replacing,entries[id] != nil { return }
        entries[id]=Entry(owner:owner,started:now,updated:now)
    }
    public func update(id:String,received:Int64,expected:Int64,delta:Int64,
                       estimated:Bool=false,now:TimeInterval=ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()}
        guard var e=entries[id],!e.finished else { return }
        e.received=max(0,received);e.expected=max(0,expected);e.isEstimated=estimated;e.updated=now
        e.samples.removeAll{$0.0<now-2}
        if delta>0 {
            if let last=e.samples.last,now-last.0<0.1 { e.samples[e.samples.count-1].1 += delta }
            else { e.samples.append((now,delta)) }
        }
        entries[id]=e
    }
    public func finish(id:String,now:TimeInterval=ProcessInfo.processInfo.systemUptime) {
        lock.lock();defer{lock.unlock()};entries[id]?.finished=true;prune(now)
    }
    public func snapshot(owner:TransferOwner,now:TimeInterval=ProcessInfo.processInfo.systemUptime) -> TransferSnapshot {
        lock.lock();defer{lock.unlock()};prune(now)
        let values=entries.values.filter{$0.owner==owner}
        let active=values.max{$0.started<$1.started}
        let start=values.map(\.started).min() ?? now
        let bytes=values.flatMap(\.samples).filter{$0.0>=now-2}.reduce(Int64(0)){$0+$1.1}
        let expected=active.flatMap{ $0.expected>0 ? $0.expected : nil }
        let fraction=active.flatMap{e in
            e.expected>0 ? min(e.isEstimated ? 0.99 : 1,Double(e.received)/Double(e.expected)) : nil
        }
        return TransferSnapshot(received:active?.received ?? 0,expected:expected,
            isEstimated:active?.isEstimated ?? false,fraction:fraction,
            bytesPerSecond:Double(bytes)/max(0.25,min(2,now-start)))
    }
    private func prune(_ now:TimeInterval) {
        entries=entries.filter{now-$0.value.updated<60 && (!$0.value.finished || now-$0.value.updated<2)}
        if entries.count>=512 { for key in entries.sorted(by:{$0.value.updated<$1.value.updated}).prefix(entries.count-511).map(\.key) { entries.removeValue(forKey:key) } }
    }
}
