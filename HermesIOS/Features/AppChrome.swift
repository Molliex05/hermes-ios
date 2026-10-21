import SwiftUI
import UIKit

// MARK: - Chrome without Liquid Glass
//
// iOS 26+ draws glass behind toolbar buttons, the back button, the search field, menus, segmented
// controls and action sheets, and ignores UIDesignRequiresCompatibility on iOS 27. Everything below
// is opaque, AppTheme-styled replacement chrome.

// MARK: Navigation bar

/// A toolbar item whose shared glass background is hidden (identical to `ToolbarItem` otherwise).
struct AppToolbarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    @ViewBuilder let content: () -> Content

    init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: @escaping () -> Content) {
        self.placement = placement
        self.content = content
    }

    var body: some ToolbarContent {
        // `sharedBackgroundVisibility` exists only in the iOS 26 SDK (Swift 6.2); older toolchains (CI's Xcode 16.4) skip it.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: placement, content: content).sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement, content: content)
        }
        #else
        ToolbarItem(placement: placement, content: content)
        #endif
    }
}

/// Plain close glyph for sheets: 44pt hit target, no background circle.
struct AppCloseButton: View {
    var label = "Fermer"
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

private final class PushProbeController: UIViewController {
    var report: (Bool) -> Void = { _ in }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); evaluate() }
    override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); evaluate() }
    private func evaluate() {
        guard let nav = navigationController else { return }
        var host: UIViewController = self
        while let next = host.parent, next !== nav { host = next }
        report(nav.viewControllers.first !== host)
    }
}

private struct PushProbe: UIViewControllerRepresentable {
    @Binding var pushed: Bool
    func makeUIViewController(context: Context) -> UIViewController {
        let probe = PushProbeController()
        probe.report = { value in if value != pushed { pushed = value } }
        return probe
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

private struct AppNavigationBarModifier: ViewModifier {
    @State private var pushed = false
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .background(PushProbe(pushed: $pushed).frame(width: 0, height: 0).allowsHitTesting(false))
            .navigationBarBackButtonHidden(pushed).toggleStyle(AppToggleStyle())
            .toolbar {
                if pushed {
                    AppToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Retour").accessibilityIdentifier("nav-back")
                    }
                }
            }
    }
}

extension View {
    /// Pushed screens get a plain chevron instead of the system (glass) back button; roots are untouched.
    /// Already applied by `modernList()`; add it explicitly on pushed screens that are not lists.
    func appNavigationBar() -> some View { modifier(AppNavigationBarModifier()) }
}

/// Keeps the interactive swipe-back gesture alive when the system back button is hidden.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}

// MARK: Search

/// Replacement for `.searchable`: an opaque rounded field, placed as the first row of a list.
struct AppSearchField: View {
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text).focused($focused)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .accessibilityIdentifier("app-search-field")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Effacer la recherche").accessibilityIdentifier("app-search-clear")
            }
        }
        .padding(.leading, 14).padding(.trailing, text.isEmpty ? 14 : 0).frame(minHeight: 46)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.line))
    }
}

/// The search field as the first section of a list (no card background of its own).
struct AppSearchSection: View {
    @Binding var text: String
    var prompt: String
    var body: some View {
        Section {
            AppSearchField(text: $text, prompt: prompt)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
    }
}

// MARK: Menus

extension EnvironmentValues {
    @Entry var appMenuDismiss: @MainActor () -> Void = {}
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The scrolling, opaque panel shown inside menu popovers.
private struct AppMenuPanel<Content: View>: View {
    let dismiss: @MainActor () -> Void
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.vertical, 6)
                .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
        }
        .onPreferenceChange(ContentHeightKey.self) { height = $0 }
        .environment(\.appMenuDismiss, dismiss)
        .frame(width: 290, height: height > 0 ? min(height, 380) : 120)
        .presentationCompactAdaptation(.popover)
        .presentationBackground(AppTheme.surface)
    }
}

