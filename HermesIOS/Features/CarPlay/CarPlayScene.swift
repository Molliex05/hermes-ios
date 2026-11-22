import CarPlay
import SwiftUI
import UIKit

/// Hermès on the car's own screen: a CarPlay voice-based conversational app (iOS 26.4). Inert until Apple's entitlement
/// `com.apple.developer.carplay-voice-based-conversation` is in the app's signature: without it CarPlay never lists the
/// app and never connects this scene. Declared in Info.plist (`CPTemplateApplicationSceneSessionRoleApplication`).
@objc(CarPlaySceneDelegate)
@MainActor final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        CarScreen.shared.connect(scene, interfaceController)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CarScreen.shared.disconnect()
    }

    // No call on opening: CarPlay reopens the last app when the car starts, and Maxime chose (2026-11-21) never to have
    // the microphone opened by surprise. The screen shows « Appeler <agent> » and its button starts the call.
}

/// The voice control template of the car's screen, kept in step with the call. It shows the agent's own animated orb
/// (as on the phone: each agent its look and colours), the call's state and two buttons (mute, hang up); never the
/// answer's text or a card, which Apple forbids at the wheel. Before a call, the bar's button picks the agent to call.
/// A reply that gives one place opens Plans on the car's screen with the driving route.
@MainActor final class CarScreen {
    static let shared = CarScreen()

    /// Installed by the app: the current agent's name and profile, used when no agent was picked on the car's screen.
    static var agentTitle: (() -> String?)?
    static var agentProfile: (() -> String?)?
    private static let pickedKey = "carplay.agent"

    private var scene: CPTemplateApplicationScene?
    private var interface: CPInterfaceController?
    private var template: CPVoiceControlTemplate?
    private var agent = ""
    private var profile = ""
    private var inCall = false
    private var state = CarVoiceScreen.State.idle
    private var shownDestinations = Set<String>()
    private var starting = false
    /// The orb's pictures per agent look and state: rendering them takes a moment, once.
    private var films: [String: UIImage] = [:]

    var connected: Bool { interface != nil }
    /// The car screen's own scale, for pictures that stay sharp there.
    private var displayScale: CGFloat { max(1, interface?.carTraitCollection.displayScale ?? 2) }

    func connect(_ scene: CPTemplateApplicationScene, _ interface: CPInterfaceController) {
        self.scene = scene; self.interface = interface
        template = nil
        if let call = VoiceCallRemote.current, call.tools.app.voiceActive {
            call.refreshCarScreen(open: false)  // builds the template on the call's state
        }
        if template == nil {
            (profile, agent) = pickedAgent()
            inCall = false; state = .idle
            rebuild()
        }
    }

    func disconnect() {
        scene = nil; interface = nil; template = nil
    }

    /// Called by the call on every change of phase or microphone (`paused` once it ends).
    func update(agent: String, profile: String, phase: String?, muted: Bool, destination: CarDestination?, open: Bool = true) {
        let state = CarVoiceScreen.state(phase: phase, muted: muted)
        let calling = state != .idle
        // Between calls the screen goes back to the agent picked on the car's screen.
        let (shownProfile, shownAgent) = calling ? (profile, agent) : pickedAgent()
        let changed = shownProfile != self.profile || shownAgent != self.agent || calling != inCall
        self.agent = shownAgent; self.profile = shownProfile; inCall = calling
        if let destination, connected, shownDestinations.insert(destination.messageID).inserted, open {
            scene?.open(destination.url, options: nil, completionHandler: nil)
        }
        guard connected else { self.state = state; return }
        if changed || template == nil { self.state = state; rebuild(); return }
        guard state != self.state else { return }
        self.state = state
        template?.activateVoiceControlState(withIdentifier: state.rawValue)
    }

    // MARK: Agent

    /// The agent picked on the car's screen, else the app's current one.
    private func pickedAgent() -> (profile: String, title: String) {
        let agents = SharedProfiles.read()
        if let picked = UserDefaults.standard.string(forKey: Self.pickedKey), let found = agents.first(where: { $0.name == picked }) {
            return (found.name, found.title.isEmpty ? found.name : found.title)
        }
        let current = Self.agentProfile?() ?? agents.first?.name ?? ""
        return (current, Self.agentTitle?() ?? agents.first { $0.name == current }?.title ?? "Hermès")
    }

    /// The list of agents, each with its picture; picking one makes it the one the screen calls.
    private func chooseAgent() {
        guard let interface, !inCall else { return }
        let side = CPListItem.maximumImageSize.width
        let items = SharedProfiles.read().map { saved -> CPListItem in
            let look = AgentLooks.shared.look(for: saved.name)
            let renderer = ImageRenderer(content: AgentNotificationPicture(look: look).frame(width: side, height: side))
            renderer.scale = displayScale
            let title = saved.title.isEmpty ? saved.name : saved.title
            let item = CPListItem(text: title, detailText: saved.name == profile ? "Agent choisi" : nil, image: renderer.uiImage)
            item.handler = { [weak self] _, done in
                MainActor.assumeIsolated {
                    UserDefaults.standard.set(saved.name, forKey: Self.pickedKey)
                    self?.profile = saved.name; self?.agent = title
                    self?.rebuild()
                    interface.popToRootTemplate(animated: true, completion: nil)
                }
                done()
            }
            return item
        }
        let list = CPListTemplate(title: "Agents", sections: [CPListSection(items: items)])
        interface.pushTemplate(list, animated: true, completion: nil)
    }

