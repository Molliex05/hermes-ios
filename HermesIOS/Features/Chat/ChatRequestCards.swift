import SwiftUI

// Cards for Hermes server→client requests. Payload = the request params plus `rpc_id`,
// `rpc_method` and `event_type` ("<method>.request") added by the app (see ServerRequests).
// Each card is Equatable on its payload so stream flushes never re-render it.

/// approval: {request_id, command, description, choices: [once|session|always|deny],
/// allow_permanent?, allow_session?, smart_denied?, tool_name?}
struct ApprovalCard: View, Equatable {
    let payload: JSONValue
    let model: AppModel
    @State private var persistent = false
    @State private var busy = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.payload == rhs.payload }

    private var choices: [JSONValue] { payload["choices"].array }
    /// The smart evaluation refused the command: the owner may only override it once.
    private var smartDenied: Bool { payload["smart_denied"].bool }
    private var allowsSession: Bool { choices.contains("session") && !smartDenied && payload["allow_session"] != .bool(false) }
    private var allowsAlways: Bool { choices.contains("always") && !smartDenied && payload["allow_permanent"] != .bool(false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Hermes vous demande l’accord", systemImage: "hand.raised").font(.subheadline.weight(.semibold))
                if !payload["tool_name"].string.isEmpty {
                    Text("Outil : \(payload["tool_name"].string)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !payload["command"].string.isEmpty {
                Text(payload["command"].string).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if !payload["description"].string.isEmpty { Text(payload["description"].string).font(.caption).foregroundStyle(.secondary) }
            if smartDenied {
                Label("L’évaluation automatique de Hermes a refusé cette action. Vous pouvez seulement l’autoriser pour cette fois.", systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(AppTheme.accent)
            }
            HStack {
                Button("Refuser") { answer("deny") }.buttonStyle(AppBorderedButtonStyle())
                Spacer()
                if choices.contains(.string("once")) {
                    Button("Autoriser une fois") { answer("once") }.buttonStyle(AppProminentButtonStyle())
                }
            }.font(.caption).disabled(busy)
            if allowsSession || allowsAlways {
                AppMenu {
                    if allowsSession { AppMenuButton("Pour cette session") { answer("session") } }
                    if allowsAlways { AppMenuButton("Toujours pour cette règle") { persistent = true } }
                } label: {
                    HStack(spacing: 4) { Text("Autres autorisations"); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                        .font(.caption.weight(.medium)).foregroundStyle(AppTheme.accent).frame(minHeight: 44)
                }.buttonStyle(.plain).disabled(busy)
            }
        }.hermesCard()
            .appConfirm("Autoriser durablement cette règle pour cet agent ?", isPresented: $persistent) {
                Button("Toujours autoriser cette règle") { answer("always") }
            }
    }

    private func answer(_ choice: String) { busy = true; Task { await model.answerApproval(choice, request: payload); busy = false } }
}

/// sudo: {command} · secret: {env_var, prompt, metadata?} · vault.code: {site?, hint?}
/// · vault.unlock_prompt: {backend, display_name}. All are answered with one value ("" declines).
struct CredentialCard: View, Equatable {
    let payload: JSONValue
    let model: AppModel
    @State private var value = ""
    @State private var busy = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.payload == rhs.payload }

    private enum Kind { case sudo, secret, verificationCode, vaultUnlock }

    private var kind: Kind {
        var method = payload["rpc_method"].string
        if method.isEmpty {
            let event = payload["event_type"].string
            method = event.hasSuffix(".request") ? String(event.dropLast(".request".count)) : event
        }
        switch method {
        case "sudo": return .sudo
        case "vault.code": return .verificationCode
        case "vault.unlock_prompt": return .vaultUnlock
        default: return .secret
        }
    }

    var body: some View {
        let kind = kind
        VStack(alignment: .leading, spacing: 14) {
            switch kind {
            case .sudo:
                Label("Accès administrateur demandé", systemImage: "key").font(.subheadline.weight(.semibold))
                if !payload["command"].string.isEmpty {
                    Text(payload["command"].string).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                prompt
            case .secret:
                Label("Hermes demande un secret", systemImage: "key").font(.subheadline.weight(.semibold))
                prompt
                if !payload["env_var"].string.isEmpty {
                    Text(payload["env_var"].string).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).accessibilityLabel("Variable \(payload["env_var"].string)")
                }
            case .verificationCode:
                Label("Code de vérification", systemImage: "number").font(.subheadline.weight(.semibold))
                if !payload["site"].string.isEmpty { Text("Pour \(payload["site"].string)").font(.caption).foregroundStyle(.secondary) }
                if !payload["hint"].string.isEmpty { Text(payload["hint"].string).font(.caption).foregroundStyle(.secondary) }
            case .vaultUnlock:
                Label("Déverrouiller le coffre", systemImage: "lock.open").font(.subheadline.weight(.semibold))
                let name = payload["display_name"].string.isEmpty ? payload["backend"].string : payload["display_name"].string
                if !name.isEmpty { Text(name).font(.caption).foregroundStyle(.secondary) }
            }
            if kind == .verificationCode {
                TextField("Code reçu", text: $value).textFieldStyle(.roundedBorder)
                    .textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled()
            } else {
                SecureField(kind == .sudo ? "Mot de passe administrateur" : kind == .vaultUnlock ? "Mot de passe du coffre" : "Valeur envoyée directement à Hermes", text: $value)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Annuler") { respond("") }.buttonStyle(AppBorderedButtonStyle())
                Spacer()
                Button("Transmettre") { respond(value) }.buttonStyle(AppProminentButtonStyle()).disabled(value.isEmpty)
            }.disabled(busy)
            Text("Cette valeur ne sera pas conservée dans l’historique local.").font(.caption2).foregroundStyle(.secondary)
        }.hermesCard()
    }

    @ViewBuilder private var prompt: some View {
        if !payload["prompt"].string.isEmpty { Text(payload["prompt"].string).font(.caption).foregroundStyle(.secondary) }
    }

    private func respond(_ text: String) {
        busy = true
        Task { if await model.answerCredential(text, request: payload) { value = "" }; busy = false }
    }
}

/// clarify: {questions: [{qid, question, choices?, multi_select}], answers?}. Every question is
/// answered on its own with `clarify.lock` (qid); the last lock resolves the request.
struct ClarificationCard: View, Equatable {
    let payload: JSONValue
    let model: AppModel
    @State private var busy = false
    @State private var answered = Set<String>()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.payload == rhs.payload }

    struct Question: Identifiable {
        let id: String
        let question: String
        let choices: [String]
        let multiSelect: Bool
    }

    /// Questions not yet answered according to the payload (`answers` replays accepted locks,
    /// including skipped ones as null).
    static func pendingQuestions(_ payload: JSONValue) -> [Question] {
        let locked = payload["answers"].object
        return payload["questions"].array.compactMap { q -> Question? in
            let qid = q["qid"].string, text = q["question"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !qid.isEmpty, !text.isEmpty, locked[qid] == nil else { return nil }
            return Question(id: qid, question: text, choices: q["choices"].array.map(\.string), multiSelect: q["multi_select"].bool)
        }
    }

    static func hasPendingQuestions(_ payload: JSONValue) -> Bool { !pendingQuestions(payload).isEmpty }

    var body: some View {
        let pending = Self.pendingQuestions(payload).filter { !answered.contains($0.id) }
        let total = max(payload["questions"].array.count, pending.count)
        // One question at a time; an answered one gives way to the next at once, no empty card while the sync catches up.
        if let question = pending.first {
            QuestionStep(prompt: question.question,
                         options: question.choices.enumerated().map { ChatCard.Option(id: $0.offset, label: $0.element, reply: $0.element, detail: "", icon: "") },
                         multiple: question.multiSelect, allowsOther: true,
                         position: total > 1 ? (total - pending.count, total) : nil, enabled: !busy, finishLabel: "Répondre",
                         answer: { respond($0, to: question) },
                         skip: (label: "Ne pas répondre", action: {
                             busy = true
                             Task { _ = await model.dismissClarification(request: payload); busy = false }
                         }))
                .id(question.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                .accessibilityIdentifier("clarification-card")
        }
    }

    private func respond(_ text: String, to q: Question) {
        busy = true
        Task {
            if await model.answerClarification(text, request: payload, qid: q.id) {
                _ = withAnimation(.snappy(duration: 0.35)) { answered.insert(q.id) }
            }
            busy = false
        }
    }
}
