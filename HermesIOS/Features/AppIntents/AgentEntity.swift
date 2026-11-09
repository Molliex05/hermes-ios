import AppIntents

/// An agent as Siri, Shortcuts and the widget's settings name it: the profiles the app last saw, by their display name.
/// Compiled into the app and the widgets, which both read the list from the shared keychain.
struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let defaultQuery = AgentQuery()

    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct AgentQuery: EntityQuery {
    private func all() -> [AgentEntity] { SharedProfiles.read().map { AgentEntity(id: $0.name, title: $0.title.isEmpty ? $0.name : $0.title) } }
    func entities(for identifiers: [String]) async throws -> [AgentEntity] { all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [AgentEntity] { all() }
    func defaultResult() async -> AgentEntity? { all().first }
}