    // MARK: Template

    private func rebuild() {
        guard let interface else { return }
        let states = CarVoiceScreen.State.allCases.map(voiceState)
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        self.template = template
        setAgentButton(on: template)
        let active = state
        interface.setRootTemplate(template, animated: false) { _, _ in
            // The first state is shown until the template is up; only then can another be activated.
            Task { @MainActor in template.activateVoiceControlState(withIdentifier: active.rawValue) }
        }
    }

    /// The bar's « Jarvis ▾ » before a call. The template provides bar buttons from iOS 26.4 (its header declares them only
    /// for apps that require 26.4, so they are set by name once the template answers to them).
    private func setAgentButton(on template: CPVoiceControlTemplate) {
        let setter = NSSelectorFromString("setLeadingNavigationBarButtons:")
        guard template.responds(to: setter), SharedProfiles.read().count > 1 else { return }
        var buttons: [CPBarButton] = []
        if !inCall {
            buttons = [CPBarButton(title: "\(agent) ▾") { [weak self] _ in MainActor.assumeIsolated { self?.chooseAgent() } }]
        }
        template.setValue(buttons, forKey: "leadingNavigationBarButtons")
    }

    private func voiceState(_ state: CarVoiceScreen.State) -> CPVoiceControlState {
        let image = orb(for: state)
        let titles = CarVoiceScreen.titles(state, agent: agent)
        let voice: CPVoiceControlState
        if #available(iOS 27.0, *) {
            voice = CPVoiceControlState(identifier: state.rawValue, titleVariants: titles, image: image, backgroundImage: background(), repeats: true)
        } else {
            voice = CPVoiceControlState(identifier: state.rawValue, titleVariants: titles, image: image, repeats: true)
        }
        if #available(iOS 26.4, *) { voice.actionButtons = buttons(for: state) }
        return voice
    }

    /// The agent's orb for the state, animated as on the phone (still when idle or muted).
    private func orb(for state: CarVoiceScreen.State) -> UIImage? {
        let look = AgentLooks.shared.look(for: profile)
        let phase: OrbPhase = switch state {
        case .idle, .muted: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        }
        let key = "\(look.hashValue)-\(phase)"
        if let cached = films[key] { return cached }
        let film = OrbFilm.image(look: look, phase: phase, side: 150, scale: displayScale)
        films[key] = film
        return film
    }

    /// The agent's colours behind the screen (iOS 27): its deep shade fading to black, like the phone's call screen.
    private func background() -> UIImage? {
        guard let window = scene?.carWindow else { return nil }
        let palette = AgentLooks.shared.look(for: profile).palette
        let size = window.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = displayScale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(palette.deep).cgColor, UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            context.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: size.width / 2, y: size.height * 0.4), startRadius: 0,
                                                 endCenter: CGPoint(x: size.width / 2, y: size.height * 0.4), endRadius: max(size.width, size.height) * 0.7,
                                                 options: .drawsAfterEndLocation)
        }
    }

    @available(iOS 26.4, *)
    private func buttons(for state: CarVoiceScreen.State) -> [CPButton] {
        func button(_ title: String, _ symbol: String, _ action: @escaping @MainActor () -> Void) -> CPButton {
            let button = CPButton(image: UIImage(systemName: symbol) ?? UIImage()) { _ in MainActor.assumeIsolated { action() } }
            button.title = title
            return button
        }
        if state == .idle { return [button("Appeler", "phone.fill") { [weak self] in self?.startCall() }] }
        let toggle: @MainActor () -> Void = { VoiceCallRemote.current?.toggleMicrophone() }
        let microphone: CPButton = state == .muted ? button("Micro", "mic.fill", toggle) : button("Couper le micro", "mic.slash.fill", toggle)
        let hangUp: CPButton = button("Raccrocher", "phone.down.fill", { VoiceCallRemote.current?.endCall() })
        let limit = Int(CPVoiceControlState.maximumActionButtonCount)
        return Array([microphone, hangUp].prefix(max(limit, 0)))
    }

    // MARK: Call

    private func startCall() {
        guard !starting, let start = CallLauncher.start else { return }
        starting = true
        let profile = profile
        Task { @MainActor [weak self] in
            let problem = await start(profile.isEmpty ? nil : profile)
            self?.starting = false
            if let problem { self?.alert(problem) }
        }
    }

    /// A call that could not start says why, in a few words the driver can glance at.
    private func alert(_ message: String) {
        // CarPlay presents one template at a time: a second alert would be refused.
        guard let interface, interface.presentedTemplate == nil else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak interface] _ in
            MainActor.assumeIsolated { interface?.dismissTemplate(animated: true, completion: nil) }
        }
        interface.presentTemplate(CPAlertTemplate(titleVariants: [message, "L’appel n’a pas pu démarrer."], actions: [ok]), animated: true, completion: nil)
    }
}
