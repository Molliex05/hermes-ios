import AVFoundation
import Foundation

/// How a call treats interruptions and noisy places. Kept on this iPhone: it describes where you are, not the agent.
enum VoiceInterruptionSetting {
    enum Mode: String { case auto, off }
    private static let key = "voice.interruption"
    /// `auto`: speaking over the agent cuts it off. `off`: only the end of its reply gives you the floor (a noisy car).
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
    static func set(_ mode: Mode) { UserDefaults.standard.set(mode.rawValue, forKey: key) }
}

enum VoiceEnvironmentSetting {
    enum Mode: String { case auto, car }
    private static let key = "voice.environment"
    /// `auto`: the call decides from the noise it hears and from the audio route. `car`: always use the noisy-place rules.
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
    static func set(_ mode: Mode) { UserDefaults.standard.set(mode.rawValue, forKey: key) }

    /// Told rather than measured: the setting says car, or the audio goes out through CarPlay.
    static var isForced: Bool {
        mode == .car || AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }
}
