import SwiftUI

struct RoutineDetailView: View {
    @State private var tools: NativeToolSession
    let routine: Routine
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = ""
    @State private var originalSchedule = ""
    @State private var runs: [JSONValue] = []
    @State private var loaded = false
    @State private var deleting = false
    @State private var triggering = false
    @State private var status: String?
    @Environment(\.dismiss) private var dismiss
    init(app: AppModel, routine: Routine) { _tools = State(initialValue: NativeToolSession(app)); self.routine = routine }
    private var path: String { "/api/cron/jobs/" + routine.id }
    var body: some View {
        Form {
            Section("La routine") {
                TextField("Nom", text: $name)
                TextField("Instruction", text: $prompt, axis: .vertical).lineLimit(4...10)
                TextField("Horaire Hermes", text: $schedule).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Ex. 0 8 * * * ou every 4h. Heure du serveur.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!loaded || tools.busy)
            ToolFeedback(tools: tools)
            if let status { Text(status).font(.caption).foregroundStyle(AppTheme.accent) }
            Section {
                Button("Enregistrer") { Task { await tools.perform {
                    var updates: [String: JSONValue] = ["name": .string(name), "prompt": .string(prompt)]
                    if schedule != originalSchedule { updates["schedule"] = .string(schedule) }
                    _ = try await tools.request(path, method: "PUT", body: ["updates": .object(updates)])
                    originalSchedule = schedule; status = "Modifications enregistrées"; await tools.app.loadRoutines()
                } } }.disabled(!loaded || tools.busy || name.isEmpty || prompt.isEmpty)
                Button("Lancer maintenant", systemImage: "play") { triggering = true }.disabled(tools.busy)
                Button("Supprimer la routine", role: .destructive) { deleting = true }.disabled(tools.busy)
            }
            Section("Dernières exécutions") {
                if runs.isEmpty { Text("Aucune exécution disponible.").foregroundStyle(.secondary) }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(run["title"].string.isEmpty ? (run["is_active"].bool ? "En cours" : "Exécution terminée") : run["title"].string).font(.subheadline.weight(.medium))
                        Text(Date(timeIntervalSince1970: run["started_at"].double), format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        if !run["preview"].string.isEmpty { Text(run["preview"].string).font(.caption).lineLimit(3) }
                        if !run["error"].string.isEmpty { Text(run["error"].string).font(.caption).foregroundStyle(AppTheme.accent) }
                    }
                }
            }
        }.modernList().navigationTitle(routine.name).navigationBarTitleDisplayMode(.inline)
            .task { await load() }.refreshable { await load() }
            .confirmationDialog("Supprimer cette routine sur Hermes ?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { Task { await tools.perform { _ = try await tools.request(path, method: "DELETE"); await tools.app.loadRoutines(); dismiss() } } }
            }
            .confirmationDialog("Exécuter cette routine maintenant ?", isPresented: $triggering, titleVisibility: .visible) {
                Button("Exécuter") { Task { await tools.perform {
                    _ = try await tools.request(path + "/trigger", method: "POST", body: [:]); status = "Exécution demandée à Hermes"; await load()
                } } }
            }
    }
    private func load() async {
        do {
            let row = try await tools.request(path)
            name = row["name"].string; prompt = row["prompt"].string
            schedule = row["schedule"].string
            if schedule.isEmpty { schedule = row["schedule"]["value"].string }
            if schedule.isEmpty { schedule = routine.schedule }
            originalSchedule = schedule; loaded = true
            let history = try await tools.request(path + "/runs")
            runs = history.array.isEmpty ? history["runs"].array : history.array
        } catch { tools.error = error.localizedDescription }
    }
}
