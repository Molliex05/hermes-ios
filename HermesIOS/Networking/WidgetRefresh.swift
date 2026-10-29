import Foundation
import Security
import WidgetKit

/// Downloads the agents' boards, saves them for the « À l'affiche » widget and asks WidgetKit to redraw. Used by the live app
/// (`AppModel`) and by the silent push that wakes the app in the background with no UI.
enum WidgetRefresh {
    enum Result { case saved, unavailable, failed }
    static let boardPath = "/api/plugins/hermes-widgets/board"

    static func run(using http: HermesHTTP) async -> Result {
        do {
            let value = try await http.request(boardPath)
            guard AgentBoardStore.write(try JSONEncoder().encode(value)) != nil else { return .failed }
            WidgetCenter.shared.reloadAllTimelines()
            return .saved
        } catch let failure as RPCFailure where [401, 403, 404].contains(failure.code) {
            return .unavailable
        } catch { return .failed }
    }

    /// The Noriven finance widget is gone: its figures, saved in the shared keychain by an earlier version, are deleted.
    static func removeOldFinanceSnapshot() {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.hermesios.widget-snapshot",
                                    kSecAttrAccount as String: "noriven"]
        if let group = Bundle.main.object(forInfoDictionaryKey: "HermesSharedKeychainGroup") as? String, !group.isEmpty, !group.contains("$(") {
            query[kSecAttrAccessGroup as String] = group
        }
        SecItemDelete(query as CFDictionary)
    }

    /// From a silent push: the app may have been started just for this, so it reads the saved connection itself.
    @MainActor static func runInBackground() async -> Bool {
        let connections = await LocalCache().read([SavedConnection].self, key: "connections") ?? []
        guard let first = connections.first else { return false }
        let http = HermesHTTP(first)
        defer { http.invalidate() }                                    // one URLSession per silent push would pile up
        return await run(using: http) == .saved
    }
}
