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

/// Draws one frame of an agent's neural network: small points and fine links laid out by the agent's personality.
/// At rest a few points light up now and then; listening lights the centre with the voice; thinking sends signals along
/// the links; speaking sends a wave of light outward from the centre.
private struct OrbArtist {
    let look: AgentLook
    let dark: Bool
    let compact: Bool
    private var palette: AgentLook.Palette { look.palette }

    private struct Node { var x: Double, y: Double, depth = 1.0, weight = 0.6 }

    func draw(_ context: GraphicsContext, size: CGSize, time: Double, state: OrbMotion.State) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let live = max(state.listening, state.speaking)
        let breath = 0.01 * sin(time * 1.3) * (1 + state.thinking)
        let radius = side / 2 * CGFloat((compact ? 0.9 : 0.66) * (1 + state.energy * 0.08) + breath)
        if !compact {
            let glow = 0.06 + 0.09 * live + 0.05 * state.energy
            let halo = Path(ellipseIn: CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
            context.fill(halo, with: .radialGradient(Gradient(colors: [palette.main.opacity(glow), palette.main.opacity(0)]),
                                                     center: center, startRadius: side * 0.26, endRadius: side * 0.5))
        }
        let (nodes, links) = layout(time: time, state: state)
        network(context, center: center, radius: radius, nodes: nodes, links: links, time: time, state: state)
    }

    private func network(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, nodes: [Node], links: [(Int, Int)], time: Double, state: OrbMotion.State) {
        let base = dark ? palette.light : palette.main
        var activity = nodes.enumerated().map { index, node -> Double in
            let seed = Self.fraction(sin(Double(index + 1) * 91.7) * 4375.85)
            let distance = (node.x * node.x + node.y * node.y).squareRoot()
            var lit = pow(max(0, sin(time * 1.3 + seed * 17)), 16) * 0.8
            lit += state.energy * max(0, 1 - distance) * 1.1
            lit += state.speaking * max(0, sin(distance * 7 - time * 8)) * 0.7
            return min(1, lit)
        }
        let points = nodes.map { CGPoint(x: center.x + CGFloat($0.x) * radius, y: center.y + CGFloat($0.y) * radius) }
        // Small marks (headers, lists) get thicker links and larger points so they still read at 17–28 points.
        let thin = max(0.7, radius * (compact ? 0.065 : 0.02))
        for (a, b) in links {
            let depth = (nodes[a].depth + nodes[b].depth) / 2
            var line = Path(); line.move(to: points[a]); line.addLine(to: points[b])
            context.stroke(line, with: .color(base.opacity((compact ? 0.3 : 0.14) + 0.28 * depth + 0.4 * max(activity[a], activity[b]))),
                           style: StrokeStyle(lineWidth: thin * CGFloat(0.6 + 0.6 * depth), lineCap: .round))
        }
        // Thinking: signals run along the links and light the point they reach.
        if state.thinking > 0.02, !links.isEmpty {
            for signal in 0..<(compact ? 1 : 3) {
                let travel = time * 1.5 + Double(signal) * 0.37 * Double(links.count)
                let link = links[Int(travel) % links.count], progress = Self.fraction(travel)
                let spot = CGPoint(x: points[link.0].x + (points[link.1].x - points[link.0].x) * CGFloat(progress),
                                   y: points[link.0].y + (points[link.1].y - points[link.0].y) * CGFloat(progress))
                let size = radius * 0.06
                context.fill(Path(ellipseIn: CGRect(x: spot.x - size, y: spot.y - size, width: size * 2, height: size * 2)),
                             with: .color(Color(red: 1, green: 0.97, blue: 0.94).opacity(0.95 * state.thinking)))
                if progress > 0.8 { activity[link.1] = max(activity[link.1], state.thinking) }
            }
        }
        for index in nodes.indices.sorted(by: { nodes[$0].depth < nodes[$1].depth }) {
            let node = nodes[index], lit = activity[index]
            let size = radius * CGFloat((compact ? 0.1 : 0.048) + (compact ? 0.05 : 0.026) * node.weight) * CGFloat(0.7 + 0.5 * node.depth) * CGFloat(1 + 0.5 * lit)
            let dot = Path(ellipseIn: CGRect(x: points[index].x - size, y: points[index].y - size, width: size * 2, height: size * 2))
            context.fill(dot, with: .color(base.opacity(0.5 + 0.5 * node.depth)))
            if lit > 0.02 { context.fill(dot, with: .color((dark ? Color.white : palette.light).opacity(lit * (dark ? 0.8 : 0.9)))) }
        }
    }

