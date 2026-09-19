import Foundation

extension AppModel {
    func useWorkspace(_ path: String) async throws {
        guard let chat = selected, !transcript.running else { throw RPCFailure("Ouvrez une conversation au repos pour choisir son dossier.") }
        _ = try await toolRequest("session.cwd.set", body: ["session_id": .string(chat.runtimeID), "cwd": .string(path)], connectionID: activeConnection?.id, profile: profile, rpc: true)
        notice = "Dossier de la conversation mis à jour."
    }

    func historyPage(query: String, offset: Int = 0, archived: Bool = false) async throws -> JSONValue {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var items = [URLQueryItem(name: "limit", value: "100")]
        if searching { items.append(URLQueryItem(name: "q", value: query)) }
        else { items += [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "archived", value: archived ? "only" : "exclude")] }
        return try await toolRequest(searching ? "/api/sessions/search" : "/api/sessions", query: items, connectionID: activeConnection?.id, profile: profile)
    }

    func updateConversation(_ conversation: Conversation, patch: JSONValue) async throws {
        _ = try await toolRequest("/api/sessions/" + conversation.id, method: "PATCH", body: patch, connectionID: activeConnection?.id, profile: conversation.profile)
        if selected?.storedID == conversation.id, patch["archived"].bool { newChat() }
        try await refreshSessions()
    }

    func branchConversation() async {
        guard let chat = selected, !transcript.running else { return }
        do {
            let result = try await toolRequest("session.branch", body: ["session_id": .string(chat.runtimeID)], connectionID: activeConnection?.id, profile: profile, rpc: true)
            await openConversation(Conversation(["id": result["stored_session_id"], "title": result["title"]], profile: chat.profile))
        } catch { notice = error.localizedDescription }
    }

    func compactConversation() async {
        guard let chat = selected, !transcript.running else { return }
        do {
            _ = try await toolRequest("session.compress", body: ["session_id": .string(chat.runtimeID)], connectionID: activeConnection?.id, profile: profile, rpc: true)
            await openConversation(Conversation(["id": .string(chat.storedID), "title": .string(chat.title)], profile: chat.profile))
        } catch { notice = error.localizedDescription }
    }
}
