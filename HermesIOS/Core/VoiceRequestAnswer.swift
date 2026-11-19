import Foundation

/// Answering the agent's requests by voice during a call: an approval (« oui, je t'autorise » / « non ») and a question with
/// choices. Pure and strict: an unclear answer is no answer, and the call asks again. Voice only ever approves once:
/// « pour la session » and « toujours » stay on the screen, and secrets (sudo, keys) are never spoken.
public enum VoiceRequestAnswer {
    public enum Approval: Equatable, Sendable { case approve, deny }

    /// The longest spoken answer still read as yes or no; past it, Maxime is saying something else.
    static let maxWords = 10

    public static func approval(_ heard: String) -> Approval? {
        let words = tokens(heard)
        guard !words.isEmpty, words.count <= maxWords else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        let yes = ["oui", "ouais", "ouaip", "ok", "okay", "daccord", "autorise", "autorises", "autoriser", "accepte", "accepter", "confirme", "permets", "go", "yes"]
            .contains { words.contains($0) } || [" vas y ", " fais le ", " c est bon ", " pas de probleme ", " pas de souci "].contains { text.contains($0) }
        let no = ["non", "refuse", "refuser", "refuses", "jamais", "annule", "annuler", "nope", "no"].contains { words.contains($0) }
            || (words.contains("pas") && !text.contains(" pas de probleme ") && !text.contains(" pas de souci "))
        // « Je ne t'autorise pas » : a verb of consent under a negation is a no.
        let consent = ["autorise", "autorises", "autoriser", "accepte", "accepter", "confirme", "permets"].contains { words.contains($0) }
        if consent, words.contains("pas"), words.contains("ne") || words.contains("n") { return .deny }
        switch (yes, no) {
        case (true, false): return .approve
        case (false, true): return .deny
        default: return nil
        }
    }

    /// The choice Maxime said: by name (whole or part), or by rank (« la deuxième », « 2 »). Nil when none or several match.
    public static func choice(_ heard: String, among choices: [String]) -> String? {
        let said = tokens(heard)
        guard !said.isEmpty, !choices.isEmpty else { return nil }
        let joined = said.joined(separator: " ")
        // Articles and fillers do not name anything: « le Costco » names « Costco Candiac ».
        let filler: Set<String> = ["le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "au", "aux", "a", "celui", "celle", "chez", "plutot", "euh", "ben"]
        let content = said.filter { !filler.contains($0) }
        let named = choices.filter { option in
            let optionWords = tokens(option)
            let words = optionWords.joined(separator: " ")
            guard !words.isEmpty else { return false }
            if joined == words || " \(joined) ".contains(" \(words) ") { return true }
            return !content.isEmpty && content.allSatisfy { word in word.count >= 2 && optionWords.contains(word) }
        }
        if named.count == 1 { return named[0] }
        if named.count > 1 { return named.max { tokens($0).count < tokens($1).count }.flatMap { best in
            named.filter { tokens($0).count == tokens(best).count }.count == 1 ? best : nil } }
        let ranks = [["1", "un", "une", "premier", "premiere"], ["2", "deux", "deuxieme", "second", "seconde"], ["3", "trois", "troisieme"],
                     ["4", "quatre", "quatrieme"], ["5", "cinq", "cinquieme"]]
        let hits = ranks.indices.filter { index in index < choices.count && ranks[index].contains { said.contains($0) } }
        return hits.count == 1 && said.count <= 4 ? choices[hits[0]] : nil
    }

    /// What the call says when the agent asks for an approval. The command itself is on the screen, never read aloud.
    public static func approvalQuestion(agent: String) -> String {
        let name = agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "L’agent" : agent
        return "\(name) demande votre accord pour une commande, affichée à l’écran. Vous autorisez ? Répondez oui ou non."
    }

    public static func choiceQuestion(_ question: String, choices: [String]) -> String {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !options.isEmpty else { return asked }
        let list = options.count == 1 ? options[0] : options.dropLast().joined(separator: ", ") + " ou " + options.last!
        return "\(asked) \(list) ?"
    }

    public static let notUnderstood = "Je n’ai pas compris. Répondez oui ou non."
    public static let answerOnScreen = "Répondez à l’écran quand vous pourrez."

    /// Lowercased words without accents or punctuation: « Je t’autorise ! » → ["je", "t", "autorise"].
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
            .replacingOccurrences(of: "d'accord", with: "daccord").replacingOccurrences(of: "d’accord", with: "daccord")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
