import SwiftUI
import Observation
import ErosCore
import ErosServices

@MainActor struct NativeClipboardProvider:ClipboardLinkProvider {
    func snapshot() async -> ClipboardLinkSnapshot {
        let board=UIPasteboard.general;let before=board.changeCount
        let value:String?
        if board.hasStrings {value=board.string}
        else if board.hasURLs {value=board.url?.absoluteString}
        else {value=nil}
        return ClipboardLinkSnapshot(text:value,changed:board.changeCount != before)
    }
}
@MainActor private enum NativeLinkResolution {
    case detail(GalleryRequest,LinkBrowseContext?)
}
/// One source-owned action shared by comments, clipboard, manual and system URLs.
@MainActor @Observable final class NativeLinkOpeningModel {
    private let online:OnlineLibraryModel
    private let navigation:NativeNavigationModel
    private let tab:Int
    private let coordinator=LinkOpenCoordinator<NativeLinkResolution>()
    private var intent:NavigationIntentGate.Ticket?
    private var retryTarget:ExternalLinkTarget?
    private(set) var message:String?
    var busy:Bool {coordinator.busy}
    init(online:OnlineLibraryModel,navigation:NativeNavigationModel,tab:Int) {
        self.online=online;self.navigation=navigation;self.tab=tab
    }
    func cancel() {
        coordinator.cancel()
        if let intent {navigation.cancel(intent)}
        intent=nil;message=nil;retryTarget=nil
    }
    private func current(_ ticket:NavigationIntentGate.Ticket,_ scope:SessionScope) -> Bool {
        !PrivacyController.shared.locked && online.state?.scope==scope && online.canRequestNetwork && navigation.current(ticket,scope:scope)
    }
    private func begin() -> (NavigationIntentGate.Ticket,SessionScope)? {
        guard !busy else{return nil}
        cancel()
        guard let scope=online.state?.scope,online.canRequestNetwork,
              let ticket=navigation.begin(tab:tab,scope:scope) else {
            message="当前会话尚未准备好，请完成验证后重试。";return nil
        }
        intent=ticket;return (ticket,scope)
    }
    func url(_ value:String) {
        guard !busy else{return}
        cancel()
        let target:ExternalLinkTarget
        do {target=try ExternalLinkParser.parse(value)}
        catch {message="链接无效，仅支持完整EH/EX画廊或图片页面链接。";return}
        open(target)
    }
    func open(_ target:ExternalLinkTarget) {
        guard let (ticket,scope)=begin() else{return}
        retryTarget=target
        launch(ticket,scope) {try await self.resolve(target,ticket,scope)}
    }
    func retry() {if let retryTarget {open(retryTarget)}}
    var canRetry:Bool {retryTarget != nil && !busy && message != nil}
    private func launch(_ ticket:NavigationIntentGate.Ticket,_ scope:SessionScope,
                        resolve:@escaping @MainActor () async throws -> NativeLinkResolution) {
        coordinator.start(resolve:resolve,current:{self.current(ticket,scope)},commit:{value in
            switch value {
            case .detail(let request,let context):
                _=self.navigation.finish(ticket,scope:scope,route:.detail(GalleryDetailRoute(reference: request.reference, scope: request.scope)),context:context)
                self.intent=nil;self.message=nil;self.retryTarget=nil
            }
        },failed:{error in
            self.message="无法打开链接，请检查目标站点权限和网络后重试。原页面已保留。"
        })
    }
    private func resolve(_ target:ExternalLinkTarget,_ ticket:NavigationIntentGate.Ticket,_ origin:SessionScope) async throws -> NativeLinkResolution {
        retryTarget=target
        guard current(ticket,origin),let base=online.services else{throw CancellationError()}
        let context:LinkBrowseContext?;let services:AppContainer;let scope:SessionScope
        if target.site==origin.storage.site {context=nil;services=base;scope=origin}
        else if let existing=navigation.contexts.values.first(where:{$0.origin==origin && $0.scope.storage.site==target.site}),
                (try? await existing.services.sessions.current().scope)==existing.scope {
            context=existing;services=existing.services;scope=existing.scope
        } else {
            let session=try await online.sessions.readSession(site:target.site)
            let state=try await session.current()
            try Task.checkCancellation();guard current(ticket,origin) else{throw CancellationError()}
            let value=LinkBrowseContext(origin:origin,scope:state.scope,sessions:session,base:base)
            context=value;services=value.services;scope=state.scope
        }
        try Task.checkCancellation();guard current(ticket,origin) else{throw CancellationError()}
        let detail=try await ExternalLinkResolver(client:services.client,sessions:services.sessions).resolveDetail(target,scope:scope)
        try Task.checkCancellation();guard current(ticket,origin) else{throw CancellationError()}
        return .detail(detail,context)
    }
}

struct LinkOpeningFeedback:View {
    let model:NativeLinkOpeningModel
    var body:some View {
        if model.busy || model.message != nil {
            VStack(alignment:.leading,spacing:8) {
                if model.busy {
                    HStack {ProgressView();Text("正在打开链接…");Spacer();Button("取消"){model.cancel()}}
                }
                if let message=model.message {Text(message).font(.footnote).foregroundStyle(.secondary)}
                if !model.busy {
                    ViewThatFits(in:.horizontal) {
                        HStack {recoveryButtons}.fixedSize(horizontal:true,vertical:false)
                        VStack(alignment:.leading,spacing:8) {recoveryButtons}
                    }.font(.footnote)
                }
            }.padding().background(.regularMaterial).buttonStyle(.borderless)
        }
    }
    @ViewBuilder private var recoveryButtons:some View {
        if model.canRetry {Button("重试"){model.retry()}}
        Button("关闭"){model.cancel()}
    }
}
private struct OpenGalleryLinkKey:EnvironmentKey {
    static let defaultValue:@MainActor @Sendable (URL) -> Void={_ in}
}
extension EnvironmentValues {
    var openGalleryLink:@MainActor @Sendable (URL) -> Void {
        get{self[OpenGalleryLinkKey.self]}
        set{self[OpenGalleryLinkKey.self]=newValue}
    }
}
