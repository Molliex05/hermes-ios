import Foundation

/// Email cards (Jarvis, Gmail): a list of messages, one message read for Maxime, the result of a triage. The agent may pass
/// the fields of its tools as they are (`gmail_chercher`: id, de, objet, date, extrait, non_lu, dossiers; `gmail_lire`: a,
/// cc, pieces_jointes) and adds its own summary. An email's words are third-party text: the cards show them, and what a
/// card sends back to the agent is written by the app (the message id and a sender name reduced to plain characters),
/// never a subject or a snippet, so a hostile email cannot speak in Maxime's name.
extension ChatCard {
    struct Sender: Equatable {
        let name: String, address: String
        /// What a row shows: the name, else the address.
        var label: String { name.isEmpty ? address : name }
        var initial: String { label.first.map { String($0).uppercased() } ?? "?" }
        /// For a sentence the app sends: letters, digits, spaces and a little punctuation, short.
        var spoken: String {
            let kept = label.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -'.&".unicodeScalars.contains($0) }
            return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(30))
        }
    }

    struct Attachment: Equatable, Identifiable {
        enum Kind: Equatable { case pdf, image, sheet, document, other }
        let id: Int
        let name: String, size: String
        let kind: Kind
    }

    struct Email: Equatable, Identifiable {
        let id: Int
        /// Gmail's id, the one the agent's tools take back; empty when the card has none (then no action is offered).
        let messageID: String
        let sender: Sender
        let to: String, cc: String
        let subject: String
        /// The agent's one-line summary, else Gmail's snippet.
        let summary: String
        let date: Date?
        let unread: Bool
        let important: Bool
        /// Gmail folders (user labels), the system ones left out.
        let folders: [String]
        let attachments: [Attachment]
        /// Attachments known only by their number.
        let attachmentCount: Int

        var gmailURL: URL? { messageID.isEmpty || MailID.isNoriven(messageID) ? nil : URL(string: "https://mail.google.com/mail/u/0/#all/\(messageID)") }
        var hasAttachments: Bool { attachmentCount > 0 || !attachments.isEmpty }
        /// « le courriel de Hydro-Québec (18f2a9c0d1e2) », for what the app sends.
        var reference: String {
            let who = sender.spoken
            return who.isEmpty ? "le courriel \(messageID)" : "le courriel de \(who) (\(messageID))"
        }
    }

    /// One message, read: its header, what the agent understood of it, what it asks for.
    struct Message: Equatable {
        let email: Email
        let points: [String]
        /// A deadline or a date the message asks for, as the agent wrote it (« Avant le 13 novembre »).
        let due: String
        /// Follow-ups the agent proposes (« Ajouter à l'agenda »), sent as Maxime's reply when touched.
        let suggestions: [String]
    }

    struct Inbox: Equatable {
        let title: String
        let items: [Email]
        var unread: Int { items.filter(\.unread).count }
        var ids: [String] { items.map(\.messageID).filter { !$0.isEmpty } }
    }

    struct FolderCount: Equatable, Identifiable {
        let id: Int
        let name: String, count: Int
    }

    /// What a triage did: how many emails went in which folder, how many were archived, what is left for Maxime.
    struct Triage: Equatable {
        let title: String
        let folders: [FolderCount]
        let total: Int, archived: Int, drafts: Int
        /// Left in the inbox for Maxime: listed when the agent gave the messages, else only counted.
        let pending: [Email]
        let pendingCount: Int
    }

    static func emailKind(_ raw: String) -> String? {
        switch raw {
        case "emails", "courriels", "inbox", "boite", "boîte", "boite-de-reception", "boîte-de-réception", "messages", "mails", "liste-courriels": "emails"
        case "email", "courriel", "message", "mail", "lecture", "courriel-lu": "email"
        case "triage", "tri", "rangement", "classement", "courriels-ranges", "courriels-rangés": "triage"
        default: nil
        }
    }

    static func parseEmailCard(_ kind: String, _ json: JSONValue, title: String) -> ChatCard? {
        switch kind {
        case "emails":
            let rows = list(firstNonNull(json, "items", "messages", "courriels"), limit: maxRows)
            // Rows with neither a sender, an id nor a subject are a plain list (the older « courriels » cards).
            let mailKeys = ["de", "from", "expediteur", "expéditeur", "sender", "id", "objet", "subject"]
            guard rows.contains(where: { row in mailKeys.contains { !row[$0].isNull } }) else { return nil }
            let items = rows.enumerated().compactMap { email($1, id: $0) }
            return items.isEmpty ? nil : .emails(Inbox(title: title, items: items))
        case "email":
            let source = json["message"].object.isEmpty ? json : json["message"]
            guard let read = email(source, id: 0, summaryKeys: ["resume", "résumé", "summary"]) else { return nil }
            let points = strings(firstNonNull(json, "points", "a_retenir", "à_retenir", "key_points"), limit: 5, length: 140)
            return .email(Message(email: read, points: points, due: clean(firstString(json, "echeance", "échéance", "due", "date_limite"), 60),
                                  suggestions: strings(firstNonNull(json, "suggestions", "options", "replies"), limit: 3, length: 40)))
        case "triage":
            let folders = list(firstNonNull(json, "dossiers", "folders", "items")).enumerated().compactMap { index, value -> FolderCount? in
                let name = clean(value.string.isEmpty ? firstString(value, "nom", "dossier", "name", "folder", "title") : value.string, 60)
                let count = Int(number(firstNonNull(value, "nombre", "count", "n", "value")) ?? 0)
                return name.isEmpty ? nil : FolderCount(id: index, name: name, count: max(0, count))
            }
            let left = firstNonNull(json, "restants", "a_traiter", "à_traiter", "pending", "kept")
            let pending = list(left, limit: maxRows).enumerated().compactMap { email($1, id: $0) }
            let pendingCount = pending.isEmpty ? Int(number(left) ?? 0) : pending.count
            let total = Int(number(firstNonNull(json, "total", "ranges", "rangés", "sorted")) ?? Double(folders.map(\.count).reduce(0, +)))
            let triage = Triage(title: title, folders: folders, total: max(0, total),
                                archived: max(0, Int(number(firstNonNull(json, "archives", "archivés", "archived")) ?? 0)),
                                drafts: max(0, Int(number(firstNonNull(json, "brouillons", "drafts")) ?? 0)),
                                pending: pending, pendingCount: max(0, pendingCount))
            return folders.isEmpty && triage.total == 0 && pending.isEmpty && triage.archived == 0 ? nil : .triage(triage)
        default:
            return nil
        }
    }

    // MARK: Pieces

    private static func email(_ value: JSONValue, id: Int, summaryKeys: [String] = ["resume", "résumé", "summary"]) -> Email? {
        guard case .object = value else { return nil }
        let subject = clean(firstString(value, "objet", "subject", "title"), 140)
        let sender = sender(firstString(value, "de", "from", "expediteur", "expéditeur", "sender"))
        guard !subject.isEmpty || !sender.label.isEmpty else { return nil }
        let summary = summaryKeys.lazy.map { value[$0].string }.first { !$0.isEmpty } ?? firstString(value, "extrait", "snippet", "apercu", "aperçu")
        let rawID = firstString(value, "id", "message_id", "messageId")
        let files = value["pieces_jointes"].isNull ? value["attachments"] : value["pieces_jointes"]
        let attachments = files.array.prefix(8).enumerated().compactMap { index, file -> Attachment? in
            let name = clean(file.string.isEmpty ? firstString(file, "nom", "name", "filename") : file.string, 80)
            return name.isEmpty ? nil : Attachment(id: index, name: name, size: size(firstNonNull(file, "taille", "size")),
                                                   kind: attachmentKind(name: name, type: firstString(file, "type", "mime")))
        }
        let count: Int = switch files {
        case .bool(let some): some ? 1 : 0
        case .number: max(0, files.int)
        default: 0
        }
        let folders = (value["dossiers"].isNull ? value["folders"] : value["dossiers"]).array.prefix(6)
            .map { clean($0.string, 40) }.filter { !$0.isEmpty && !isSystemLabel($0) }
        let tone = value["tone"].string.lowercased()
        return Email(id: id, messageID: MailID.validMessage(rawID) ? rawID : "", sender: sender,
                     to: clean(firstString(value, "a", "à", "to"), 160), cc: clean(value["cc"].string, 160), subject: subject,
                     summary: clean(summary, 240), date: emailDate(firstString(value, "date", "recu", "reçu", "received")),
                     unread: flag(firstNonNull(value, "non_lu", "unread")), important: flag(value["important"]) || tone == "warning" || tone == "negative",
                     folders: Array(folders.prefix(3)), attachments: attachments, attachmentCount: attachments.isEmpty ? count : 0)
    }

    /// « Hydro-Québec <noreply@hydroquebec.com> », « "Julie T." <j@x.ca> » or a bare address.
    static func sender(_ raw: String) -> Sender {
        let text = clean(raw, 160)
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let address = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            let name = text[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return Sender(name: clean(name, 60), address: clean(address, 80))
        }
        return text.contains("@") ? Sender(name: "", address: clean(text, 80)) : Sender(name: clean(text, 60), address: "")
    }

    nonisolated(unsafe) private static let mailFormats: [DateFormatter] = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"].map { format in
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format; return formatter
    }
    nonisolated(unsafe) private static let isoDate = ISO8601DateFormatter()
    nonisolated(unsafe) private static let localMinute: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"; return formatter
    }()

    /// An email's Date header (« Sat, 1 Nov 2026 10:03:22 -0400 (EDT) ») or an ISO date written by the agent.
    static func emailDate(_ raw: String) -> Date? {
        let text = raw.replacing(/\s*\([^)]*\)\s*$/, with: "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for formatter in mailFormats { if let date = formatter.date(from: text) { return date } }
        return isoDate.date(from: text) ?? localMinute.date(from: String(text.prefix(16)))
    }

    private static func isSystemLabel(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["INBOX", "UNREAD", "IMPORTANT", "STARRED", "SENT", "DRAFT", "SPAM", "TRASH", "CHAT"].contains(upper) || upper.hasPrefix("CATEGORY_")
    }

    private static func flag(_ value: JSONValue) -> Bool {
        switch value {
        case .bool(let on): on
        case .string(let word): ["true", "oui", "yes", "1"].contains(word.lowercased())
        case .number(let n): n != 0
        default: false
        }
    }

    private static func strings(_ value: JSONValue, limit: Int, length: Int) -> [String] {
        Array(value.array.map { clean($0.string.isEmpty ? firstString($0, "text", "texte", "label") : $0.string, length) }.filter { !$0.isEmpty }.prefix(limit))
    }

    private static func size(_ value: JSONValue) -> String {
        guard let bytes = number(value), bytes > 0 else { return display(value).isEmpty ? "" : clean(display(value), 12) }
        return bytes < 1_000_000 ? "\(max(1, Int((bytes / 1_000).rounded()))) Ko" : String(format: "%.1f Mo", bytes / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }

    private static func attachmentKind(name: String, type: String) -> Attachment.Kind {
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? "", mime = type.lowercased()
        if ext == "pdf" || mime.contains("pdf") { return .pdf }
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) { return .image }
        if ["xls", "xlsx", "csv", "numbers"].contains(ext) || mime.contains("sheet") || mime.contains("csv") { return .sheet }
        if ["doc", "docx", "pages", "txt", "rtf"].contains(ext) || mime.contains("word") || mime.hasPrefix("text/") { return .document }
        return .other
    }
}
