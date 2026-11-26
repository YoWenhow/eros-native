import SwiftUI
import UIKit
import ErosCore
import ErosServices

/// Opt-in, numeric-only diagnostic counters. Cache cost is NOT process RSS.
@MainActor final class PerformanceProbe: ObservableObject {
    static let shared = PerformanceProbe()
    private var started: Date?
    private var ended: Date?
    private var startedUptime: TimeInterval?
    private var endedUptime: TimeInterval?
    var hasSession: Bool { started != nil }
    var elapsedSeconds: TimeInterval {
        guard let startedUptime else { return 0 }
        return max(0, (endedUptime ?? ProcessInfo.processInfo.systemUptime) - startedUptime)
    }
    var elapsedText: String {
        let seconds = Int(elapsedSeconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var selectedPageCount: Int { selectedFixturePages.count }
    private var phaseEpoch = 0
    private var selectedFixturePages: Set<Int> = []
    private var ticks: Task<Void, Never>?
    private var values: [String: Double] = [:]
    private var currentCaches: [UUID: Int] = [:]
    @Published private(set) var running = false
    func begin() {
        ticks?.cancel(); values = [:]; currentCaches = [:]; started = Date(); ended = nil; startedUptime = ProcessInfo.processInfo.systemUptime; endedUptime = nil; selectedFixturePages = []; running = true
        ticks = Task { [weak self] in
            var last = ProcessInfo.processInfo.systemUptime
            var wasActive = UIApplication.shared.applicationState == .active
            while !Task.isCancelled {
                let epoch = self?.phaseEpoch
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let active = UIApplication.shared.applicationState == .active
                // Exclude suspension and one return-to-foreground sample.
                if active && wasActive && epoch == self.phaseEpoch {
                    self.values["foregroundTimerSamples", default: 0] += 1
                    self.values["maxForegroundTimerLatenessMs"] = max(self.values["maxForegroundTimerLatenessMs", default: 0], max(0, now - last - 0.5) * 1000)
                }
                last = now; wasActive = active
            }
        }
    }
    func stop() { ticks?.cancel(); ticks = nil; if running { ended = Date(); endedUptime = ProcessInfo.processInfo.systemUptime }; running = false }
    func phaseChanged() { phaseEpoch += 1 }
    func selectedFixturePage(_ index: Int) {
        guard running, (0..<120).contains(index) else { return }
        selectedFixturePages.insert(index); values["uniqueSelectedFixturePages"] = Double(selectedFixturePages.count)
    }
    func cache(_ id: UUID, cost: Int, count: Int) {
        guard running else { return }
        currentCaches[id] = cost
        values["currentDecodedCacheBytes"] = Double(currentCaches.values.reduce(0,+))
        values["peakDecodedCacheBytes"] = max(values["peakDecodedCacheBytes", default: 0], values["currentDecodedCacheBytes", default: 0])
        values["peakSingleReaderCacheCount"] = max(values["peakSingleReaderCacheCount", default: 0], Double(count))
    }
    func release(_ id: UUID) { currentCaches.removeValue(forKey: id); if running { values["currentDecodedCacheBytes"] = Double(currentCaches.values.reduce(0,+)) } }
    func hit(_ found: Bool) { guard running else { return }; values[found ? "cacheHits" : "cacheMisses", default: 0] += 1 }
    func decoded(milliseconds: Double) {
        guard running else { return }
        values["decodedImages", default: 0] += 1
        values["decodeTotalMs", default: 0] += milliseconds
        values["maxDecodeIncludingQueueMs"] = max(values["maxDecodeIncludingQueueMs", default: 0], milliseconds)
    }
    func memoryWarning() { if running { values["memoryWarningSignals", default: 0] += 1 } }
    func export() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eros-performance.json")
        let object: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?", "startedUTC": started.map { ISO8601DateFormatter().string(from: $0) } ?? "NOT_RUN", "elapsedSeconds": elapsedSeconds, "running": running, "counters": values, "limits": ["decodedCacheMiBPerReader": 96, "decodedCacheCount": 12], "notMeasured": ["processRSS", "GPU", "FPS", "coldStartFirstFrame", "cachedPageVisibleLatency"], "notes": "Cache excludes visible image references and in-flight decoder allocations. Timer lateness is not frame time. Memory-warning button is an injected signal, not OS pressure."]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        return url
    }
}

struct StressGalleryRepository: GalleryRepository {
    static let reference = GalleryReference(key: GalleryKey(site: .eh, galleryID: try! GalleryID(300)), token: try! SensitiveText("stressfixture"))
    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func detail(request: GalleryRequest) throws -> GalleryDetail {
        try GalleryDetail(summary: GallerySummary(reference: request.reference, title: "本地压力样本 120 页", pageCount: NonnegativeCount(120)), tags: [])
    }
    func thumbnails(request: ReaderPagesRequest) throws -> PagedResult<GalleryThumbnail> { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) throws -> PagedResult<ReaderPage> {
        try PagedResult(items: (0..<120).map { try ReaderPage(reference: request.reference, index: PageIndex($0), pageURL: URL(string: "https://stress.example.invalid/page/\($0)")!) }, context: request.context)
    }
}
actor StressImageSource {
    static let shared = StressImageSource()
    func load(index: PageIndex, slow: Bool) async throws -> Data {
        if slow { try await Task.sleep(for: .milliseconds(800)) }
        try Task.checkCancellation()
        guard let root = Bundle.module.url(forResource: "PerformanceFixtures", withExtension: nil) else { throw AppError.notFound }
        return try Data(contentsOf: root.appendingPathComponent("page\(index.value % 3).png"))
    }
}
struct PerformanceAcceptanceView: View {
    let services: AppContainer
    let scope: SessionScope
    @ObservedObject private var probe = PerformanceProbe.shared
    @State private var confirmRestart = false
    @State private var slow = false
    @State private var route: ReadingMode?
    @State private var report: URL?
    @State private var message = "尚未开始"
    var body: some View {
        List {
            Section("T30 本地压力验收") {
                Text("120页固定中性色带，包含普通图、大图和长图；不访问网络。沿用真实阅读器、解码和缓存路径。")
                Toggle("模拟慢读取（每页800毫秒）", isOn: $slow)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本轮计时：" + probe.elapsedText).monospacedDigit()
                        Text("已选中过 \(probe.selectedPageCount) / 120 页").monospacedDigit()
                        Text(probe.running ? "计数中（包含切后台及锁屏时间）" : (probe.hasSession ? "已停止，计时已固定" : "尚未开始计数")).font(.footnote).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                Button("开始新一轮计数") {
                    if probe.hasSession { confirmRestart = true } else { beginRound() }
                }
                Button("打开单页样本") { route = .leftToRight }
                Button("打开连续纵向样本") { route = .vertical }
                Text(message)
            }
            Section("报告") {
                Button("停止计数并生成报告") {
                    probe.stop()
                    do { report = try probe.export(); message = "报告已生成。缓存字节不是进程总内存；未测量项目已单列。" }
                    catch { message = "报告生成失败，请重试。" }
                }
                if let report { ShareLink("导出性能 JSON", item: report) }
                Text("在样本阅读页的阅读选项中可注入内存警告。它只触发缓存回收，不消耗内存制造系统压力。真实下载并行可在另一Tab中使用现有小任务。")
            }
        }.navigationTitle("性能与恢复验收")
            .confirmationDialog("确定开始新一轮？", isPresented: $confirmRestart, titleVisibility: .visible) {
                Button("清空当前计数并重新开始", role: .destructive) { beginRound() }
                Button("取消，保留本轮", role: .cancel) {}
            } message: {
                Text("当前计时和计数将清空。若还未导出，请先取消，点击“停止计数并生成报告”并导出 JSON。")
            }
            .navigationDestination(isPresented: Binding(get: { route != nil }, set: { if !$0 { route = nil } })) {
                if let route { OnlineReaderView(stressServices: services, scope: scope, mode: route, slow: slow) }
            }
    }
    private func beginRound() {
        probe.begin(); report = nil; message = "计数已开启；退出阅读后生成报告。"
    }

}
