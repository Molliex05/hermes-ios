import Foundation
import Observation

@MainActor @Observable
final class NativeToolSession {
    let app: AppModel
    let profile: String
    let connectionID: UUID?
    var data: JSONValue = .null
    var loading = false
    var error: String?
    var busy = false
    @ObservationIgnored private var resourceKey: String?
    @ObservationIgnored private var loadID = UUID()

    init(_ app: AppModel) {
        self.app = app; profile = app.profile; connectionID = app.activeConnection?.id
    }

    func request(_ path: String, method: String = "GET", body: JSONValue? = nil,
                 query: [URLQueryItem] = [], rpc: Bool = false) async throws -> JSONValue {
        guard !app.demo else { throw RPCFailure("Connectez votre Hermes pour effectuer cette action.") }
        return try await app.toolRequest(path, method: method, body: body, query: query,
            connectionID: connectionID, profile: profile, rpc: rpc)
    }

    func load(_ path: String, query: [URLQueryItem] = [], rpc: Bool = false) async {
        let key = "\(connectionID?.uuidString ?? "demo")|\(profile)|\(path)|\(query)"
        guard !loading || resourceKey != key else { return }
        if resourceKey != key { data = app.toolCache[key] ?? .null; resourceKey = key }
        let attempt = UUID(); loadID = attempt
        loading = true; error = nil
        defer { if loadID == attempt { loading = false } }
        do {
            let result = app.demo ? Self.preview(path) : try await request(path, query: query, rpc: rpc)
            try Task.checkCancellation()
            guard loadID == attempt else { return }
            data = result; app.toolCache[key] = result
        } catch is CancellationError { }
        catch {
            guard loadID == attempt else { return }
            if let failure = error as? RPCFailure, [404, 405, -32601].contains(failure.code) {
                self.error = "Cet outil n’est pas disponible sur ce serveur Hermes. Vérifiez sa version et, pour Kanban, l’activation du plugin."
            } else { self.error = error.localizedDescription }
        }
    }

    func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await action() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private static func preview(_ path: String) -> JSONValue {
        switch path {
        case "/api/skills": [
            ["name": "web-research", "description": "Explorer, recouper et citer des sources fiables.", "enabled": true, "provenance": "bundled"],
            ["name": "daily-briefing", "description": "Un point clair sur ce qui compte aujourd’hui.", "enabled": true, "provenance": "agent"],
            ["name": "writing", "description": "Trouver le ton juste et affiner vos textes.", "enabled": false, "provenance": "bundled"]]
        case "/api/model/options": ["model": "Hermes", "provider": "nous", "providers": [["slug": "nous", "name": "Nous Research", "models": ["Hermes"], "is_current": true]]]
        case "projects.list": ["projects": [["id": "demo-project", "name": "Mon espace de travail", "description": "Les projets et dossiers de votre agent.", "primary_path": "~/Projects", "folders": [["path": "~/Projects", "label": "Projets"]]]]]
        case "/api/plugins/kanban/boards": ["current": "default", "boards": [["slug": "default", "name": "Mes projets", "total": 3]]]
        case "/api/plugins/kanban/board": ["columns": [
            ["name": "todo", "tasks": [["id": "demo-1", "title": "Préparer la prochaine idée", "body": "Poser les premières pistes et choisir une direction.", "status": "todo"]]],
            ["name": "running", "tasks": [["id": "demo-2", "title": "Explorer les possibilités", "assignee": "Atlas", "status": "running"]]],
            ["name": "done", "tasks": [["id": "demo-3", "title": "Faire le point", "status": "done"]]]]]
        default: [:]
        }
    }
}
