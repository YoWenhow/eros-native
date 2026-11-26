import SwiftUI
import UniformTypeIdentifiers
import ErosCore
import ErosPersistence
import ErosServices

struct StorageMaintenanceTools: View {
    @ObservedObject var model: OnlineLibraryModel
    @State private var scope: VerifiedCopyScope = .downloadFolders
    @State private var selection: FileSelection?
    @State private var choosing = false
    @State private var message: String?
    @State private var pending: [String] = []
    @State private var findings: [DownloadFileFinding] = []

    private enum FileSelection {
        case copy(VerifiedCopyScope)
        case page(DownloadFileFinding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("校验副本范围", selection: $scope) {
                ForEach(VerifiedCopyScope.allCases) { scope in
                    Label(scope.title, systemImage: scope.menuSymbol).tag(scope)
                }
            }
            Button("生成当前账号的校验副本") { Task { await publishCopy() } }
            Button("选择校验副本并导入") { choose(.copy(scope)) }
            if !pending.isEmpty {
                DisclosureGroup("\(pending.count) 项待处理") {
                    ForEach(Array(pending.enumerated()), id: \.offset) { item in
                        Text(item.element).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if model.canReviewPublicDownloads {
                Divider()
                Button("核对公开下载文件") { Task { await reviewDownloads() } }
                ForEach(findings) { finding in findingRow(finding) }
            }
            if model.maintenanceBusy { ProgressView().accessibilityLabel("正在校验存储资料") }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .disabled(model.maintenanceBusy)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data]) { result in
            guard let selection else { return }
            self.selection = nil
            Task { await accept(result, selection: selection) }
        }
    }

    private func findingRow(_ finding: DownloadFileFinding) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(finding.site.rawValue.uppercased()) \(finding.galleryID.value) · \(finding.filenameLabel)")
            Text(finding.issueLabel).font(.footnote).foregroundStyle(.secondary)
            switch (finding.issue, finding.index) {
            case (.missing, .some):
                if let renamed = finding.renamedFile {
                    Button("把 \(renamed.lastPathComponent) 复制回原位") { Task { await restore(finding, from: renamed) } }
                }
                Button(finding.ambiguous ? "选择同摘要的原页" : "选择原页文件") { choose(.page(finding)) }
            case (.missing, .none):
                Button("校验整组并恢复收据") { Task { await restore(finding, from: nil) } }
            default: EmptyView()
            }
        }
        .padding(.vertical, 3)
    }

    private func choose(_ selection: FileSelection) {
        self.selection = selection
        choosing = true
    }

    private func publishCopy() async {
        let selected = scope
        pending = []
        do {
            let header = try await model.withClosedStorage { owner in
                try await model.storageCopies.publish(scope: selected, owner: owner)
            }
            message = "校验副本已发布到文稿的 ErosLibrary/Databases，共 \(header.rowCount) 条记录。"
        } catch StorageDocumentError.invalidFile {
            message = "校验副本未通过检查，文件未发布。"
        } catch { present(error) }
    }

    private func accept(_ result: Result<URL, any Error>, selection: FileSelection) async {
        do {
            let file = try result.get()
            switch selection {
            case .copy(let scope):
                pending = []
                let result = try await model.withClosedStorage { owner in
                    try await model.storageCopies.restore(from: file, scope: scope, owner: owner)
                }
                pending = result.pending
                message = "已补回 \(result.inserted) 项，\(result.pending.count) 项待处理。"
            case .page(let finding):
                await restore(finding, from: file)
            }
        } catch { present(error) }
    }

    private func reviewDownloads() async {
        do {
            findings = try await model.withClosedStorage { owner in
                try await model.downloadReconciliation.review(owner: owner)
            }
            message = findings.isEmpty ? "已核对当前账号的正式下载。" : "有 \(findings.count) 个文件需要处理。"
        } catch { present(error) }
    }

    private func restore(_ finding: DownloadFileFinding, from file: URL?) async {
        do {
            try await model.withClosedStorage { owner in
                try await model.downloadReconciliation.restore(finding, from: file, owner: owner)
            }
            findings.removeAll { $0.id == finding.id }
            message = "已核验并恢复所选文件。"
        } catch { present(error) }
    }

    private func present(_ error: any Error) {
        if error is CancellationError || (error as? CocoaError)?.code == .userCancelled { return }
        message = switch error {
        case StorageDocumentError.unregisteredCopy: "文件摘要与本机登记的校验副本不匹配。"
        case StorageDocumentError.wrongOwner: "该副本属于其他账号。"
        case StorageDocumentError.wrongScope: "该副本的资料范围与选择不匹配。"
        case StorageDocumentError.destinationOccupied: "原位置已有文件，请移走该文件后重新核对。"
        case StorageDocumentError.invalidFile: "原件或归档整组未通过校验。"
        case StorageMaintenanceError.downloadRootUnavailable: "请放回原公开下载目录后重试。"
        default: "操作暂未完成，请确认资料可读取后重试。"
        }
    }
}

private extension VerifiedCopyScope {
    var menuSymbol: String {
        switch self {
        case .downloadFolders: "folder"
        case .localRules: "hand.raised"
        case .imageBlocks: "photo"
        case .translations: "character.bubble"
        }
    }

    var title: String {
        switch self {
        case .downloadFolders: "下载分组"
        case .localRules: "本地规则"
        case .imageBlocks: "图像屏蔽"
        case .translations: "标签词库"
        }
    }
}

private extension DownloadFileFinding {
    var filenameLabel: String { index.map { "第 \($0 + 1) 页" } ?? "归档收据" }
    var issueLabel: String {
        switch issue {
        case .missing: ambiguous ? "缺失，发现多份可能的原件" : "缺失"
        case .changed: "文件已变化，请移开后重新核对"
        case .unverifiable: "缺少可验证的原页摘要"
        }
    }
}