    /// The personality: where the points sit and how they move, in a unit disc.
    private func layout(time: Double, state: OrbMotion.State) -> ([Node], [(Int, Int)]) {
        let golden = 2.399963
        var nodes: [Node] = [], links: [(Int, Int)] = []
        func linkClose(_ limit: Double) {
            for i in nodes.indices { for j in nodes.indices where j > i && hypot(nodes[i].x - nodes[j].x, nodes[i].y - nodes[j].y) < limit { links.append((i, j)) } }
        }
        switch look.style {
        case .sphere:
            // Points on a turning globe: nearer points are larger and brighter.
            let count = compact ? 12 : 26, spin = state.phase * 0.45, tilt = 0.38
            var unit: [(Double, Double, Double)] = []
            for index in 0..<count {
                let y = 1 - 2 * (Double(index) + 0.5) / Double(count), ring = max(0, 1 - y * y).squareRoot(), angle = Double(index) * golden
                let x0 = cos(angle) * ring, z0 = sin(angle) * ring
                unit.append((x0, y, z0))
                let xr = x0 * cos(spin) + z0 * sin(spin), zr = -x0 * sin(spin) + z0 * cos(spin)
                let yt = y * cos(tilt) - zr * sin(tilt), zt = y * sin(tilt) + zr * cos(tilt)
                nodes.append(Node(x: xr * 0.95, y: yt * 0.95, depth: (zt + 1) / 2))
            }
            var seen = Set<Int>()
            for (i, a) in unit.enumerated() {
                let nearest = unit.indices.filter { $0 != i }.sorted { j, k in
                    let dj = pow(a.0 - unit[j].0, 2) + pow(a.1 - unit[j].1, 2) + pow(a.2 - unit[j].2, 2)
                    let dk = pow(a.0 - unit[k].0, 2) + pow(a.1 - unit[k].1, 2) + pow(a.2 - unit[k].2, 2)
                    return dj < dk
                }.prefix(3)
                for j in nearest where seen.insert(min(i, j) * 100 + max(i, j)).inserted { links.append((i, j)) }
            }
        case .flower:
            // Hermès' flower as a network: six arms of points around a centre.
            let radii: [Double] = compact ? [0.5, 0.95] : [0.34, 0.62, 0.93], turn = state.phase * 0.25
            nodes.append(Node(x: 0, y: 0, weight: 1.4))
            for arm in 0..<6 {
                for (step, distance) in radii.enumerated() {
                    let angle = turn + Double(arm) * .pi / 3 + Double(step) * 0.17 - .pi / 2
                    let reach = distance * (1 + 0.04 * sin(time * 1.1 + Double(arm)))
                    nodes.append(Node(x: cos(angle) * reach, y: sin(angle) * reach, weight: step == 0 ? 0.95 : 0.6 - 0.1 * Double(step)))
                }
            }
            let perArm = radii.count
            for arm in 0..<6 {
                let first = 1 + arm * perArm
                links.append((0, first))
                for step in 0..<(perArm - 1) { links.append((first + step, first + step + 1)) }
                links.append((first, 1 + ((arm + 1) % 6) * perArm))
            }
        case .spiral:
            // A sunflower of points, linked along its golden spirals.
            let count = compact ? 13 : 28
            for index in 0..<count {
                let reach = 0.96 * ((Double(index) + 0.5) / Double(count)).squareRoot(), angle = Double(index) * golden + state.phase * 0.3
                nodes.append(Node(x: cos(angle) * reach, y: sin(angle) * reach, weight: 1 - reach * 0.5))
            }
            for index in 0..<count { for gap in [5, 8, 13] where index + gap < count && hypot(nodes[index].x - nodes[index + gap].x, nodes[index].y - nodes[index + gap].y) < (compact ? 0.62 : 0.42) { links.append((index, index + gap)) } }
        case .cluster:
            // A loose swarm that drifts; links follow whoever is close.
            let count = compact ? 10 : 19
            nodes.append(Node(x: 0.02 * sin(time * 0.7), y: 0.02 * cos(time * 0.6), weight: 1.3))
            for index in 1..<count {
                let h1 = Self.fraction(sin(Double(index) * 12.9898) * 43758.5453), h2 = Self.fraction(sin(Double(index) * 78.233) * 12345.678)
                let angle = Double(index) * golden + h1 * 0.8, reach = 0.28 + 0.68 * h2.squareRoot()
                nodes.append(Node(x: cos(angle) * reach + 0.07 * sin(time * 0.6 + Double(index) * 1.7),
                                  y: sin(angle) * reach + 0.07 * cos(time * 0.5 + Double(index) * 2.3), weight: 0.4 + 0.4 * (1 - reach)))
            }
            linkClose(compact ? 0.78 : 0.56)
        case .layers:
            // A deep-learning diagram: columns of points, every point linked to the next column.
            let counts = compact ? [2, 3, 2] : [3, 4, 4, 3], spacing = compact ? 0.62 : 0.46
            var columns: [[Int]] = []
            for (layer, count) in counts.enumerated() {
                let x = -0.82 + 1.64 * Double(layer) / Double(counts.count - 1)
                var column: [Int] = []
                for row in 0..<count {
                    column.append(nodes.count)
                    let y = (Double(row) - Double(count - 1) / 2) * spacing + 0.04 * sin(time * 0.9 + Double(layer + row))
                    nodes.append(Node(x: x, y: y, weight: layer == 0 || layer == counts.count - 1 ? 0.5 : 0.7))
                }
                columns.append(column)
            }
            for layer in 0..<(columns.count - 1) { for a in columns[layer] { for b in columns[layer + 1] { links.append((a, b)) } } }
        case .lattice:
            // An ordered hexagonal lattice that turns slowly.
            let ring = compact ? 1 : 2, spacing = compact ? 0.8 : 0.44, turn = state.phase * 0.12
            for q in -ring...ring {
                for r in -ring...ring where abs(q + r) <= ring {
                    let x0 = spacing * (Double(q) + Double(r) / 2), y0 = spacing * Double(r) * 3.0.squareRoot() / 2
                    nodes.append(Node(x: x0 * cos(turn) - y0 * sin(turn), y: x0 * sin(turn) + y0 * cos(turn), weight: q == 0 && r == 0 ? 1.2 : 0.6))
                }
            }
            linkClose(spacing * 1.05)
        }
        return (nodes, links)
    }

    private static func fraction(_ value: Double) -> Double { value - value.rounded(.down) }
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
