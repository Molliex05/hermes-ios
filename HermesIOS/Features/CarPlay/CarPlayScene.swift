import CarPlay
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

    /// Opening Hermès on the car's screen starts a call: Apple wants a voice app to open in voice.
    func sceneDidBecomeActive(_ scene: UIScene) { CarScreen.shared.opened() }
}

/// The voice control template of the car's screen, kept in step with the call. It shows the call's state, the agent's
/// name and two buttons (mute, hang up); never the answer's text or a card, which Apple forbids at the wheel. A reply that
/// gives one place opens Plans on the car's screen with the driving route.
@MainActor final class CarScreen {
    static let shared = CarScreen()

    /// Installed by the app: the current agent's name, shown before a call.
    static var agentTitle: (() -> String?)?

    private var scene: CPTemplateApplicationScene?
    private var interface: CPInterfaceController?
    private var template: CPVoiceControlTemplate?
    private var agent = ""
    private var state = CarVoiceScreen.State.idle
    private var shownDestinations = Set<String>()
    private var starting = false

    var connected: Bool { interface != nil }

    func connect(_ scene: CPTemplateApplicationScene, _ interface: CPInterfaceController) {
        self.scene = scene; self.interface = interface
        template = nil
        if let call = VoiceCallRemote.current, call.tools.app.voiceActive {
            call.refreshCarScreen(open: false)  // builds the template on the call's state
        }
        if template == nil { agent = Self.agentTitle?() ?? agent; state = .idle; rebuild() }
    }

    func disconnect() {
        scene = nil; interface = nil; template = nil
    }

    func opened() {
        guard connected, !starting, !(VoiceCallRemote.current?.tools.app.voiceActive ?? false) else { return }
        startCall()
    }

    /// Called by the call on every change of phase or microphone (`paused` once it ends).
    func update(agent: String, phase: String?, muted: Bool, destination: CarDestination?, open: Bool = true) {
        let state = CarVoiceScreen.state(phase: phase, muted: muted)
        let renamed = agent != self.agent
        self.agent = agent
        if let destination, connected, shownDestinations.insert(destination.messageID).inserted, open {
            scene?.open(destination.url, options: nil, completionHandler: nil)
        }
        guard connected else { self.state = state; return }
        if renamed || template == nil { self.state = state; rebuild(); return }
        guard state != self.state else { return }
        self.state = state
        template?.activateVoiceControlState(withIdentifier: state.rawValue)
    }

    // MARK: Template

    private func rebuild() {
        guard let interface else { return }
        let states = CarVoiceScreen.State.allCases.map(voiceState)
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        self.template = template
        let active = state
        interface.setRootTemplate(template, animated: false) { _, _ in
            // The first state is shown until the template is up; only then can another be activated.
            Task { @MainActor in template.activateVoiceControlState(withIdentifier: active.rawValue) }
        }
    }

    private func voiceState(_ state: CarVoiceScreen.State) -> CPVoiceControlState {
        let symbol = switch state {
        case .idle: "phone.fill"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .muted: "mic.slash.fill"
        }
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold))
        let voice = CPVoiceControlState(identifier: state.rawValue, titleVariants: CarVoiceScreen.titles(state, agent: agent), image: image, repeats: false)
        if #available(iOS 26.4, *) { voice.actionButtons = buttons(for: state) }
        return voice
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
        Task { @MainActor [weak self] in
            let problem = await start(nil)
            self?.starting = false
            if let problem { self?.alert(problem) }
        }
    }

    /// A call that could not start says why, in a few words the driver can glance at.
    private func alert(_ message: String) {
        guard let interface else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak interface] _ in
            MainActor.assumeIsolated { interface?.dismissTemplate(animated: true, completion: nil) }
        }
        interface.presentTemplate(CPAlertTemplate(titleVariants: [message, "L’appel n’a pas pu démarrer."], actions: [ok]), animated: true, completion: nil)
    }
}
