import SwiftUI
import ErosCore
import ErosNetworking

@MainActor
final class NetworkAcceptanceModel: ObservableObject {
    @Published var success = "NOT_RUN"
    @Published var failure = "NOT_RUN"
    @Published var busy = false
    private var operation: Task<Void,Never>?
    func start() {
        guard !busy else { return };busy = true
        operation = Task {
            defer { busy = false;operation = nil }
            let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()),site: .eh),generation: 1)
            let policy = NetworkPolicy(parsing: ParsingPolicy(ehHost: "www.apple.com"))
            let client = HTTPClient(transport: URLSessionTransport(policy: policy),policy: policy)
            let request = HTTPRequest(id: UUID(),scope: scope,url: URL(string: "https://www.apple.com/library/test/success.html")!,method: .get,headers: ["Accept":"text/html"])
            success = "RUNNING"
            do {
                let result = try await client.send(request,expecting: .html)
                let text = String(decoding: result.body,as: UTF8.self)
                success = text.contains("Success") && result.body.count < 65536 ? "PASS · HTTP 200，公开小页面匹配，\(result.body.count) bytes" : "FAIL · 页面内容不匹配"
            } catch is CancellationError { success = "CANCELLED";return }
            catch let error as AppError { success = "FAIL · \(Self.label(error))" }
            catch { success = "FAIL · 未知错误" }
            guard !Task.isCancelled else { return }
            failure = "RUNNING"
            let invalidPolicy = NetworkPolicy(parsing: ParsingPolicy(ehHost: "example.invalid"))
            let invalid = HTTPRequest(id: UUID(),scope: scope,url: URL(string: "https://example.invalid/")!,method: .get,headers: ["Accept":"text/html"])
            do {
                _ = try await HTTPClient(transport: URLSessionTransport(policy: invalidPolicy),policy: invalidPolicy).send(invalid,expecting: .html)
                failure = "FAIL · 无效域名意外成功"
            } catch is CancellationError { failure = "CANCELLED" }
            catch let error as AppError {
                if case .transport = error { failure = "PASS · \(Self.label(error))；未崩溃，可重试" }
                else { failure = "FAIL · \(Self.label(error))" }
            } catch { failure = "FAIL · 未知错误" }
        }
    }
    func cancel() { operation?.cancel() }
    static func label(_ error: AppError) -> String {
        switch error {
        case .transport(let code): "网络错误 code=\(code)"
        case .httpStatus(let code): "HTTP \(code)"
        case .authenticationRequired: "需要认证"
        case .accessDenied: "访问或跳转被拒绝"
        case .rateLimited: "限流"
        case .quotaExceeded: "配额不足"
        case .unsupportedContent: "响应类型不匹配"
        default: "响应校验失败"
        }
    }
}

struct NetworkAcceptanceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = NetworkAcceptanceModel()
    var body: some View {
        NavigationStack {
            List {
                Section("公开 HTTPS 小请求") { Text(model.success) }
                Section("预期网络失败") { Text(model.failure) }
                Section {
                    Button("运行两项检查") { model.start() }.disabled(model.busy)
                    Button("取消") { model.cancel() }.disabled(!model.busy)
                } footer: { Text("访问 Apple 公开连通性小页面及保留的无效域名。使用 T15 网络层，不携带 Cookie/账号，不记录正文。错误分类与重试上限另有离线测试；此页不代表业务站点已登录。") }
            }
            .navigationTitle("T15 网络验收")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .onDisappear { model.cancel() }
        }
    }
}
