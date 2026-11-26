import Foundation
import Observation
import ErosCore

@MainActor @Observable public final class DownloadFolderPreferences {
    public static let shared = DownloadFolderPreferences(defaults: .standard)
    private static let colorsKey = "native.download-folder.colors"
    private let defaults: UserDefaults
    private var colors: [String: Int]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        colors = defaults.dictionary(forKey: Self.colorsKey) as? [String: Int] ?? [:]
    }

    public func color(for id: DownloadFolderID, account: AccountID) -> UInt32? {
        guard let value = colors[colorKey(id, account: account)], (0...0xFFFFFF).contains(value) else { return nil }
        return UInt32(value)
    }

    func setColor(_ rgb: UInt32?, for id: DownloadFolderID, account: AccountID) {
        let key = colorKey(id, account: account)
        let value = rgb.map(Int.init)
        guard colors[key] != value else { return }
        colors[key] = value
        defaults.set(colors, forKey: Self.colorsKey)
    }

    private func colorKey(_ id: DownloadFolderID, account: AccountID) -> String {
        key("color.\(id.value.uuidString)", account: account)
    }

    public func reusesLastFolder(account: AccountID) -> Bool {
        defaults.bool(forKey: key("reuseLast", account: account))
    }

    public func setReusesLastFolder(_ enabled: Bool, account: AccountID) {
        defaults.set(enabled, forKey: key("reuseLast", account: account))
    }

    public func remember(_ folderID: DownloadFolderID?, account: AccountID) {
        let selection = folderID?.value.uuidString ?? DownloadLibraryTarget.unfiled.storageKey
        defaults.set(selection, forKey: key("last", account: account))
    }

    public func initialFolderID(defaultFolderID: DownloadFolderID?, folders: [DownloadFolder],
                                account: AccountID) -> DownloadFolderID? {
        let fallback = folders.first { $0.accountID == account && $0.id == defaultFolderID }?.id
        guard reusesLastFolder(account: account),
              let selection = defaults.string(forKey: key("last", account: account)) else { return fallback }
        if selection == DownloadLibraryTarget.unfiled.storageKey { return nil }
        guard let id = UUID(uuidString: selection) else { return fallback }
        return folders.first { $0.accountID == account && $0.id.value == id }?.id ?? fallback
    }

    private func key(_ setting: String, account: AccountID) -> String {
        "native.download-folder.\(account.value.uuidString).\(setting)"
    }
}
