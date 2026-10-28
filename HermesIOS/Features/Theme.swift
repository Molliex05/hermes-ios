import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.81, green: 0.29, blue: 0.19)
    /// A warm stone that sits clearly below the white cards, so surfaces read as raised (the old cream was a hair from white).
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.055, green: 0.058, blue: 0.062, alpha: 1) : UIColor(red: 0.929, green: 0.914, blue: 0.886, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1) : .white })
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.11)
    /// Your messages: a soft wash of the accent with a fine accent edge, instead of one more white card.
    static let userBubble = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.81, green: 0.29, blue: 0.19, alpha: 0.24) : UIColor(red: 0.81, green: 0.29, blue: 0.19, alpha: 0.12) })
    static let userBubbleLine = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.81, green: 0.29, blue: 0.19, alpha: 0.38) : UIColor(red: 0.81, green: 0.29, blue: 0.19, alpha: 0.24) })
    static let colors: [Color] = [accent, Color(red: 0.3, green: 0.43, blue: 0.35), Color(red: 0.44, green: 0.39, blue: 0.59), Color(red: 0.38, green: 0.48, blue: 0.62)]
    static func color(_ name: String) -> Color { colors[name.utf8.reduce(0) { ($0 + Int($1)) % colors.count }] }

    /// Large navigation titles keep the serif voice of the app's headings; inline titles stay system.
    @MainActor static func configureNavigationBars() {
        let base = UIFont.preferredFont(forTextStyle: .largeTitle)
        guard let serif = base.fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.traitBold) ?? base.fontDescriptor.withDesign(.serif) else { return }
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFont(descriptor: serif, size: 0)]
    }
}

/// A soft two-layer lift for floating surfaces (pills, circles, the composer).
struct SoftShadow: ViewModifier {
    var strength = 1.0
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity((scheme == .dark ? 0.45 : 0.09) * strength), radius: 12, y: 4)
            .shadow(color: .black.opacity((scheme == .dark ? 0.30 : 0.06) * strength), radius: 1.5, y: 0.5)
    }
}

extension View {
    func softShadow(_ strength: Double = 1) -> some View { modifier(SoftShadow(strength: strength)) }
}

/// A gentle press: the control sinks a little and springs back.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// Closes the sheet presented over the chat, from any depth of its navigation stack.
/// Always equal: it only ever clears the chat's sheet, so updates never invalidate readers.
struct ReturnToChat: Equatable, Sendable {
    let action: @MainActor @Sendable () -> Void
    @MainActor func callAsFunction() { action() }
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var returnToChat: ReturnToChat? = nil
}

struct AgentMark: View {
    var size: CGFloat = 52
    var color: Color = AppTheme.accent
    var body: some View {
        ZStack {
            ForEach(0..<6) { index in
                Ellipse().fill(color)
                    .frame(width: size * 0.22, height: size * 0.52)
                    .offset(y: -size * 0.21)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
            Circle().fill(AppTheme.background).frame(width: size * 0.14)
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
            RoundedRectangle(cornerRadius: size * 0.34).fill(AppTheme.color(name).opacity(0.12))
            if name == "default" { AgentMark(size: size * 0.54) }
            else {
                Image(systemName: name == "research" ? "sparkle.magnifyingglass" : name == "studio" ? "pencil.and.outline" : "sparkle")
                    .font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(AppTheme.color(name))
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
                .frame(width: 44, height: 44).background(AppTheme.surface, in: Circle())
                .overlay(Circle().strokeBorder(AppTheme.line))
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
            }.padding(.vertical, 18).background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 22))
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
            // No bottom anchor for the initial offset (the list's `ScrollPosition` already starts at its end): with it, a
            // tall last row (a reply with a card) was dropped from the accessibility tree while still on screen.
            self.defaultScrollAnchor(.bottom, for: .sizeChanges).defaultScrollAnchor(.top, for: .alignment)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
    }
    /// Inset, rounded cards on the app background (rows keep the system grouped surface, which matches `AppTheme.surface`).
    func modernList() -> some View {
        listStyle(.insetGrouped).scrollContentBackground(.hidden).background(AppTheme.background)
            .environment(\.defaultMinListRowHeight, 54).listSectionSpacing(.custom(20)).toggleStyle(AppToggleStyle())
            .appNavigationBar()
    }
    func barBackground() -> some View { background(AppTheme.background) }
    func sheetChrome() -> some View { presentationDragIndicator(.visible).presentationCornerRadius(30).presentationBackground(AppTheme.background) }
    func hermesCard() -> some View {
        padding(20).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(AppTheme.line))
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
    }
}
