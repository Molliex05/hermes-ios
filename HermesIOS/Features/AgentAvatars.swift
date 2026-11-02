import SwiftUI

/// Draws each agent's still illustration on a disc of its colour and hands it to the notification extension
/// (`NotificationAvatar`). Done when the agents load and when a look changes; an unchanged look is not drawn again.
@MainActor enum AgentAvatars {
    private static var published: [String: AgentLook] = [:]

    static func publish(_ profiles: [String]) {
        for profile in profiles {
            let look = AgentLooks.shared.look(for: profile)
            guard published[profile] != look else { continue }
            let renderer = ImageRenderer(content: AgentNotificationPicture(look: look).frame(width: 60, height: 60))
            renderer.scale = 3
            guard let png = renderer.uiImage?.pngData(), NotificationAvatar.store(png, for: profile) else { continue }
            published[profile] = look
        }
    }
}
