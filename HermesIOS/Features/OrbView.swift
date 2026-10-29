import SwiftUI

/// The orb is the whole conversation: it follows your voice while listening, breathes while the
/// agent thinks, and pulses while it speaks. States blend into each other instead of switching.
/// Only this surface observes microphone energy, and it sleeps when motion is unneeded.
enum OrbPhase { case idle, listening, thinking, speaking }

/// The agent's animated illustration, in the style of its profile (see `AgentLook`): it follows a voice level while
/// listening, comes alive while the agent thinks, pulses while it speaks. Phases blend into each other.
struct OrbView: View {
    let phase: OrbPhase
    /// Microphone energy 0...1 while listening; nil lets the orb pulse gently on its own (no microphone level available).
    var level: Double?
    /// false draws the resting shape only (headers, lists): no timeline, no per-frame cost.
    var animated = true
    /// Keep breathing while idle (the empty chat); calls and paused states stay still to spare the battery.
    var breathesWhenIdle = false
    /// The look to draw; nil uses the current agent's (`\.agentLook`).
    var look: AgentLook?
    /// An avatar or a small mark: the illustration fills its frame, without the surrounding glow.
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.agentLook) private var currentLook
    @State private var motion = OrbMotion()

    var body: some View {
        let animating = animated && !reduceMotion && scenePhase == .active && (phase != .idle || breathesWhenIdle)
        let heard = phase == .listening ? (level.map { min(1, max(0, $0)) } ?? -1) : 0
        let target = OrbMotion.Target(listening: phase == .listening, thinking: phase == .thinking, speaking: phase == .speaking,
                                      level: reduceMotion ? 0 : heard)
        let drawn = look ?? currentLook
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { timeline in
            Canvas { context, size in
                let time = animating ? timeline.date.timeIntervalSinceReferenceDate : 0
                let state = animating ? motion.step(time: time, target: target) : motion.settle(target: target)
                OrbArtist(look: drawn, dark: colorScheme == .dark, compact: compact).draw(context, size: size, time: time, state: state)
            }
        }.accessibilityHidden(true)
    }
}

/// Draws one frame of an agent's illustration.
private struct OrbArtist {
    let look: AgentLook
    let dark: Bool
    let compact: Bool
    private var palette: AgentLook.Palette { look.palette }

    func draw(_ context: GraphicsContext, size: CGSize, time: Double, state: OrbMotion.State) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let live = max(state.listening, state.speaking)
        let breath = 0.012 * sin(time * 1.3) * (1 + state.thinking)
        let radius = side / 2 * CGFloat((compact ? 0.9 : 0.66) + state.energy * 0.13 + breath + state.speaking * 0.02)
        if !compact {
            let glow = 0.07 + 0.10 * live + 0.05 * state.energy
            let halo = Path(ellipseIn: CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
            context.fill(halo, with: .radialGradient(Gradient(colors: [palette.main.opacity(glow), palette.main.opacity(glow * 0.25), .clear]),
                                                     center: center, startRadius: side * 0.26, endRadius: side * 0.5))
        }
        switch look.style {
        case .petals: petals(context, center: center, radius: radius, time: time, state: state)
        case .aurora: aurora(context, center: center, radius: radius, time: time, state: state)
        case .prism: prism(context, center: center, radius: radius, time: time, state: state)
        case .constellation: constellation(context, center: center, radius: radius, side: side, time: time, state: state)
        case .liquid: liquid(context, center: center, radius: radius, time: time, state: state)
        }
    }

    /// Hermès' flower: six petals that turn slowly, open with the voice and light up one after another while thinking.
    private func petals(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, time: Double, state: OrbMotion.State) {
        let spin = state.phase * 0.35
        let lit = (time * 2.4).truncatingRemainder(dividingBy: 6)
        for index in 0..<6 {
            let angle = Double(index) / 6 * 2 * .pi + spin
            let pulse = 1 + 0.08 * state.speaking * sin(time * 6 + Double(index)) + 0.12 * state.energy
            let length = radius * 0.98 * CGFloat(pulse), width = radius * 0.46
            let petal = Path(ellipseIn: CGRect(x: -width / 2, y: -length, width: width, height: length * 1.04))
                .applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
            let tip = CGPoint(x: center.x + sin(angle) * length, y: center.y - cos(angle) * length)
            context.fill(petal, with: .linearGradient(Gradient(colors: [palette.deep.opacity(0.95), palette.main, palette.light]),
                                                      startPoint: center, endPoint: tip))
            // While thinking, a light runs from petal to petal.
            let distance = min(abs(Double(index) - lit), 6 - abs(Double(index) - lit))
            let shine = state.thinking * max(0, 1 - distance) * 0.55
            if shine > 0.01 { context.fill(petal, with: .color(.white.opacity(shine))) }
        }
        let heart = radius * 0.16
        context.fill(Path(ellipseIn: CGRect(x: center.x - heart, y: center.y - heart, width: heart * 2, height: heart * 2)),
                     with: .color(dark ? Color(white: 0.08) : Color(red: 0.98, green: 0.96, blue: 0.93)))
    }

