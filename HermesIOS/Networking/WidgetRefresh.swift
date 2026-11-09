import Foundation
import Security
import WidgetKit

/// Downloads the agents' boards, saves them for the « À l'affiche » widget and asks WidgetKit to redraw. Used by the live app
/// (`AppModel`) and by the silent push that wakes the app in the background with no UI.
enum WidgetRefresh {
    enum Result { case saved, unavailable, failed }
    static let boardPath = "/api/plugins/hermes-widgets/board"

    static func run(using http: HermesHTTP) async -> Result {
        await sendSeen(using: http)
        do {
            let value = try await http.request(boardPath)
            guard AgentBoardStore.write(try JSONEncoder().encode(value)) != nil else { return .failed }
            WidgetCenter.shared.reloadAllTimelines()
            return .saved
        } catch let failure as RPCFailure where [401, 403, 404].contains(failure.code) {
            return .unavailable
        } catch { return .failed }
    }

    /// The « Vu » taps on the widget, which cannot reach the server itself: each one takes its lines off the agent's board
    /// (and archives the emails they were about), then is forgotten. One that fails is tried again on the next refresh.
    static func sendSeen(using http: HermesHTTP) async {
        let marks = BoardDismissals.read()
        guard !marks.isEmpty else { return }
        var done: [SeenMark] = []
        for mark in marks {
            let body: JSONValue = .object(["profile": .string(mark.profile), "lines": .array(mark.lines.map(JSONValue.string)), "focus": .string(mark.focus)])
            do {
                _ = try await http.request(boardPath + "/seen", method: "POST", body: body)
                done.append(mark)
            } catch let failure as RPCFailure where failure.code == 404 {
                continue                                                // a server without « Vu » yet: kept until it expires
            } catch { break }                                           // offline: the rest waits too
        }
        if !done.isEmpty { BoardDismissals.remove(done) }
    }

    static var hasSeenToSend: Bool { !BoardDismissals.read().isEmpty }

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