/// An opaque popover menu. Content is `AppMenuButton`s (and `Divider`s); tapping a button closes it.
struct AppMenu<Label: View, Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label
    @State private var open = false
    var body: some View {
        Button { open = true } label: { label() }
            .popover(isPresented: $open) { AppMenuPanel(dismiss: { open = false }, content: content) }
    }
}

/// Replacement for `.contextMenu`: a long press opens the same opaque popover.
private struct AppContextMenuModifier<Menu: View>: ViewModifier {
    @ViewBuilder let menu: () -> Menu
    @State private var open = false
    func body(content: Content) -> some View {
        content
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                open = true
            })
            .popover(isPresented: $open) { AppMenuPanel(dismiss: { open = false }, content: menu) }
    }
}

extension View {
    func appContextMenu<Menu: View>(@ViewBuilder _ menu: @escaping () -> Menu) -> some View { modifier(AppContextMenuModifier(menu: menu)) }
}

/// One row of an `AppMenu`.
struct AppMenuButton<Label: View>: View {
    var role: ButtonRole?
    var selected = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.appMenuDismiss) private var dismissMenu
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(role: role) {
            dismissMenu()
            action()
        } label: {
            HStack(spacing: 10) {
                label().frame(maxWidth: .infinity, alignment: .leading)
                if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.accent) }
            }
            .padding(.horizontal, 16).frame(minHeight: 46).contentShape(Rectangle())
        }
        .buttonStyle(AppMenuRowStyle(destructive: role == .destructive))
        .opacity(enabled ? 1 : 0.4)
    }
}

extension AppMenuButton where Label == AppMenuLabel {
    init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, selected: Bool = false, action: @escaping () -> Void) {
        self.init(role: role, selected: selected, action: action) { AppMenuLabel(title: title, systemImage: systemImage) }
    }
}

struct AppMenuLabel: View {
    let title: String
    var systemImage: String?
    var body: some View {
        HStack(spacing: 12) {
            if let systemImage { Image(systemName: systemImage).frame(width: 22) }
            Text(title).multilineTextAlignment(.leading)
        }
    }
}

private struct AppMenuRowStyle: ButtonStyle {
    let destructive: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
    }
}

/// Replacement for a menu-style `Picker`: a row with the current value that opens an opaque popover.
struct AppPicker<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var showsTitle = true
    var systemImage: String?
    var identifier: String?

    private var current: String { options.first { $0.value == selection }?.label ?? "" }

    var body: some View {
        AppMenu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                AppMenuButton(option.label, selected: option.value == selection) { selection = option.value }
            }
        } label: {
            HStack(spacing: 8) {
                if showsTitle {
                    if let systemImage { Label(title, systemImage: systemImage).foregroundStyle(.primary) } else { Text(title).foregroundStyle(.primary) }
                    Spacer(minLength: 12)
                }
                Text(current).foregroundStyle(showsTitle ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppTheme.accent)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityValue(current)
        .accessibilityIdentifier(identifier ?? "picker-\(title)")
    }
}

/// Replacement for a segmented `Picker`: a flat rounded track with an accent thumb.
struct AppSegmented<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var identifier: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.value == selection
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = option.value } } label: {
                    Text(option.label).font(.subheadline.weight(on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? AppTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("\(identifier ?? "segment")-\(option.label)")
            }
        }
        .padding(3).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? "segmented-\(title)")
    }
}

// MARK: Confirmations and alerts

/// Dialog buttons: full-width rounded buttons, styled by role. Tapping runs the action, then closes the dialog.
private struct AppDialogButtonStyle: PrimitiveButtonStyle {
    @Environment(\.appMenuDismiss) private var dismiss
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let cancel = configuration.role == .cancel
        configuration.label
            .font(.body.weight(cancel ? .regular : .semibold))
            .foregroundStyle(cancel ? Color.primary : Color.white)
            .frame(maxWidth: .infinity, minHeight: 50).padding(.horizontal, 12)
            .background(cancel ? Color.primary.opacity(0.08) : destructive ? Color.red : AppTheme.accent, in: RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? 1 : 0.45).contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { guard enabled else { return }; configuration.trigger(); dismiss() }
            .accessibilityAddTraits(.isButton)
    }
}

