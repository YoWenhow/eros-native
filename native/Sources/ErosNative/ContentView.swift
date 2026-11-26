import SwiftUI
import Foundation

struct ContentView: View {
    @State private var showPersistence = false
    @State private var showNetworking = false
    @AppStorage("t06.installationProbe.savedValue") private var savedValue = ""
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    var body: some View {
        ScrollView {
          VStack(spacing: 20) {
            Image(systemName: "book.closed")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Hello, Eros Native!")
                .font(.title2)
            Text("覆盖更新已完成")
                .font(.headline)
            Text("Build \(buildNumber)")
                .foregroundStyle(.secondary)
            Divider()
            Text("本地保存值")
                .font(.headline)
            Text(savedValue.isEmpty ? "尚未保存" : savedValue)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("t06.savedValue")
            Button("保存验收值") {
                savedValue = "KEEP-" + String(UUID().uuidString.prefix(8))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!savedValue.isEmpty)
            Text("保存后保留此值，用于确认覆盖安装与重新打开应用后数据仍在。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("T14 存储验收") { showPersistence = true }
                .buttonStyle(.bordered)
            Button("T15 网络验收") { showNetworking = true }
                .buttonStyle(.bordered)
          }
          .multilineTextAlignment(.center)
          .padding(24)
        }
        .sheet(isPresented: $showPersistence) { PersistenceAcceptanceView() }
        .sheet(isPresented: $showNetworking) { NetworkAcceptanceView() }
    }
}
