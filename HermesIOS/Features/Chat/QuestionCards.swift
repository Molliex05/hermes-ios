import SwiftUI

/// One question at a time: its answers as large rows (letter or symbol, an optional line), a free answer, the progress
/// among several questions. Used by the agent's `choices` cards and by Hermes' own clarification requests.
struct QuestionStep: View {
    var title = "Question"
    let prompt: String
    let options: [ChatCard.Option]
    let multiple: Bool
    let allowsOther: Bool
    /// Where this question stands when there are several (0-based), nil for a single one.
    var position: (index: Int, count: Int)?
    var enabled = true
    /// The button that confirms a multiple choice.
    var finishLabel = "Envoyer"
    let answer: (String) -> Void
    var back: (() -> Void)?
    var skip: (label: String, action: () -> Void)?

    @State private var picked: Set<Int> = []
    @State private var tapped: Int?
    @State private var writing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !prompt.isEmpty {
                Text(prompt).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if multiple { Text("Plusieurs réponses possibles").font(.caption).foregroundStyle(.secondary).padding(.top, -8) }
            VStack(spacing: 8) {
                ForEach(options) { option in row(option) }
                if allowsOther { other }
            }
            if back != nil || skip != nil || multiple { footer }
        }
        .padding(16).cardSurface()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.caption.weight(.bold)).foregroundStyle(AppTheme.accent)
            Text(position.map { "\(title) \($0.index + 1) sur \($0.count)" } ?? title)
                .font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer(minLength: 0)
            if let position, position.count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<position.count, id: \.self) { index in
                        Capsule().fill(index <= position.index ? AppTheme.accent : AppTheme.line)
                            .frame(width: index == position.index ? 18 : 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func row(_ option: ChatCard.Option) -> some View {
        let selected = multiple ? picked.contains(option.id) : tapped == option.id
        return Button { choose(option) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? AppTheme.accent : AppTheme.accent.opacity(0.12))
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).transition(.scale.combined(with: .opacity))
                    } else if !option.icon.isEmpty, UIImage(systemName: option.icon) != nil {
                        Image(systemName: option.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.accent)
                    } else {
                        Text(Self.letter(option.id)).font(.system(.subheadline, design: .rounded).weight(.bold)).foregroundStyle(AppTheme.accent)
                    }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.body.weight(.medium)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                if !multiple { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(selected ? AppTheme.accent.opacity(0.1) : AppTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? AppTheme.accent.opacity(0.6) : AppTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled || tapped != nil)
        .opacity(enabled ? 1 : 0.6)
        .accessibilityLabel(option.detail.isEmpty ? option.label : "\(option.label), \(option.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var other: some View {
        if writing {
            HStack(spacing: 8) {
                // One line: the keyboard's Envoyer sends (a field that grows would insert a line break instead).
                TextField("Votre réponse…", text: $text)
                    .focused($focused).submitLabel(.send).onSubmit(sendTyped)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(AppTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.accent.opacity(0.5)))
                Button(action: sendTyped) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                    .foregroundStyle(AppTheme.accent).disabled(typed.isEmpty || !enabled).opacity(typed.isEmpty ? 0.4 : 1)
                    .accessibilityLabel("Envoyer cette réponse")
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            Button {
                Haptics.select()
                withAnimation(.snappy(duration: 0.25)) { writing = true }
                Task { try? await Task.sleep(for: .milliseconds(150)); focused = true }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        Image(systemName: "pencil").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .frame(width: 30, height: 30)
                    Text("Autre réponse…").font(.body).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle()).disabled(!enabled || tapped != nil)
            .accessibilityLabel("Autre réponse…")
        }
    }

    /// Held while a tapped answer is on its way, so it cannot land on another question.
    private var footer: some View {
        HStack(spacing: 16) {
            if let back {
                Button { Haptics.select(); back() } label: { Label("Précédente", systemImage: "chevron.left").font(.subheadline.weight(.medium)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!enabled || tapped != nil)
            }
            if let skip {
                Button(skip.label) { skip.action() }.font(.subheadline).buttonStyle(.plain).foregroundStyle(.secondary).disabled(!enabled || tapped != nil)
            }
            Spacer(minLength: 0)
            if multiple {
                let ready = !picked.isEmpty || !typed.isEmpty
                Button(action: finish) {
                    Text(finishLabel).font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 9)
                        .foregroundStyle(.white).background(AppTheme.accent, in: Capsule())
                }
                .buttonStyle(PressableStyle()).disabled(!ready || !enabled).opacity(ready ? 1 : 0.4)
            }
        }
    }

    private func choose(_ option: ChatCard.Option) {
        Haptics.select()
        if multiple {
            withAnimation(.snappy(duration: 0.2)) { if picked.contains(option.id) { picked.remove(option.id) } else { picked.insert(option.id) } }
            return
        }
        // The choice shows as ticked for a moment, then it is answered.
        withAnimation(.snappy(duration: 0.2)) { tapped = option.id }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            answer(option.reply)
            tapped = nil
        }
    }

    private func sendTyped() {
        guard !typed.isEmpty, enabled, tapped == nil else { return }
        // The text stays until the next question replaces this one: an answer that could not be sent is not lost.
        if multiple { finish() } else { focused = false; answer(typed) }
    }

    private func finish() {
        let chosen = options.filter { picked.contains($0.id) }.map(\.reply) + (typed.isEmpty ? [] : [typed])
        guard !chosen.isEmpty else { return }
        focused = false
        answer(chosen.joined(separator: ", "))
    }

    private static func letter(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJ")
        return index < letters.count ? String(letters[index]) : "\(index + 1)"
    }
}

