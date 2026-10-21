import SwiftUI

struct RoutineDetailView: View {
    @State private var tools: NativeToolSession
    let routine: Routine
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = ""
    @State private var originalName = ""
    @State private var originalPrompt = ""
    @State private var originalSchedule = ""
    @State private var namePrefix = ""
    @State private var job: JSONValue = .null
    @State private var runs: [JSONValue] = []
    @State private var loaded = false
    @State private var jobMissing = false
    @State private var deleting = false
    @State private var triggering = false
    @State private var verifyingTrigger = false
    @State private var openingResult = false
    @State private var status: String?
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, routine: Routine) {
        _tools = State(initialValue: NativeToolSession(app)); self.routine = routine
    }

    private var path: String { "/api/cron/jobs/" + routine.id }
    private var paused: Bool { loaded ? Routine(job).paused : routine.paused }
    private var completed: Bool { loaded ? Routine(job).completed : routine.completed }
    private var canMutate: Bool { loaded && !tools.busy && !jobMissing }
    private var hasChanges: Bool { name != originalName || prompt != originalPrompt || schedule != originalSchedule }
    private var valid: Bool {
        ![name, prompt, schedule].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Label(jobMissing ? "Routine non enregistrée" : (completed ? "Terminée" : (paused ? "En pause" : "Active sur Hermès")), systemImage: jobMissing ? "tray" : (completed ? "checkmark.circle" : (paused ? "pause.circle" : "clock")))
                    .foregroundStyle(jobMissing || paused ? Color.secondary : AppTheme.accent)
                if !jobMissing, !paused, let next = RoutineSchedule.nextRun(from: job) {
                    LabeledContent("Prochaine exécution") {
                        Text(next, format: .dateTime.day().month().hour().minute()).multilineTextAlignment(.trailing)
                    }
                    Text("À l’heure de cet iPhone.").font(.caption).foregroundStyle(.secondary)
                }
                if !job["last_error"].string.isEmpty {
                    Label(job["last_error"].string, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(AppTheme.accent)
                }
            }
            Section("La routine") {
                TextField("Nom", text: $name)
                TextField("Instruction", text: $prompt, axis: .vertical).lineLimit(4...10)
            }.disabled(!canMutate)
            RoutineScheduleFields(schedule: $schedule).disabled(!canMutate)
            ToolFeedback(tools: tools)
            if let status { Text(status).font(.subheadline).foregroundStyle(AppTheme.accent) }
            Section {
                Button(paused ? "Reprendre la routine" : "Mettre en pause", systemImage: paused ? "play.circle" : "pause.circle") {
                    Task { await tools.perform {
                        guard !jobMissing else { return }
                        job = try await tools.request(path + (paused ? "/resume" : "/pause"), method: "POST", body: [:])
                        status = paused ? "Routine mise en pause" : "Routine réactivée"
                        await tools.app.loadRoutines()
                    } }
                }.disabled(!canMutate || completed)
                if verifyingTrigger || jobMissing {
                    Button("Actualiser le résultat", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(tools.busy)
                } else {
                    Button("Lancer maintenant", systemImage: "play") { triggering = true }
                        .disabled(!canMutate).accessibilityIdentifier("routine.trigger")
                }
            }
            Section("Dernières exécutions") {
                if runs.isEmpty { Text("Aucune exécution disponible.").foregroundStyle(.secondary) }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in runRow(run) }
            }
            Section {
                Button("Supprimer la routine", role: .destructive) { deleting = true }.disabled(!canMutate)
            }
        }
        .modernList().navigationTitle(name.isEmpty ? routine.name : name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer") { Task { await save() } }
                    .disabled(!canMutate || !valid || !hasChanges)
            }
        }
        .task { await load() }.refreshable { await load() }
        .appConfirm("Supprimer cette routine sur Hermès ?", isPresented: $deleting) {
            Button("Supprimer", role: .destructive) { Task { await tools.perform {
                guard !jobMissing else { return }
                _ = try await tools.request(path, method: "DELETE"); await tools.app.loadRoutines(); dismiss()
            } } }
        }
        .appConfirm("Exécuter la version enregistrée de cette routine ?", isPresented: $triggering) {
            Button("Exécuter") { Task { await trigger() } }
        } message: {
            if paused { Text("Hermès réactive aussi la routine mise en pause lors d’un lancement manuel.") }
            else if hasChanges { Text("Les modifications non enregistrées ne seront pas utilisées.") }
        }
    }

    @ViewBuilder private func runRow(_ run: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(run["title"].string.isEmpty ? "Exécution" : run["title"].string)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                if run["is_active"].bool {
                    Text("En cours").font(.caption).foregroundStyle(AppTheme.accent)
                }
            }
            if run["started_at"].double > 0 {
                Text(Date(timeIntervalSince1970: run["started_at"].double), format: .dateTime.day().month().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !run["preview"].string.isEmpty { Text(run["preview"].string).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            if !run["error"].string.isEmpty { Text(run["error"].string).font(.caption).foregroundStyle(AppTheme.accent) }
            if let conversation = RoutineSchedule.runConversation(run, profile: tools.profile) {
                Button("Voir le résultat", systemImage: "arrow.up.right") {
                    Task {
                        guard !openingResult, !tools.app.sending, !tools.app.voiceActive,
                              tools.app.activeConnection?.id == tools.connectionID else { return }
                        openingResult = true
                        await tools.app.openConversation(conversation)
                        openingResult = false
                        if tools.app.selected?.storedID == conversation.id,
                           !(tools.app.selected?.runtimeID.isEmpty ?? true) {
                            tools.app.navigationRevision = UUID()
                        }
                    }
                }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
                    .disabled(openingResult || tools.app.sending || tools.app.voiceActive || run["is_active"].bool)
                    .accessibilityIdentifier("routine.result")
            }
        }.padding(.vertical, 4)
    }

    private func save() async {
        guard !jobMissing else { return }
        await tools.perform {
            let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var updates: [String: JSONValue] = ["name": .string(namePrefix + cleanedName), "prompt": .string(prompt)]
            // Preserve native one-shot and custom schedules when only the text is edited.
            if schedule != originalSchedule { updates["schedule"] = .string(schedule.trimmingCharacters(in: .whitespacesAndNewlines)) }
            job = try await tools.request(path, method: "PUT", body: ["updates": .object(updates)])
            name = cleanedName; originalName = name; originalPrompt = prompt; originalSchedule = schedule
            status = "Modifications enregistrées"
            await tools.app.loadRoutines()
        }
    }

    private func trigger() async {
        guard !jobMissing else { return }
        await tools.perform {
            status = "Hermès exécute la routine. Vous pouvez revenir au chat."
            do {
                job = try await tools.request(path + "/trigger", method: "POST", body: [:])
                status = "Exécution terminée. Retrouvez son résultat ci-dessous."
                await loadRuns()
                await tools.app.loadRoutines()
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                // The native endpoint waits for the whole run. A transport timeout
                // is not evidence that the server stopped, so never submit it again.
                verifyingTrigger = true
                status = "La connexion a été interrompue. La routine peut continuer sur Hermès. Actualisez son résultat avant de la relancer."
                await load()
            }
        }
    }

    private func load() async {
        do {
            let row = try await tools.request(path)
            if jobMissing { status = nil }
            jobMissing = false
            if verifyingTrigger, row["last_run_at"] != job["last_run_at"], !row["last_run_at"].isNull {
                verifyingTrigger = false; status = "Le résultat de l’exécution est disponible."
            }
            job = row
            if !loaded {
                name = Routine(row).name; prompt = row["prompt"].string
                let serverName = row["name"].string
                if serverName.hasSuffix(name) { namePrefix = String(serverName.dropLast(name.count)) }
                schedule = RoutineSchedule.expression(from: row)
                if schedule.isEmpty { schedule = routine.rawSchedule }
                originalName = name; originalPrompt = prompt; originalSchedule = schedule; loaded = true
            }
            tools.error = nil
            await loadRuns()
        } catch let error as RPCFailure where error.code == 404 {
            // A one-shot can disappear after running, but an external deletion
            // produces the same response. Keep the history without inferring success.
            jobMissing = true
            tools.error = nil
            status = "Cette routine n’est plus enregistrée. Ses exécutions restent accessibles."
            await loadRuns()
        } catch { tools.error = error.localizedDescription }
    }

    private func loadRuns() async {
        do {
            let history = try await tools.request(path + "/runs")
            runs = history.array.isEmpty ? history["runs"].array : history.array
        } catch { tools.error = error.localizedDescription }
    }
}