    /// Soft lights that drift around each other and blend, like an aurora; they spread and quicken with the voice.
    private func aurora(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, time: Double, state: OrbMotion.State) {
        var glow = context
        glow.addFilter(.blur(radius: radius * (compact ? 0.12 : 0.2)))
        if dark { glow.blendMode = .plusLighter }
        // On a light page the pale shade washes out: the deep one keeps the lights vivid.
        let colors = dark ? [palette.main, palette.companion, palette.light] : [palette.main, palette.companion, palette.deep]
        for index in 0..<3 {
            let k = Double(index)
            let angle = state.phase * 0.9 + k * 2.1 + sin(time * 0.7 + k) * 0.4
            let reach = radius * CGFloat(0.26 + 0.14 * state.energy + 0.05 * sin(time * 1.3 + k))
            let size = radius * CGFloat(0.66 + 0.08 * sin(time * 1.1 + k * 1.7) + 0.16 * state.energy + 0.05 * state.speaking)
            let spot = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
            glow.fill(Path(ellipseIn: CGRect(x: spot.x - size, y: spot.y - size, width: size * 2, height: size * 2)),
                      with: .color(colors[index].opacity(dark ? 0.85 : 0.92)))
        }
        // A bright core that swells while the agent speaks or thinks.
        let core = radius * CGFloat(0.42 + 0.12 * max(state.speaking, state.thinking) + 0.1 * state.energy)
        context.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(dark ? 0.55 : 0.45), .white.opacity(0)]),
                                           center: center, startRadius: 0, endRadius: core))
    }

    /// A cut gem seen from above: its facets catch a light that turns, faster while thinking; it brightens with the voice.
    private func prism(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, time: Double, state: OrbMotion.State) {
        let turn = state.phase * 0.25
        let r = radius * CGFloat(1 + 0.04 * state.speaking * sin(time * 7))
        func point(_ angle: Double, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: center.x + CGFloat(cos(angle)) * distance, y: center.y + CGFloat(sin(angle)) * distance)
        }
        let outer = (0..<6).map { point(turn + Double($0) / 6 * 2 * .pi - .pi / 2, r) }
        let inner = (0..<6).map { point(turn + (Double($0) + 0.5) / 6 * 2 * .pi - .pi / 2, r * 0.52) }
        let light = 2.6 - time * (0.5 + 1.6 * state.thinking)
        func facet(_ points: [CGPoint]) {
            var path = Path(); path.addLines(points); path.closeSubpath()
            let middle = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            let facing = atan2(Double(middle.y - center.y), Double(middle.x - center.x))
            let brightness = 0.5 + 0.5 * cos(facing - light)
            context.fill(path, with: .color(palette.deep))
            context.fill(path, with: .color(palette.main.opacity(0.55 + 0.35 * brightness)))
            context.fill(path, with: .color(palette.light.opacity(brightness * (0.55 + 0.3 * state.energy))))
            context.stroke(path, with: .color(.white.opacity(dark ? 0.18 : 0.35)), lineWidth: max(0.5, radius * 0.012))
        }
        for index in 0..<6 {
            let next = (index + 1) % 6, previous = (index + 5) % 6
            facet([outer[index], outer[next], inner[index]])
            facet([outer[index], inner[index], inner[previous]])
        }
        var table = Path(); table.addLines(inner); table.closeSubpath()
        context.fill(table, with: .linearGradient(Gradient(colors: [palette.light, palette.main.opacity(0.9)]),
                                                  startPoint: point(light, r * 0.5), endPoint: point(light + .pi, r * 0.5)))
        context.stroke(table, with: .color(.white.opacity(dark ? 0.22 : 0.45)), lineWidth: max(0.5, radius * 0.012))
    }

    /// Linked stars around a centre: they drift, swell with the voice, and a spark runs along the links while thinking.
    private func constellation(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, side: CGFloat, time: Double, state: OrbMotion.State) {
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                     with: .radialGradient(Gradient(colors: [palette.main.opacity(dark ? 0.3 : 0.24), palette.main.opacity(0)]),
                                           center: center, startRadius: 0, endRadius: radius))
        let stars: [CGPoint] = [center] + (0..<6).map { index in
            let k = Double(index)
            let angle = k / 6 * 2 * .pi + 0.35 * sin(time * 0.5 + k) + state.phase * 0.12 - .pi / 2
            let distance = radius * CGFloat(0.66 + 0.1 * sin(time * 0.8 + k * 1.3) + 0.12 * state.energy)
            return CGPoint(x: center.x + CGFloat(cos(angle)) * distance, y: center.y + CGFloat(sin(angle)) * distance)
        }
        let links = (1...6).map { (0, $0) } + (1...6).map { ($0, $0 % 6 + 1) } + [(1, 4), (2, 5)]
        let width = max(0.8, side * (compact ? 0.05 : 0.014))
        for (a, b) in links {
            var line = Path(); line.move(to: stars[a]); line.addLine(to: stars[b])
            context.stroke(line, with: .color(palette.main.opacity(b == 4 && a == 1 || b == 5 && a == 2 ? 0.35 : 0.75)), lineWidth: width)
        }
        if state.thinking > 0.02 {
            let travel = time * 1.4
            let link = links[Int(travel) % links.count], progress = CGFloat(travel.truncatingRemainder(dividingBy: 1))
            let spark = CGPoint(x: stars[link.0].x + (stars[link.1].x - stars[link.0].x) * progress,
                                y: stars[link.0].y + (stars[link.1].y - stars[link.0].y) * progress)
            let glow = radius * 0.16
            context.fill(Path(ellipseIn: CGRect(x: spark.x - glow, y: spark.y - glow, width: glow * 2, height: glow * 2)),
                         with: .radialGradient(Gradient(colors: [Color.white.opacity(0.9 * state.thinking), palette.light.opacity(0)]),
                                               center: spark, startRadius: 0, endRadius: glow))
        }
        for (index, star) in stars.enumerated() {
            let pulse = 1 + 0.35 * state.energy * (0.6 + 0.4 * sin(time * 6 + Double(index)))
            let size = radius * CGFloat(index == 0 ? (compact ? 0.26 : 0.2) : (compact ? 0.17 : 0.12)) * CGFloat(pulse)
            context.fill(Path(ellipseIn: CGRect(x: star.x - size, y: star.y - size, width: size * 2, height: size * 2)),
                         with: .radialGradient(Gradient(colors: [palette.light, palette.main]), center: star, startRadius: 0, endRadius: size))
        }
    }

    /// A drop whose outline ripples: calm at rest, it moves more with the voice and while thinking.
    private func liquid(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, time: Double, state: OrbMotion.State) {
        let amount = 0.08 + 0.1 * state.energy + 0.03 * state.thinking + 0.02 * state.speaking
        var drop = Path()
        for sample in 0...72 {
            let theta = Double(sample) / 72 * 2 * .pi
            let wobble = sin(3 * theta + state.phase * 1.1) + 0.6 * sin(5 * theta - state.phase * 1.7 + 1) + 0.4 * sin(2 * theta + state.phase * 0.6 + 2)
            let distance = radius * CGFloat(1 + amount * wobble / 2)
            let point = CGPoint(x: center.x + CGFloat(cos(theta)) * distance, y: center.y + CGFloat(sin(theta)) * distance)
            if sample == 0 { drop.move(to: point) } else { drop.addLine(to: point) }
        }
        drop.closeSubpath()
        let box = drop.boundingRect
        context.fill(drop, with: .linearGradient(Gradient(colors: [palette.light, palette.main, palette.deep]),
                                                 startPoint: box.origin, endPoint: CGPoint(x: box.maxX, y: box.maxY)))
        var inside = context
        inside.clip(to: drop)
        let swirl = CGPoint(x: center.x + CGFloat(cos(state.phase * 0.8)) * radius * 0.3, y: center.y + CGFloat(sin(state.phase * 0.8)) * radius * 0.3)
        inside.fill(drop, with: .radialGradient(Gradient(colors: [palette.companion.opacity(0.5), .clear]), center: swirl, startRadius: 0, endRadius: radius * 0.8))
        inside.fill(drop, with: .radialGradient(Gradient(colors: [.white.opacity(dark ? 0.28 : 0.5), .clear]),
                                                center: CGPoint(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.24), startRadius: 0, endRadius: radius * 0.7))
        context.stroke(drop, with: .color(.white.opacity(dark ? 0.12 : 0.3)), lineWidth: max(0.5, radius * 0.012))
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