/// Title, message and buttons of a dialog (shared by the bottom card and the in-app notice overlay).
struct AppDialogContent<A: View, M: View>: View {
    let title: String
    var cancel: String?
    @ViewBuilder let actions: () -> A
    @ViewBuilder let message: () -> M
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(title).font(.system(.title3, design: .serif, weight: .semibold)).multilineTextAlignment(.center)
                message().font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                actions()
                if let cancel { Button(cancel, role: .cancel) {} }
            }
            .buttonStyle(AppDialogButtonStyle())
            .textFieldStyle(AppDialogFieldStyle())
        }
    }
}

private struct AppDialogSheet<A: View, M: View>: View {
    let title: String
    let cancel: String?
    @ViewBuilder let actions: () -> A
    @ViewBuilder let message: () -> M
    let close: @MainActor () -> Void
    @State private var height: CGFloat = 280
    var body: some View {
        AppDialogContent(title: title, cancel: cancel, actions: actions, message: message)
            .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 12)
            .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
            .onPreferenceChange(ContentHeightKey.self) { height = $0 }
            .environment(\.appMenuDismiss, close)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(AppTheme.background)
            .presentationDetents([.height(height + 8)])
            .presentationDragIndicator(.visible).presentationCornerRadius(30).presentationBackground(AppTheme.background)
    }
}

/// An in-app dialog that is not a presentation, so it works while a sheet is already open.
struct AppDialogOverlay<A: View, M: View>: View {
    let title: String
    @Binding var isPresented: Bool
    @ViewBuilder let actions: () -> A
    @ViewBuilder let message: () -> M
    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { isPresented = false }
                AppDialogContent(title: title, actions: actions, message: message)
                    .padding(20).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(AppTheme.line))
                    .padding(.horizontal, 24).frame(maxWidth: 460)
                    .environment(\.appMenuDismiss, { isPresented = false })
            }.transition(.opacity)
        }
    }
}

private struct AppDialogFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.padding(.horizontal, 14).frame(minHeight: 48)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.line))
    }
}

extension View {
    /// Replacement for `confirmationDialog` and `alert` (glass on iOS 26+): a compact opaque bottom card.
    func appAlert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, cancel: String? = nil, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        sheet(isPresented: isPresented) {
            AppDialogSheet(title: title, cancel: cancel, actions: actions, message: message, close: { isPresented.wrappedValue = false })
        }
    }
    func appAlert<A: View>(_ title: String, isPresented: Binding<Bool>, cancel: String? = nil, @ViewBuilder actions: @escaping () -> A) -> some View {
        appAlert(title, isPresented: isPresented, cancel: cancel, actions: actions) { EmptyView() }
    }
    func appConfirm<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, cancel: String? = "Annuler", @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        appAlert(title, isPresented: isPresented, cancel: cancel, actions: actions, message: message)
    }
    func appConfirm<A: View>(_ title: String, isPresented: Binding<Bool>, cancel: String? = "Annuler", @ViewBuilder actions: @escaping () -> A) -> some View {
        appAlert(title, isPresented: isPresented, cancel: cancel, actions: actions) { EmptyView() }
    }
}

// MARK: Buttons

/// Flat accent button (replaces `.borderedProminent`).
struct AppProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .background(AppTheme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Flat neutral button (replaces `.bordered`).
struct AppBorderedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: Cards

/// An explanatory paragraph at the top of a list: plain text on the background, no card.
struct AppIntro: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Section {
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
    }
}

// MARK: Toggle

/// Flat switch: the iOS 26+ system switch has a glass thumb.
struct AppToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? AppTheme.accent : Color.primary.opacity(0.2)).frame(width: 51, height: 31)
                    Circle().fill(Color.white).frame(width: 27, height: 27).padding(2).shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                }.animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.5)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}
