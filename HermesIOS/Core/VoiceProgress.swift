import Foundation

/// What the call says while the agent works, from the tool that is running: a fact the app sees, never a guess. A tool
/// without a line here stays silent (the « I'm on it » filler covers the wait instead). Each line is recorded once in the
/// agent's voice (`Resources/Progress/<clip>.pcm`, like the fillers): it plays at once, offline, and spends none of the
/// server's daily speech quota.
public enum VoiceProgress {
    public struct Line: Equatable, Sendable {
        public let clip: String
        public let text: String
    }

    /// Every line, by clip name: what `scripts/record_progress_lines.py` records.
    public static let lines: [String: String] = [
        "agenda-lire": "Je regarde ton agenda.",
        "agenda-ajout": "J’ajoute ça à ton agenda.",
        "agenda-modif": "Je modifie l’événement.",
        "agenda-retrait": "Je retire l’événement.",
        "courriels-lire": "Je regarde tes courriels.",
        "courriels-ranger": "Je range tes courriels.",
        "brouillon": "Je prépare le brouillon.",
        "meteo": "Je regarde la météo.",
        "nouvelles": "Je regarde les nouvelles.",
        "widget": "Je mets ton widget à jour.",
        "web-cherche": "Je cherche en ligne.",
        "web-page": "Je lis cette page web.",
        "comptes": "Je regarde tes comptes.",
    ]

    public static func line(for step: Transcript.ToolStep) -> Line? {
        let clip: String? = switch step.baseName {
        case "agenda_lister", "agenda_calendriers": "agenda-lire"
        case "agenda_creer": "agenda-ajout"
        case "agenda_modifier": "agenda-modif"
        case "agenda_supprimer": "agenda-retrait"
        case "gmail_chercher", "gmail_lire": "courriels-lire"
        case "gmail_trier", "gmail_dossiers": "courriels-ranger"
        case "gmail_brouillon": "brouillon"
        case "meteo": "meteo"
        case "nouvelles": "nouvelles"
        case "widget_publier", "widget_bloc": "widget"
        case "web_search": "web-cherche"
        case "web_extract", "browse", "browser_navigate": "web-page"
        case let name where name.hasPrefix("finance_"): "comptes"
        default: nil
        }
        return clip.flatMap { key in lines[key].map { Line(clip: key, text: $0) } }
    }
}