// MARK: - The agent's choices card

/// A `choices` card: short follow-ups stay quick-reply pills; real questions are asked one at a time and their answers
/// sent together, as one message, once the last one is answered.
struct ChoicesCard: View {
    let choices: ChatCard.Choices
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    @State private var step = 0
    @State private var answers: [String] = []
    @State private var sent: [String]?
    private var live: Bool { reply != nil && interactive }

    var body: some View {
        let questions = choices.questions, count = questions.count
        ZStack {
            if choices.isQuick {
                QuickReplies(options: questions[0].options)
            } else if let sent {
                SentAnswers(questions: questions, answers: sent)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if !live {
                // An older reply (or no chat around): the question as it was asked, at rest.
                QuestionStep(prompt: questions[0].prompt, options: questions[0].options, multiple: questions[0].multiple, allowsOther: false,
                             position: count > 1 ? (0, count) : nil, enabled: false, answer: { _ in })
            } else {
                let question = questions[min(step, count - 1)]
                QuestionStep(prompt: question.prompt, options: question.options, multiple: question.multiple, allowsOther: choices.other,
                             position: count > 1 ? (step, count) : nil,
                             finishLabel: step + 1 < count ? "Continuer" : "Envoyer",
                             answer: advance,
                             back: step > 0 ? { withAnimation(.snappy(duration: 0.35)) { if !answers.isEmpty { answers.removeLast() }; step = answers.count } } : nil)
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .accessibilityIdentifier("card-choices")
    }

    private func advance(_ answer: String) {
        let all = answers + [answer]
        if all.count < choices.questions.count {
            withAnimation(.snappy(duration: 0.35)) { answers = all; step += 1 }
            return
        }
        let message = choices.questions.count == 1 ? answer
            : zip(choices.questions, all).map { question, answer in question.prompt.isEmpty ? answer : "\(question.prompt) \(answer)" }.joined(separator: "\n")
        guard let reply, reply.send(message) else { return }
        Haptics.send()
        withAnimation(.snappy(duration: 0.3)) { sent = all }
    }
}

/// What was answered, once sent: the card stays as a short record instead of vanishing.
private struct SentAnswers: View {
    let questions: [ChatCard.Question]
    let answers: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(answers.count > 1 ? "Réponses envoyées" : "Réponse envoyée", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.bold)).foregroundStyle(CardPalette.positive).textCase(.uppercase)
            ForEach(Array(zip(questions, answers).enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 2) {
                    if !pair.0.prompt.isEmpty { Text(pair.0.prompt).font(.caption).foregroundStyle(.secondary) }
                    Text(pair.1).font(.subheadline.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// A few short follow-ups under a reply: pills that arrive one after another; the one tapped is sent and stays lit.
private struct QuickReplies: View {
    let options: [ChatCard.Option]
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chosen: Int?
    @State private var shown = false
    private var live: Bool { reply != nil && interactive && chosen == nil }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options) { option in
                let picked = chosen == option.id
                Button {
                    guard live, let reply, reply.send(option.reply) else { return }
                    Haptics.send(); chosen = option.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: picked ? "checkmark" : "arrow.turn.down.right").font(.caption.weight(.bold))
                        Text(option.label).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(picked ? Color.white : AppTheme.accent)
                    .background(picked ? AppTheme.accent : AppTheme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(AppTheme.accent.opacity(picked ? 0 : 0.35)))
                    .softShadow(picked ? 0.8 : 0.3)
                }
                .buttonStyle(PressableStyle())
                .disabled(!live)
                .opacity(chosen != nil && !picked ? 0.45 : chosen == nil && !live ? 0.6 : 1)
                .opacity(shown || reduceMotion ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 8)
                .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(option.id) * 0.06), value: shown)
                .accessibilityLabel(option.label)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: chosen)
        .onAppear { shown = true }
    }
}
