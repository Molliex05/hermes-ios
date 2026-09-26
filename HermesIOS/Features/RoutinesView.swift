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
                    NavigationLink { RoutineDetailView(app: model, routine: routine) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(routine.name).font(.headline).lineLimit(1)
                                Spacer(minLength: 8)
                                if routine.paused || routine.completed {
                                    Text(routine.completed ? "Terminée" : "En pause").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                }
                            }
                            Text(routine.prompt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Label(routine.scheduleSummary, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                            if !routine.paused, let next = routine.nextRunAt {
                                Text("Prochaine : \(next.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(AppTheme.accent)
                            }
                        }.padding(.vertical, 8)
                    }.swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button(routine.paused ? "Reprendre" : "Pause", systemImage: routine.paused ? "play" : "pause") {
                            Task { await model.toggleRoutine(routine) }
                        }.tint(AppTheme.accent).disabled(model.demo || routine.completed)
                    }
                }
                if model.routines.contains(where: { !$0.paused && $0.nextRunAt != nil }) {
                    Text("Les prochaines exécutions sont affichées à l’heure de cet iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.listRowBackground(Color.clear)
}.modernList()
                .navigationTitle("Les routines").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fermer", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("routines.close") }

                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ToolDock { Button { creating = true } label: { Label("Ajouter", systemImage: "plus").frame(minHeight: 44) }.disabled(model.demo).accessibilityLabel("Nouvelle routine").accessibilityIdentifier("routine.add") }
                }.task { await model.loadRoutines() }.refreshable { await model.loadRoutines() }
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
                    TextField("Nom de la routine", text: $name).accessibilityIdentifier("routine.name")
                    TextField("Que doit faire votre agent ?", text: $prompt, axis: .vertical).lineLimit(4...8).accessibilityIdentifier("routine.prompt")
                }
                RoutineScheduleFields(schedule: $schedule)
                Section {
                    Label("Le résultat arrive dans le Bot Chat de cet agent.", systemImage: "bubble.left.and.bubble.right")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(AppTheme.accent) }
            }.modernList()
                .navigationTitle("Nouvelle routine").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fermer", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(busy ? "Création…" : "Créer") { create() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy).accessibilityIdentifier("routine.create") }
                }
        }.interactiveDismissDisabled(busy)
    }
    private func create() {
        busy = true
        Task {
            do { try await model.createRoutine(name: name.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt, schedule: schedule.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct RoutineScheduleFields: View {
    @Binding var schedule: String
    @State private var customMode = false
    @State private var advanced = false
    private var parsed: RoutineSchedule? { RoutineSchedule(schedule) }
    private var customized: Bool { customMode || parsed == nil }
    private var wallClock: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var rhythm: Binding<String> {
        Binding {
            customized ? "custom" : parsed!.rhythm.rawValue
        } set: { value in
            guard let selection = RoutineSchedule.Rhythm(rawValue: value) else {
                customMode = true; advanced = true; return
            }
            var current = parsed ?? RoutineSchedule(rhythm: selection)
            current.rhythm = selection
            schedule = current.expression; customMode = false
        }
    }
    private var time: Binding<Date> {
        Binding {
            let value = parsed ?? RoutineSchedule(rhythm: .daily)
            return wallClock.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: value.hour, minute: value.minute))!
        } set: { value in
            var current = parsed ?? RoutineSchedule(rhythm: .daily)
            current.hour = wallClock.component(.hour, from: value)
            current.minute = wallClock.component(.minute, from: value)
            schedule = current.expression
        }
    }

    var body: some View {
        Section {
            Picker("Rythme", selection: rhythm) {
                ForEach(RoutineSchedule.Rhythm.allCases, id: \.self) { value in Text(value.title).tag(value.rawValue) }
                Text("Personnalisé").tag("custom")
            }.accessibilityIdentifier("routine.rhythm")
            if !customized, let parsed {
                if parsed.rhythm == .weekly {
                    Picker("Jour", selection: Binding(get: { parsed.weekday }, set: { value in
                        var updated = parsed; updated.weekday = value; schedule = updated.expression
                    })) {
                        ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                            Text(RoutineSchedule.weekdays[day].capitalized).tag(day)
                        }
                    }
                }
                if parsed.rhythm == .hourly {
                    Picker("À la minute", selection: Binding(get: { parsed.minute }, set: { value in
                        var updated = parsed; updated.minute = value; schedule = updated.expression
                    })) { ForEach(0..<60) { minute in Text(String(format: "%02d", minute)).tag(minute) } }
                } else {
                    DatePicker("Heure", selection: time, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, wallClock.timeZone).accessibilityIdentifier("routine.time")
                }
                Text(parsed.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            DisclosureGroup("Avancé", isExpanded: $advanced) {
                TextField("Horaire Hermès", text: Binding(get: { schedule }, set: { value in
                    schedule = value; customMode = true
                }), axis: .vertical)
                    .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("routine.rawSchedule")
                Text("Expression cron, intervalle (every 4h), délai unique (in 30m) ou date ISO. Hermès valide l’horaire à l’enregistrement.")
                    .font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier("routine.advanced")
        } header: { Text("Quand") }
        footer: { Text("Les horaires suivent le fuseau configuré dans Hermès pour ce profil, pas celui de l’iPhone.") }
        .onAppear { if !schedule.isEmpty, parsed == nil { advanced = true } }
        .onChange(of: schedule) { _, _ in if !schedule.isEmpty, parsed == nil { advanced = true } }
    }
}
