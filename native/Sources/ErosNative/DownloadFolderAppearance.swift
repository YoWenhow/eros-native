import SwiftUI
import UIKit
import ErosCore
import ErosServices
import ErosPersistence

struct DownloadFolderLabel: View {
    let title: String
    let rgb: UInt32?

    var body: some View {
        Label {
            Text(verbatim: title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "folder.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Self.tint(for: rgb).gradient)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
        .labelStyle(.titleAndIcon)
    }

    static func tint(for rgb: UInt32?) -> Color {
        guard let rgb else { return .blue }
        return Color(red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255)
    }
}

struct DownloadFolderChoices: View {
    let folders: [DownloadFolder]
    let selection: DownloadFolderID?
    let select: (DownloadFolderID?) -> Void

    var body: some View {
        row(nil) { RootMenuLabel("未分组", symbol: "tray.fill", color: .gray) }
        ForEach(folders, id: \.id) { folder in
            row(folder.id) {
                DownloadFolderLabel(title: folder.displayName.value, rgb: DownloadFolderPreferences.shared.color(
                    for: folder.id, account: folder.accountID))
            }
        }
    }

    private func row<Title: View>(_ id: DownloadFolderID?, @ViewBuilder title: () -> Title) -> some View {
        let selected = selection == id
        return Button { select(id) } label: {
            HStack {
                title()
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct DownloadFolderColorEditor: View {
    let folder: DownloadFolder
    @Environment(\.dismiss) private var dismiss
    @State private var rgb: UInt32?
    @State private var management: DownloadFolderManagementModel

    init(folder: DownloadFolder, database: SQLiteDatabase, sessions: any SessionProvider, scope: SessionScope) {
        self.folder = folder
        _rgb = State(initialValue: DownloadFolderPreferences.shared.color(for: folder.id, account: folder.accountID))
        _management = State(initialValue: DownloadFolderManagementModel(store: database, sessions: sessions, scope: scope))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ColorPicker(selection: selection, supportsOpacity: false) {
                        DownloadFolderLabel(title: folder.displayName.value, rgb: rgb)
                    }
                    Button("恢复默认颜色", systemImage: "arrow.counterclockwise") { rgb = nil }
                        .disabled(rgb == nil)
                }
                .disabled(management.busy)
                if let error = management.error {
                    Text(error.message).foregroundStyle(.red)
                }
            }
            .navigationTitle("文件夹颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(management.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { if await management.setColor(rgb, for: folder) { dismiss() } }
                    }
                    .disabled(management.busy)
                }
            }
            .interactiveDismissDisabled(management.busy)
        }
        .presentationDetents([.medium])
    }

    private var selection: Binding<Color> {
        Binding(get: { DownloadFolderLabel.tint(for: rgb) }, set: { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
                  red.isFinite, green.isFinite, blue.isFinite else { return }
            func byte(_ value: CGFloat) -> UInt32 {
                UInt32((min(max(value, 0), 1) * 255).rounded())
            }
            rgb = (byte(red) << 16) | (byte(green) << 8) | byte(blue)
        })
    }
}
