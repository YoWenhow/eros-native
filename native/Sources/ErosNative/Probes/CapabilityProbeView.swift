#if DEBUG
import SwiftUI
import UIKit

struct CapabilityProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store = ProbeStore.shared
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            ProbeVisualView().tabItem { Label("玻璃与交互", systemImage: "sparkles") }.tag(0)
            ProbePlatformView().tabItem { Label("平台", systemImage: "checkmark.shield") }.tag(1)
            ProbeDiagnosticsView().tabItem { Label("诊断", systemImage: "list.bullet.rectangle") }.tag(2)
        }
        .onChange(of: tab) { _, _ in store.mark("Tab", "PASS", "用户切换系统标签页") }
        .onChange(of: scenePhase, initial: true) { _, phase in store.sceneChanged(phase) }
    }
}

struct ProbeVisualView: View {
    @State private var query = ""
    @State private var showSheet = false
    private let items = ["蓝色山丘", "绿色森林", "橙色海岸"]
    var body: some View {
        NavigationStack {
            List {
                Section("普通 PNG 资源") {
                    ProbeGlassView()
                }
                Section("导航") {
                    NavigationLink("进入详情并返回") { ProbeDetailView() }
                    Button("打开半屏 Sheet") { showSheet = true }
                }
                Section("搜索：输入“蓝”应只剩一项") {
                    ForEach(items.filter { query.isEmpty || $0.contains(query) }, id: \.self) { Text($0) }
                }
            }
            .navigationTitle("液态玻璃")
            .sheet(isPresented: $showSheet) {
                VStack(spacing: 24) {
                    Text("系统 Sheet").font(.title)
                    Text("观察背景材质、拖动手柄和按钮响应")
                    Button("关闭并记录通过") {
                        ProbeStore.shared.mark("Sheet", "PASS", "用户打开并通过按钮关闭 Sheet")
                        showSheet = false
                    }.buttonStyle(.borderedProminent)
                }
                .padding()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .searchable(text: $query, prompt: "输入 蓝")
            .onChange(of: query) { _, value in
                if value == "蓝" && items.filter({ $0.contains(value) }) == ["蓝色山丘"] {
                    ProbeStore.shared.mark("搜索", "PASS", "固定本地列表筛选：蓝 → 1项；未记录输入内容")
                }
            }
        }
    }
}

struct ProbeGlassView: View {
    @State private var count = 0
    @State private var confirmFailure = false
    @ObservedObject private var store = ProbeStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(spacing: 12) {
            Text("在图片区域上下滑动，观察固定玻璃控件下的背景变化。")
                .font(.caption)
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<3) { _ in ProbeImageView().frame(height: 240).clipped() }
                    }
                }
                GlassEffectContainer(spacing: 16) {
                    HStack(spacing: 16) {
                        Text("计数 \(count)")
                            .padding()
                            .glassEffect(.regular, in: Capsule())
                        Button("轻点 +1", systemImage: "plus") {
                            count += 1
                            ProbeStore.shared.mark("状态", "PASS", "玻璃按钮触发 SwiftUI 状态更新：\(count)")
                        }
                        .buttonStyle(.glass)
                    }
                }.padding()
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            Text(reduceTransparency ? "系统已开启降低透明度；记录真实效果，不强制关闭。" : "系统降低透明度：关闭")
                .font(.caption)
            Button("人工确认：材质可见、文字可读、按压正常") {
                ProbeStore.shared.mark("Glass", "PASS", "用户确认玻璃材质/可读性/交互；降低透明度=\(reduceTransparency)")
            }.buttonStyle(.bordered).font(.caption)
            Button("报告玻璃异常…", role: .destructive) {
                confirmFailure = true
            }.buttonStyle(.borderless).font(.caption)
            Text("本次玻璃结果：\(store.results["Glass"]?.status ?? "NOT_RUN")")
                .font(.caption)
            Text("上方两项是人工操作按钮，不是自动检测结果。正常时只点人工确认。")
                .font(.caption2)
        }
        .confirmationDialog("确实观察到玻璃显示或交互异常？", isPresented: $confirmFailure, titleVisibility: .visible) {
            Button("确认异常并记为失败", role: .destructive) {
                store.mark("Glass", "FAIL", "用户二次确认玻璃显示或交互异常")
            }
            Button("取消", role: .cancel) {}
        }
    }
}

struct ProbeImageView: View {
    var body: some View {
        Group {
            if let url = Bundle.module.url(forResource: "ProbeBackground", withExtension: "png"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .onAppear { ProbeStore.shared.mark("PNG资源", "PASS", "SwiftPM 普通 PNG 读取及解码成功") }
            } else {
                Text("图片读取失败")
                    .onAppear { ProbeStore.shared.mark("PNG资源", "FAIL", "普通 PNG 无法读取或解码") }
            }
        }
    }
}

