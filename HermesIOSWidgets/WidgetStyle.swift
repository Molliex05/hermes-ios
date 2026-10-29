import SwiftUI

/// The widgets' colours: the app's ember accent on its sand page (light) or near-black (dark).
enum WidgetPalette {
    static let accent = Color(red: 0.81, green: 0.29, blue: 0.19)
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.075, green: 0.08, blue: 0.08) : Color(red: 0.973, green: 0.965, blue: 0.947)
    }
}

struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { WidgetPalette.background(scheme) }
}
