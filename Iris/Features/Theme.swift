import SwiftUI

enum IrisTheme {
    static let accent = Color(red: 0.81, green: 0.29, blue: 0.19)
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.075, green: 0.08, blue: 0.08, alpha: 1) : UIColor(red: 0.973, green: 0.965, blue: 0.947, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : .white })
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.08)
    static let colors: [Color] = [accent, Color(red: 0.3, green: 0.43, blue: 0.35), Color(red: 0.44, green: 0.39, blue: 0.59), Color(red: 0.38, green: 0.48, blue: 0.62)]
    static func color(_ name: String) -> Color { colors[name.utf8.reduce(0) { ($0 + Int($1)) % colors.count }] }
}

struct IrisMark: View {
    var size: CGFloat = 52
    var color: Color = IrisTheme.accent
    var body: some View {
        ZStack {
            ForEach(0..<6) { index in
                Ellipse().fill(color)
                    .frame(width: size * 0.22, height: size * 0.52)
                    .offset(y: -size * 0.21)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
            Circle().fill(IrisTheme.background).frame(width: size * 0.14)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 48
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34).fill(IrisTheme.color(name).opacity(0.12))
            if name == "default" { IrisMark(size: size * 0.54) }
            else {
                Image(systemName: name == "research" ? "sparkle.magnifyingglass" : name == "studio" ? "pencil.and.outline" : "sparkle")
                    .font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(IrisTheme.color(name))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct RoundButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44).background(IrisTheme.surface, in: Circle())
                .overlay(Circle().strokeBorder(IrisTheme.line))
        }.foregroundStyle(.primary).accessibilityLabel(label)
    }
}

struct PrimaryButton: View {
    var title: String
    var symbol: String = "arrow.right"
    var busy = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text(title).fontWeight(.semibold)
                if busy { ProgressView().tint(.white) }
                else { Image(systemName: symbol) }
                Spacer()
            }.padding(.vertical, 18).background(IrisTheme.accent, in: RoundedRectangle(cornerRadius: 22))
        }.foregroundStyle(.white).disabled(busy)
    }
}

struct ConnectionIndicator: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.state == .connected ? Color.green.opacity(0.8) : Color.orange).frame(width: 5, height: 5)
            Text(model.demo ? "Aperçu interactif" : model.state == .connected ? "Connecté à Hermes" : model.state == .signInRequired ? "Connexion expirée" : model.state == .connecting ? "Reconnexion…" : "Hors ligne · brouillon conservé")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

extension View {
    @ViewBuilder func chatScrollAnchors() -> some View {
        if #available(iOS 18.0, *) {
            self.defaultScrollAnchor(.bottom).defaultScrollAnchor(.top, for: .alignment)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
    }
    func irisCard() -> some View {
        padding(20).background(IrisTheme.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(IrisTheme.line))
    }
}