struct ProbeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 20) {
            Text("系统 NavigationStack 详情页")
            Button("确认进入并返回") {
                ProbeStore.shared.mark("导航", "PASS", "用户进入详情并触发返回")
                dismiss()
            }
        }.navigationTitle("详情探针")
    }
}

struct ProbePlatformView: View {
    @ObservedObject private var store = ProbeStore.shared
    @State private var networkRunning = false
    @State private var webTarget: ProbeWebTarget?
    var body: some View {
        NavigationStack {
            List {
                Section("无账号网络") {
                    Button("运行 URLSession 检查") {
                        Task {
                            networkRunning = true
                            await ProbeNetwork.run(expectFailure: false)
                            networkRunning = false
                        }
                    }.disabled(networkRunning)
                    Button("运行预期失败检查（保留失败提示）") {
                        Task {
                            networkRunning = true
                            await ProbeNetwork.run(expectFailure: true)
                            networkRunning = false
                        }
                    }.disabled(networkRunning)
                    Text("仅访问固定公开示例页或保留的无效域名，不使用 Cookie/账号。")
                        .font(.caption)
                    Text("网络：\(store.results["URLSession"]?.status ?? "NOT_RUN")")
                    Text("错误处理：\(store.results["网络错误处理"]?.detail ?? "未运行")").font(.caption)
                }
                Section("隔离的 WKWebView") {
                    Button("打开 WK 本地测试页") { webTarget = .local }
                    Button("打开 WK 公开测试页") { webTarget = .remote }
                    Text("\(store.results["WKWebView"]?.status ?? "NOT_RUN") · 非持久数据存储")
                }
                Section("持久化（冷启动仅检查，不自动重建）") {
                    Button("Keychain 首次写入并检查") { ProbeKeychain.run(allowCreate: true) }
                    Text(store.results["Keychain"]?.detail ?? "未运行").font(.caption)
                    Button("SQLite 首次写入并检查") { ProbeSQLite.run(allowCreate: true) }
                    Text(store.results["SQLite"]?.detail ?? "未运行").font(.caption)
                }
            }.navigationTitle("平台探针")
            .task {
                ProbeKeychain.run(allowCreate: false)
                ProbeSQLite.run(allowCreate: false)
            }
            .sheet(item: $webTarget) { target in ProbeWebScreen(target: target) }
        }
    }
}

struct ProbeDiagnosticsView: View {
    @ObservedObject private var store = ProbeStore.shared
    @AppStorage("t06.installationProbe.savedValue") private var previousValue = ""
    @State private var exportItem: ProbeExportItem?
    var body: some View {
        NavigationStack {
            List {
                Section("版本与历史值") {
                    Text("Build \(store.build) · iPhone / iOS 27+")
                    Text("T06 保存值：\(previousValue.isEmpty ? "无" : previousValue)")
                    Text("结果表仅代表本次启动。日志包含历史启动事件。")
                    if let error = store.storageError { Text(error).foregroundStyle(.red) }
                }
                Section("检查结果") {
                    ForEach(ProbeStore.names, id: \.self) { name in
                        VStack(alignment: .leading) {
                            Text("\(name)：\(store.results[name]?.status ?? "NOT_RUN")")
                            Text(store.results[name]?.detail ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("导出与持久性检查") {
                    Button("导出脱敏 JSON 报告") {
                        if let url = store.export() { exportItem = ProbeExportItem(url: url) }
                    }
                    Text("报告不含 Cookie、私钥、UDID、设备名称和 T06 保存值。取消分享不会记为通过。")
                        .font(.caption)
                    Text("先完成交互和平台检查并导出；然后划掉重开，到平台页观察 Keychain/SQLite 是否只读已有值。结果表会重置，历史事件保留。")
                        .font(.caption)
                }
                Section("最近事件") {
                    ForEach(Array(store.events.suffix(30).reversed())) { event in
                        VStack(alignment: .leading) {
                            Text(event.name).font(.headline)
                            Text(event.detail).font(.caption)
                            Text(event.time, style: .time).font(.caption2)
                        }
                    }
                }
            }
            .navigationTitle("诊断")
            .sheet(item: $exportItem) { item in
                ProbeExportSheet(url: item.url) { completed, errorCode in
                    if let errorCode {
                        store.mark("日志导出", "FAIL", "分享错误 code=\(errorCode)")
                    } else {
                        store.mark("日志导出", completed ? "PASS" : "NOT_RUN", completed ? "系统分享完成，需用户确认文件可取出" : "用户取消分享")
                    }
                    exportItem = nil
                }
            }
        }
    }
}
#endif
