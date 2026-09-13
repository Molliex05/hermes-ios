import SwiftUI

struct RoutinesView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    var body: some View {
        NavigationStack {
            List { Group {
                Section {
                    Text("Les routines de \(model.agent?.title ?? "Hermes") continuent sur votre serveur, même quand Hermès iOS est fermé.").font(.subheadline).foregroundStyle(.secondary)
                }
                if model.routines.isEmpty {
                    ContentUnavailableView("Un rythme à inventer", systemImage: "sun.max", description: Text("Un briefing du matin, une veille, un bilan. Confiez une habitude à votre agent."))
                }
                ForEach(model.routines) { routine in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(routine.name).font(.headline)
                            Spacer()
                            Button { Task { await model.toggleRoutine(routine) } } label: {
                                Image(systemName: routine.paused ? "play.circle" : "pause.circle").font(.title2)
                            }.buttonStyle(.borderless).accessibilityLabel(routine.paused ? "Reprendre" : "Mettre en pause")
                        }
                        Text(routine.prompt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        Label(routine.paused ? "En pause" : routine.schedule, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 10)
                }
            }.listRowBackground(Color.clear)
}.modernList()
                .navigationTitle("Les routines").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }

                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ToolDock { Button { creating = true } label: { Label("Ajouter", systemImage: "plus").frame(minHeight: 44) }.disabled(model.demo).accessibilityLabel("Nouvelle routine") }
                }.task { await model.loadRoutines() }
                .sheet(isPresented: $creating) { RoutineEditor(model: model) }
        }
    }
}

struct RoutineEditor: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = "0 8 * * *"
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Une petite habitude") {
                    TextField("Nom de la routine", text: $name)
                    TextField("Que doit faire votre agent ?", text: $prompt, axis: .vertical).lineLimit(4...8)
                }
                Section {
                    Picker("Rythme", selection: $schedule) {
                        Text("Chaque matin à 8 h").tag("0 8 * * *")
                        Text("En semaine à 9 h").tag("0 9 * * 1-5")
                        Text("Le vendredi à 17 h").tag("0 17 * * 5")
                        Text("Toutes les heures").tag("0 * * * *")
                    }
                } footer: { Text("Heure du serveur Hermes. Le résultat arrive dans le Bot Chat de cet agent.") }
                if let error { Text(error).foregroundStyle(AppTheme.accent) }
            }.modernList()
                .navigationTitle("Nouvelle routine").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(busy ? "Création…" : "Créer") { create() }.disabled(name.isEmpty || prompt.isEmpty || busy) }
                }
        }
    }
    private func create() {
        busy = true
        Task {
            do { try await model.createRoutine(name: name, prompt: prompt, schedule: schedule); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
