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
    // the microphone opened by surprise. The screen lists the agents; a touch on one calls it.
}

/// The car's screen. Between calls, the list of agents, each with its own orb: a touch on one calls it at once. During a
/// call, the voice control template with the agent's animated orb (as on the phone: each agent its look and colours), the
/// call's state and two buttons (mute, hang up); never the answer's text or a card, which Apple forbids at the wheel.
/// A reply that gives one place opens Plans on the car's screen with the driving route.
@MainActor final class CarScreen {
    static let shared = CarScreen()

    /// Installed by the app: the current agent's name and profile, used when no agent was called from the car yet.
    static var agentTitle: (() -> String?)?
    static var agentProfile: (() -> String?)?
    private static let pickedKey = "carplay.agent"

    private var scene: CPTemplateApplicationScene?
    private var interface: CPInterfaceController?
    private var template: CPVoiceControlTemplate?
    private var agents: CPListTemplate?
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
        template = nil; agents = nil
        if let call = VoiceCallRemote.current, call.tools.app.voiceActive {
            call.refreshCarScreen(open: false)  // shows the call's own screen
        }
        if !inCall || template == nil {
            inCall = false; state = .idle
            showAgents()
        }
    }

    func disconnect() {
        scene = nil; interface = nil; template = nil; agents = nil
    }

    /// Called by the call on every change of phase or microphone (`paused` once it ends).
    func update(agent: String, profile: String, phase: String?, muted: Bool, destination: CarDestination?, open: Bool = true) {
        let state = CarVoiceScreen.state(phase: phase, muted: muted)
        let calling = state != .idle
        if let destination, connected, shownDestinations.insert(destination.messageID).inserted, open {
            scene?.open(destination.url, options: nil, completionHandler: nil)
        }
        defer { self.state = state }
        guard calling else {
            // The call ended: back to the agents, the one just called first.
            if inCall || agents == nil { inCall = false; if connected { showAgents() } }
            return
        }
        let changed = !inCall || profile != self.profile || template == nil
        self.agent = agent; self.profile = profile; inCall = true
        guard connected else { return }
        if changed { self.state = state; showCall(); return }
        guard state != self.state else { return }
        template?.activateVoiceControlState(withIdentifier: state.rawValue)
    }

    // MARK: Agents

    /// Every agent, the last one called first, each with its orb; a touch calls it.
    private func showAgents() {
        guard let interface else { return }
        template = nil
        let saved = SharedProfiles.read()
        let last = UserDefaults.standard.string(forKey: Self.pickedKey) ?? Self.agentProfile?() ?? ""
        var entries = saved.map { (profile: $0.name, title: $0.title.isEmpty ? $0.name : $0.title) }
        if entries.isEmpty, let current = Self.agentProfile?() {
            entries = [(current, Self.agentTitle?() ?? "Hermès")]
        }
        entries.sort { ($0.profile == last ? 0 : 1) < ($1.profile == last ? 0 : 1) }
        let side = CPListItem.maximumImageSize.width
        let items = entries.map { entry -> CPListItem in
            let look = AgentLooks.shared.look(for: entry.profile)
            let image = OrbFilm.image(look: look, phase: .idle, side: side, scale: displayScale) ?? UIImage(systemName: "phone.circle.fill")
            let item = CPListItem(text: "Appeler \(entry.title)", detailText: entry.profile == last ? "Dernier appelé" : nil, image: image)
            item.accessoryType = .none
            item.handler = { [weak self] _, done in
                MainActor.assumeIsolated { self?.startCall(profile: entry.profile, title: entry.title) }
                done()
            }
            return item
        }
        let list = CPListTemplate(title: "Appeler", sections: [CPListSection(items: items)])
        list.emptyViewTitleVariants = ["Aucun agent", "Ouvrez Hermès sur l’iPhone"]
        agents = list
        interface.setRootTemplate(list, animated: false, completion: nil)
    }

    // MARK: Call screen

    private func showCall() {
        guard let interface else { return }
        let states = CarVoiceScreen.State.allCases.filter { $0 != .idle }.map(voiceState)
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        self.template = template; agents = nil
        let active = state == .idle ? CarVoiceScreen.State.thinking : state
        interface.setRootTemplate(template, animated: true) { _, _ in
            // The first state is shown until the template is up; only then can another be activated.
            Task { @MainActor in template.activateVoiceControlState(withIdentifier: active.rawValue) }
        }
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

    /// The agent's orb for the state, animated as on the phone (still when muted).
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
        let symbol = state == .muted ? "mic.slash.fill" : "waveform"
        let film = OrbFilm.image(look: look, phase: phase, side: 150, scale: displayScale)
            ?? UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold))
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
        let toggle: @MainActor () -> Void = { VoiceCallRemote.current?.toggleMicrophone() }
        let microphone: CPButton = state == .muted ? button("Micro", "mic.fill", toggle) : button("Couper le micro", "mic.slash.fill", toggle)
        let hangUp: CPButton = button("Raccrocher", "phone.down.fill", { VoiceCallRemote.current?.endCall() })
        let limit = Int(CPVoiceControlState.maximumActionButtonCount)
        return Array([microphone, hangUp].prefix(max(limit, 0)))
    }

    // MARK: Call

    private func startCall(profile: String, title: String) {
        guard !starting, !inCall, let start = CallLauncher.start else { return }
        UserDefaults.standard.set(profile, forKey: Self.pickedKey)
        starting = true
        // The call's screen at once: the touch answers before the agent does.
        self.profile = profile; agent = title; inCall = true; state = .thinking
        showCall()
        Task { @MainActor [weak self] in
            let problem = await start(profile.isEmpty ? nil : profile)
            self?.starting = false
            if let problem {
                self?.inCall = false; self?.state = .idle
                self?.showAgents()
                self?.alert(problem)
            }
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
