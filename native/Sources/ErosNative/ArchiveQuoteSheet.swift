import SwiftUI
import ErosCore
import ErosServices

struct ArchiveQuoteSheet: View {
    let services: AppContainer
    let request: GalleryRequest
    let summary: GallerySummary
    let metadata: DownloadLibraryMetadata
    @Environment(\.dismiss) private var dismiss
    @State private var offers:[ArchiveOffer]=[]
    @State private var operations:[DownloadVariant:ArchiveOperation]=[:]
    @State private var loading=true
    @State private var busy=false
    @State private var message:String?
    @State private var reload=UUID()
    @State private var confirmation: Confirmation?
    @State private var folders:[DownloadFolder]=[]
    @State private var destinationFolderID:DownloadFolderID?
    @State private var destinationLoaded = false

    private var selectedFolderMissing: Bool {
        destinationFolderID.map { id in !folders.contains { $0.id == id } } ?? false
    }

    private enum Confirmation {
        case create(ArchiveOffer)
        case stopWaiting(DownloadVariant)

        var title: String {
            switch self {
            case .create(let offer):
                offer.variant == .original ? "创建原始档案？" : "创建重采样档案？"
            case .stopWaiting:
                "停止本地等待？"
            }
        }
    }

    var body:some View {
        NavigationStack {
            List {
                if loading { ProgressView().frame(maxWidth:.infinity).listRowBackground(Color.clear) }
                if let message { Text(message).foregroundStyle(.secondary) }
                ForEach(offers,id:\.variant) { offer in offerRow(offer) }
                ForEach([DownloadVariant.display,.original],id:\.self) { variant in
                    if !offers.contains(where:{$0.variant == variant}),let operation=operations[variant] {
                        VStack(alignment:.leading,spacing:8) {
                            Text(variant == .original ? "原始档案" : "重采样档案")
                            Text(statusText(operation)).font(.footnote).foregroundStyle(.secondary)
                            if operation.state == .waiting {
                                waitingActions(variant)
                            } else {
                                downloadAction(operation, variant:variant)
                            }
                        }.padding(.vertical,4)
                    }
                }
                if services.archiveOperations == nil && !offers.isEmpty {
                    Text("本机档案操作记录不可用，请稍后重试。").font(.footnote).foregroundStyle(.secondary)
                }
                if !offers.isEmpty {
                    Text("创建前会重新核对价格。档案准备就绪后，点“下载归档”会在下载页建立任务；完成校验和导入后即可离线阅读。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if operations.values.contains(where:{$0.state == .ready || $0.downloadJobID != nil}) {
                    Section("保存到文件夹") {
                        DownloadFolderChoices(folders: folders, selection: destinationFolderID) {
                            destinationFolderID = $0
                        }
                        .disabled(busy || loading)
                        if selectedFolderMissing {
                            Text("所选文件夹已失效，请重新选择").foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("归档下载").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) }
                ToolbarItem(placement:.confirmationAction) { Button("刷新") { reload=UUID() }.disabled(loading || busy) }
            }
            .task(id:reload) { await load() }
            .alert(confirmation?.title ?? "", item: $confirmation) { action in
                switch action {
                case .create(let offer):
                    Button("确认创建") { Task { await create(offer) } }
                case .stopWaiting(let variant):
                    Button("停止本地等待", role: .destructive) { Task { await cancel(variant) } }
                }
                Button("取消", role: .cancel) {}
            } message: { action in
                switch action {
                case .create(let offer):
                    Text("网站当前报价：\(offer.priceLabel)。创建前会重新核对；如报价变化，将停止并要求重新确认。创建可能消耗网站额度。")
                case .stopWaiting:
                    Text("这会清除本机保存的准备地址，之后无法在应用内继续核对。网站任务与可能产生的费用不会撤销。")
                }
            }
            .interactiveDismissDisabled(busy)
        }.presentationDetents([.medium,.large])
    }
    @ViewBuilder private func offerRow(_ offer:ArchiveOffer)->some View {
        VStack(alignment:.leading,spacing:9) {
            Text(offer.variant == .original ? "原始档案" : "重采样档案")
            HStack {
                Text(offer.quote.price.isKnown ? offer.priceLabel : "价格未知")
                    .foregroundStyle(offer.quote.price.isKnown ? Color.primary : Color.secondary)
                Spacer()
                Text(offer.quote.sizeLabel).foregroundStyle(.secondary)
            }.font(.subheadline)
            if let operation=operations[offer.variant] {
                Text(statusText(operation)).font(.footnote).foregroundStyle(.secondary)
                if operation.state == .waiting {
                    waitingActions(offer.variant)
                } else if operation.state == .ready || operation.downloadJobID != nil {
                    downloadAction(operation,variant:offer.variant)
                } else if [.creationUnknown,.paused,.failed,.cancelled].contains(operation.state) {
                    Link("在网站核对",destination:offer.action).font(.footnote)
                }
            } else {
                Button("创建档案") { confirmation = .create(offer) }
                    .disabled(busy || loading || !offer.quote.price.isKnown || services.archiveOperations == nil)
            }
        }.padding(.vertical,4)
    }
    private func waitingActions(_ variant:DownloadVariant)->some View {
        HStack {
            Button("核对准备状态") { Task { await poll(variant) } }.disabled(busy || loading)
            Spacer()
            Button("停止本地等待") { confirmation = .stopWaiting(variant) }.disabled(busy || loading)
        }.font(.footnote)
    }
    @ViewBuilder private func downloadAction(_ operation:ArchiveOperation,variant:DownloadVariant)->some View {
        if operation.state == .ready || operation.downloadJobID != nil && [.paused,.completed].contains(operation.state) {
            Button(operation.state == .completed ? "核对本机归档 / 重新获取" : "下载归档") {
                Task { await startDownload(variant) }
            }.disabled(busy || loading || !destinationLoaded || services.archiveOperations == nil ||
                (operation.downloadJobID == nil && selectedFolderMissing))
                .font(.footnote)
        }
    }
    private func statusText(_ operation:ArchiveOperation)->String {
        switch operation.state {
        case .waiting: "服务器正在准备档案，请稍后核对。"
        case .ready: "服务器已准备好档案；尚未保存在本机。"
        case .transferring: "下载页正在获取归档文件；尚不能离线阅读。"
        case .verifying,.extracting: "下载页正在校验并导入图片；尚不能离线阅读。"
        case .completed: "本机档案已校验完成，可在下载库离线阅读。"
        case .creating,.creationUnknown: "创建结果尚未确认，请在网站核对；不会自动重新提交。"
        case .paused: operation.downloadJobID == nil ? "本次等待已中断，需在网站核对。" : "本机下载已中断；可从同一档案操作重新获取文件。"
        case .failed: "网站未确认档案可用，请查看网站状态。"
        case .cancelled: "本地等待已停止；网站已有操作和可能产生的费用未撤销。"
        default: "档案操作已记录，请核对网站状态。"
        }
    }
    private func load() async {
        loading=true; message=nil; offers=[]
        defer { if !Task.isCancelled { loading=false } }
        do {
            var found:[DownloadVariant:ArchiveOperation]=[:]
            if let service=services.archiveOperations {
                for variant in [DownloadVariant.display,.original] {
                    if let operation=try await service.status(request:request,variant:variant) { found[variant]=operation }
                }
            }
            try Task.checkCancellation()
            operations=found
            let account = request.scope.storage.accountID
            let latestFolders = try await services.database.listFolders(account: account)
            let initialDefault = destinationLoaded ? nil : try await services.database.loadDefaultFolder(account: account)
            try Task.checkCancellation()
            guard try await services.sessions.current().scope == request.scope else { throw AppError.staleSession }
            try Task.checkCancellation()
            folders = latestFolders
            if !destinationLoaded {
                destinationFolderID = DownloadFolderPreferences.shared.initialFolderID(
                    defaultFolderID: initialDefault, folders: latestFolders, account: account)
                destinationLoaded = true
            }
            // D10: never silently redirect an already-open destination after
            // deletion. Keep its invalid selection visible until the user chooses.
            let fresh=try await ArchiveQuoteService(client:services.client,sessions:services.sessions).read(request)
            try Task.checkCancellation()
            offers=fresh
        } catch is CancellationError {}
        catch AppError.cancelled {}
        catch AppError.staleSession { message="会话已变化，请关闭后重新打开。" }
        catch AppError.authenticationRequired { message="请登录并启用在线访问后查看报价。" }
        catch AppError.quotaExceeded { message="网站提示额度不足，暂时无法获取报价。" }
        catch AppError.accessDenied { message="网站暂不允许访问归档下载报价。" }
        catch AppError.parseMismatch { message="暂时无法识别归档下载报价，请稍后刷新。" }
        catch { message="报价请求失败，请稍后刷新。" }
    }
    private func create(_ offer:ArchiveOffer) async {
        guard !busy,let service=services.archiveOperations else {return}
        busy=true; message=nil;defer {busy=false}
        do {
            let operation=try await service.create(confirmed:offer,request:request)
            operations[offer.variant]=operation
            if operation.state == .waiting { message="创建请求已提交，服务器仍在准备；稍后可核对状态。" }
        } catch ArchiveContractError.quoteChanged {
            await load(); message="报价已变化，请按新价格重新确认。"
        } catch ArchiveContractError.expired {
            await load(); message="报价已过期，请按新价格重新确认。"
        } catch ArchiveContractError.pollNotDue { message="服务器仍在准备，请稍后重试。" }
        catch AppError.staleSession { message="会话已变化，请重新打开。" }
        catch AppError.authenticationRequired { message="请先登录并启用在线访问。" }
        catch {
            operations[offer.variant]=try? await service.status(request:request,variant:offer.variant)
            message="创建结果暂无法确认，请在网站核对；应用不会自动再次提交。"
        }
    }
    private func poll(_ variant:DownloadVariant) async {
        guard !busy,let service=services.archiveOperations else {return}
        busy=true;message=nil;defer {busy=false}
        do {
            let operation=try await service.poll(request:request,variant:variant)
            operations[variant]=operation
            if operation.state == .waiting { message="尚未确认准备完成，请稍后再核对。" }
        } catch ArchiveContractError.pollNotDue { message="请等待服务器准备，稍后再试。" }
        catch { message="当前无法核对准备状态，请在网站查看。" }
    }
    private func cancel(_ variant:DownloadVariant) async {
        guard !busy,let service=services.archiveOperations else {return}
        busy=true;defer {busy=false}
        do { operations[variant]=try await service.cancelLocalWait(request:request,variant:variant) }
        catch { message="暂时无法停止本地等待，请稍后重试。" }
    }
    private func startDownload(_ variant:DownloadVariant) async {
        guard !busy, !loading, destinationLoaded, let operation = operations[variant],
              operation.downloadJobID != nil || !selectedFolderMissing,
              let service = services.archiveOperations else { return }
        busy=true;message=nil
        defer { busy=false }
        let folder = destinationFolderID
        do {
            let result = try await service.enqueueDownloadResult(request: request, summary: summary, variant: variant,
                destinationFolderID: folder, metadata: metadata)
            guard try await services.sessions.current().scope == request.scope else { throw AppError.staleSession }
            try Task.checkCancellation()
            if case .inserted = result {
                DownloadFolderPreferences.shared.remember(folder, account: request.scope.storage.accountID)
            }
            dismiss()
        } catch is CancellationError {
            message="建立任务已取消，请在下载页核对。"
        } catch AppError.staleSession { message="会话已变化，请重新打开后核对本机档案。" }
        catch AppError.storageFull {
            message="本机可用空间不足，未建立归档任务。"
        }
        catch DownloadLibraryError.folderNotFound {
            message="所选文件夹已删除，请刷新后重新选择保存位置。未自动改为未分组。"
        }
        catch {
            message="归档任务未能建立，请核对下载页；不会再次创建网站档案。"
        }
    }
}
