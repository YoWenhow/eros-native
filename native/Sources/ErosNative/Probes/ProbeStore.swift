#if DEBUG
import SwiftUI
import Foundation

struct ProbeResult: Codable {
    var status: String
    var detail: String
}

struct ProbeEvent: Codable, Identifiable {
    let id: UUID
    let time: Date
    let name: String
    let detail: String
}

@MainActor
final class ProbeStore: ObservableObject {
    static let shared = ProbeStore()
    static let names = ["Tab", "导航", "搜索", "Sheet", "Glass", "状态", "PNG资源", "URLSession", "网络错误处理", "WK本地页", "WKWebView", "Keychain", "SQLite", "生命周期", "日志导出"]
    @Published private(set) var results = Dictionary(uniqueKeysWithValues: names.map { ($0, ProbeResult(status: "NOT_RUN", detail: "待验证")) })
    @Published private(set) var events: [ProbeEvent] = []
    @Published private(set) var storageError: String?
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private let logURL: URL
    private var delegateStarted = false
    private var sawBackground = false

    func delegateLaunch() {
        delegateStarted = true
        event("UIApplicationDelegate", "didFinishLaunching")
    }

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            sawBackground = true
            event("scenePhase", "background")
        case .inactive: event("scenePhase", "inactive")
        case .active:
            event("scenePhase", "active")
            if sawBackground && delegateStarted {
                mark("生命周期", "PASS", "观察到 delegate 启动和 scenePhase background→active；不代表后台下载已验证")
            }
        @unknown default: event("scenePhase", "unknown")
        }
    }

    private init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("T07Diagnostics", isDirectory: true)
        logURL = directory.appendingPathComponent("events.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: logURL.path) {
                events = Array(try JSONDecoder().decode([ProbeEvent].self, from: Data(contentsOf: logURL)).suffix(200))
            }
        } catch { storageError = "诊断历史读取失败" }
        event("启动", "Build \(build)；结果表为本次启动，历史事件最多保留200条")
    }

    // Only pass controlled messages, never URLs, cookies, device identifiers, or raw errors.
    func event(_ name: String, _ detail: String) {
        events.append(ProbeEvent(id: UUID(), time: Date(), name: name, detail: detail))
        events = Array(events.suffix(200))
        do { try JSONEncoder().encode(events).write(to: logURL, options: .atomic) }
        catch { storageError = "诊断日志写入失败" }
    }

    func mark(_ name: String, _ status: String, _ detail: String) {
        results[name] = ProbeResult(status: status, detail: detail)
        event(name, "\(status)：\(detail)")
    }

    func export() -> URL? {
        mark("日志导出", "READY", "生成脱敏报告；实际分享完成后才记 PASS")
        struct Report: Encodable {
            let build: String
            let os: String
            let generated: Date
            let results: [String: ProbeResult]
            let events: [ProbeEvent]
            let storageError: String?
        }
        let url = logURL.deletingLastPathComponent().appendingPathComponent("ErosNative-T07.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let report = Report(build: build, os: ProcessInfo.processInfo.operatingSystemVersionString,
                                generated: Date(), results: results, events: events, storageError: storageError)
            try encoder.encode(report).write(to: url, options: .atomic)
            return url
        } catch {
            mark("日志导出", "FAIL", "报告文件写入失败")
            return nil
        }
    }
}
#endif
