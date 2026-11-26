import ErosCore
public actor MyTagsChangeSignal {
    private var revisions:[AccountID:UInt64]=[:]
    public init() {}
    public func revision(scope:StorageScope)->UInt64 { revisions[scope.accountID] ?? 0 }
    public func confirmed(scope:StorageScope) { revisions[scope.accountID,default:0] += 1 }
}
