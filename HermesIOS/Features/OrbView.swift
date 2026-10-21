import SwiftUI

/// The orb is the whole conversation: it follows your voice while listening, breathes while the
/// agent thinks, and pulses while it speaks. States blend into each other instead of switching.
/// Only this surface observes microphone energy, and it sleeps when motion is unneeded.
enum OrbPhase { case idle, listening, thinking, speaking }

/// The animated orb: follows a voice level while listening, breathes while the agent thinks, pulses while it
/// speaks. Phases blend into each other.
struct OrbView: View {
    let phase: OrbPhase
    /// Microphone energy 0...1 while listening; nil lets the orb pulse gently on its own (no microphone level available).
    var level: Double?
    /// false draws the resting shape only (headers, lists): no timeline, no per-frame cost.
    var animated = true
    /// Keep breathing while idle (the empty chat); calls and paused states stay still to spare the battery.
    var breathesWhenIdle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var motion = OrbMotion()

    private static let accentColor = Color(red: 0.81, green: 0.29, blue: 0.19)

    var body: some View {
        let animating = animated && !reduceMotion && scenePhase == .active && (phase != .idle || breathesWhenIdle)
        let heard = phase == .listening ? (level.map { min(1, max(0, $0)) } ?? -1) : 0
        let target = OrbMotion.Target(listening: phase == .listening, thinking: phase == .thinking, speaking: phase == .speaking,
                                      level: reduceMotion ? 0 : heard)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { timeline in
            Canvas { context, size in
                let time = animating ? timeline.date.timeIntervalSinceReferenceDate : 0
                let state = animating ? motion.step(time: time, target: target) : motion.settle(target: target)
                draw(context: context, size: size, time: time, state: state)
            }
        }.accessibilityHidden(true)
    }

    private func draw(context: GraphicsContext, size: CGSize, time: Double, state: OrbMotion.State) {
        let side = min(size.width, size.height)
        let breath = 0.012 * sin(time * 1.3) * (1 + state.thinking)
        let diameter = side * CGFloat(0.66 + state.energy * 0.13 + breath + state.speaking * 0.02)
        let rect = CGRect(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2, width: diameter, height: diameter)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let silhouette = Path(ellipseIn: rect)
        let dark = colorScheme == .dark
        let accent = Self.accentColor
        let warm = Color(red: 0.97, green: 0.66, blue: 0.43)
        let deep = Color(red: 0.55, green: 0.21, blue: 0.17)
        let live = max(state.listening, state.speaking)
        let glow = 0.07 + 0.10 * live + 0.05 * state.energy

        let halo = Path(ellipseIn: CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
        context.fill(halo, with: .radialGradient(Gradient(colors: [accent.opacity(glow), accent.opacity(glow * 0.25), .clear]),
                                                 center: center, startRadius: side * 0.26, endRadius: side * 0.5))
        // Soft ripples leave the orb while someone is speaking (you or the agent).
        if live > 0.02 {
            for index in 0..<2 {
                let progress = (time * 0.42 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                let radius = diameter / 2 + CGFloat(progress) * side * 0.17
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(accent.opacity((1 - progress) * 0.22 * live)), lineWidth: 1.2)
            }
        }
        context.stroke(Path(ellipseIn: rect.insetBy(dx: -10, dy: -10)), with: .color(accent.opacity(0.06 + 0.08 * live)), lineWidth: 0.75)

        var orb = context
        orb.clip(to: silhouette)
        let body = 0.55 + 0.35 * max(live, state.thinking * 0.6)
        orb.fill(silhouette, with: .linearGradient(Gradient(colors: [warm.opacity(dark ? 0.75 : 0.6), accent.opacity(body), deep.opacity(dark ? 0.95 : 0.85)]),
                                                   startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        let amplitude = diameter * CGFloat(0.03 + state.energy * 0.11)
        for index in 0..<3 {
            let baseline = rect.minY + diameter * CGFloat(0.38 + Double(index) * 0.17)
            var wave = Path()
            wave.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            for sample in 0...40 {
                let position = Double(sample) / 40
                let angle = position * .pi * 2 + state.phase + Double(index) * 1.8
                let y = baseline + CGFloat(sin(angle)) * amplitude + CGFloat(cos(angle * 0.6 + Double(index))) * amplitude * 0.3
                wave.addLine(to: CGPoint(x: rect.minX + CGFloat(position) * diameter, y: y))
            }
            wave.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            wave.closeSubpath()
            orb.fill(wave, with: .linearGradient(Gradient(colors: [warm.opacity(0.45 - Double(index) * 0.06), accent.opacity(0.12), deep.opacity(0.4)]),
                                                 startPoint: CGPoint(x: rect.midX, y: baseline - amplitude), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        orb.fill(silhouette, with: .radialGradient(Gradient(colors: [.white.opacity(dark ? 0.24 : 0.45), .clear]),
                                                   center: CGPoint(x: rect.minX + diameter * 0.28, y: rect.minY + diameter * 0.20), startRadius: 0, endRadius: diameter * 0.65))
        context.stroke(silhouette, with: .color(.white.opacity(dark ? 0.1 : 0.3)), lineWidth: 0.75)
        // A slow light travels around the edge while the agent thinks.
        if state.thinking > 0.02 {
            let sweep = Gradient(stops: [.init(color: .clear, location: 0), .init(color: warm.opacity(0.85 * state.thinking), location: 0.18),
                                         .init(color: .clear, location: 0.36), .init(color: .clear, location: 1)])
            context.stroke(silhouette, with: .conicGradient(sweep, center: center, angle: .radians(time * 2.2)), lineWidth: 2.4)
        }
    }
}

/// Smooths phase changes: weights ease between states and the energy follows with a fast attack and a
/// slower release, so the orb never jumps. Reference type: drawing advances it once per frame.
private final class OrbMotion {
    struct Target { let listening: Bool, thinking: Bool, speaking: Bool, level: Double }
    struct State { var listening = 0.0, thinking = 0.0, speaking = 0.0, energy = 0.0, phase = 0.0 }

    private var state = State()
    private var last: Double?

    func step(time: Double, target: Target) -> State {
        let dt = min(0.1, max(0.001, time - (last ?? time - 1.0 / 30.0)))
        last = time
        func ease(_ value: Double, to goal: Double, rate: Double) -> Double { value + (goal - value) * (1 - exp(-dt * rate)) }
        state.listening = ease(state.listening, to: target.listening ? 1 : 0, rate: 6)
        state.thinking = ease(state.thinking, to: target.thinking ? 1 : 0, rate: 4)
        state.speaking = ease(state.speaking, to: target.speaking ? 1 : 0, rate: 6)
        let voice = 0.30 + 0.22 * (sin(time * 5.3) * 0.5 + 0.5) * (0.6 + 0.4 * sin(time * 2.1 + 1))
        let goal = target.listening ? (target.level < 0 ? 0.14 + 0.08 * sin(time * 2.6) : target.level) : target.speaking ? voice : target.thinking ? 0.10 + 0.05 * sin(time * 2) : 0
        state.energy = ease(state.energy, to: goal, rate: goal > state.energy ? 14 : 5)
        state.phase += dt * (0.7 + state.speaking + state.thinking * 0.5 + state.listening * 0.4)
        return state
    }

    /// Reduced motion or background: show the resting shape for the current phase, with no movement.
    func settle(target: Target) -> State {
        state.listening = target.listening ? 1 : 0; state.thinking = target.thinking ? 0.6 : 0; state.speaking = target.speaking ? 1 : 0
        state.energy = 0; last = nil
        return state
    }
}
