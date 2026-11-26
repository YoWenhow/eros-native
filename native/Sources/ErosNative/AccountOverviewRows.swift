import SwiftUI
import ErosCore
import ErosServices

struct AccountOverviewRows: View {
    let service: AccountOverviewService
    let scope: SessionScope?
    @State private var quota: ImageQuota?
    @State private var assets: AccountAssets?
    @State private var readingQuota = false
    @State private var readingAssets = false
    @State private var resetting = false
    @State private var unconfirmed = false
    @State private var showReset = false
    @State private var showAcknowledgement = false
    @State private var confirmedCost: Int?
    @State private var message: String?

    var body: some View {
        Group {
            Button(action: quotaTapped) {
                LabeledContent("图片配额", value: quotaText)
            }
            .disabled(scope == nil || resetting || readingQuota)
            Button {
                if let scope { Task { await loadAssets(scope) } }
            } label: {
                LabeledContent("资产总量") {
                    if let assets {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(assets.credits.formatted()) Credits")
                            Text("\(assets.kiloGP.formatted()) kGP")
                            Text("\(assets.hath.formatted()) Hath")
                        }
                        .monospacedDigit()
                    } else {
                        Text(readingAssets ? "读取中…" : (scope == nil ? "验证账号后查看" : "轻点重试"))
                    }
                }
            }
            .disabled(scope == nil || readingAssets)
            if unconfirmed {
                Button("我已核对上次重置") { showAcknowledgement = true }
                    .disabled(resetting)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task(id: scope) {
            guard let scope else { return }
            async let limits: () = loadQuota(scope)
            async let balances: () = loadAssets(scope)
            _ = await (limits, balances)
        }
        .alert("重置图片配额？", isPresented: $showReset, presenting: confirmedCost) { cost in
            Button("取消", role: .cancel) {}
            Button("确认重置", role: .destructive) {
                if let scope { Task { await reset(scope, cost: cost) } }
            }
        } message: { cost in
            Text("将扣除 \(cost.formatted()) GP，并重置本账号的图片用量。")
        }
        .alert("标记为已核对？", isPresented: $showAcknowledgement) {
            Button("取消", role: .cancel) {}
            Button("标记已核对") {
                if let scope { Task { await acknowledge(scope) } }
            }
        } message: {
            Text("请先在网站核对用量和 GP 余额。标记后可以重新发起重置。")
        }
    }

    private var quotaText: String {
        if resetting { return "重置中…" }
        if let quota { return "\(quota.used.formatted()) / \(quota.limit.formatted())" }
        if readingQuota { return "读取中…" }
        return scope == nil ? "验证账号后查看" : "轻点重试"
    }

    private func quotaTapped() {
        guard let scope else { return }
        if unconfirmed || quota == nil {
            Task { await loadQuota(scope) }
        } else if let quota, quota.used > 0, let cost = quota.resetCostGP {
            confirmedCost = cost
            showReset = true
        } else {
            message = quota?.used == 0 ? "当前图片用量为 0。" : "网站当前未提供重置选项。"
        }
    }

    private func loadQuota(_ scope: SessionScope, keepMessage: Bool = false) async {
        guard !readingQuota else { return }
        readingQuota = true
        defer { readingQuota = false }
        do {
            let status = try await service.quota(scope: scope)
            guard !Task.isCancelled else { return }
            quota = status.quota
            unconfirmed = status.resetUnconfirmed
            if unconfirmed { message = "上次重置结果未确认。请先核对网站用量和 GP 余额。" }
            else if !keepMessage { message = nil }
        } catch is CancellationError {
        } catch AppError.staleSession {
        } catch {
            if !keepMessage { message = "暂时无法读取图片配额，轻点重试。" }
        }
    }

    private func loadAssets(_ scope: SessionScope) async {
        guard !readingAssets else { return }
        readingAssets = true
        defer { readingAssets = false }
        if let value = try? await service.assets(scope: scope), !Task.isCancelled { assets = value }
    }

    private func reset(_ scope: SessionScope, cost: Int) async {
        guard !resetting else { return }
        resetting = true
        defer { resetting = false }
        do {
            quota = try await service.resetQuota(scope: scope, confirmedCost: cost)
            message = "图片配额已重置。"
            await loadAssets(scope)
        } catch QuotaResetError.quoteChanged {
            message = "网站的用量或费用已变化，请核对后重新确认。"
            await loadQuota(scope, keepMessage: true)
        } catch QuotaResetError.unconfirmed {
            unconfirmed = true
            message = "重置结果未确认。请先核对网站用量和 GP 余额。"
        } catch {
            message = "无法发起重置，请检查账号状态后重试。"
        }
    }

    private func acknowledge(_ scope: SessionScope) async {
        do {
            try await service.acknowledgeUnconfirmedReset(scope: scope)
            unconfirmed = false
            await loadQuota(scope)
        } catch {
            message = "暂时无法记录核对结果。"
        }
    }
}
