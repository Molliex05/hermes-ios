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
        TimelineView(.animation(minimumInterval: compact ? 1.0 / 30.0 : 1.0 / 60.0, paused: !animating)) { timeline in
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

    private func network(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, nodes rawNodes: [Node], links: [(Int, Int)], time: Double, state: OrbMotion.State) {
        var canvas = context
        if dark && !compact { canvas.blendMode = .plusLighter }      // light adds up on a dark page (large orb only)
        let base = dark ? palette.light : palette.main
        let glow = dark && !compact ? Color.white : dark ? palette.main : palette.light
        let spark = dark ? Color.white : palette.deep
        // A slow drift: the network is never frozen while it animates (the sphere turns instead).
        let nodes = rawNodes.enumerated().map { index, node -> Node in
            guard look.style != .sphere else { return node }
            let seed = Self.seed(index)
            var moved = node
            moved.x += 0.022 * sin(time * 0.7 + seed * 6.28)
            moved.y += 0.022 * cos(time * 0.55 + seed * 4.1)
            return moved
        }
        let points = nodes.map { CGPoint(x: center.x + CGFloat($0.x) * radius, y: center.y + CGFloat($0.y) * radius) }
        var activity = nodes.enumerated().map { index, node -> Double in
            let seed = Self.seed(index), distance = hypot(node.x, node.y)
            let period = 3.6 + 3.2 * seed, phase = Self.fraction(time / period + seed)
            var lit = 0.55 * exp(-pow((phase - 0.5) * 7, 2))                    // a point lights up now and then, softly
            lit += state.energy * max(0, 1 - distance) * 1.1                    // the voice lights the centre
            let front = Self.fraction(time * 0.85) * 1.35                        // speaking: a wave of light leaves the centre
            lit += state.speaking * exp(-pow((distance - front) * 5, 2)) * 0.9
            return min(1, lit)
        }
        let thin = max(0.7, radius * (compact ? 0.065 : 0.011))

        // Thinking: signals hop from link to link, lighting the point they reach.
        var signals: [(from: CGPoint, to: CGPoint, progress: Double)] = []
        if state.thinking > 0.02, !links.isEmpty {
            for index in 0..<(compact ? 1 : 4) {
                let travel = time * (0.9 + 0.22 * Double(index)) + Double(index) * 7.31
                let hop = Int(travel.rounded(.down))
                let pick = ((hop &* 7919 &+ index &* 104_729) % links.count + links.count) % links.count
                let forward = (hop + index) % 2 == 0
                let (from, to) = forward ? links[pick] : (links[pick].1, links[pick].0)
                let linear = Self.fraction(travel), progress = linear * linear * (3 - 2 * linear)
                signals.append((points[from], points[to], progress))
                if progress > 0.8 { activity[to] = max(activity[to], state.thinking * (progress - 0.8) / 0.2) }
                if progress < 0.15 { activity[from] = max(activity[from], state.thinking * (0.15 - progress) / 0.15 * 0.6) }
            }
        }

        // Speaking: soft rings leave the centre. Listening: a ring around the centre follows the voice.
        if !compact, state.speaking > 0.02 {
            for ring in 0..<2 {
                let progress = Self.fraction(time * 0.6 + Double(ring) * 0.5), size = radius * CGFloat(0.12 + 0.95 * progress)
                canvas.stroke(Path(ellipseIn: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 2)),
                              with: .color(base.opacity((1 - progress) * 0.28 * state.speaking)), lineWidth: thin * 1.2)
            }
        }
        if !compact, state.listening > 0.02 {
            let size = radius * CGFloat(0.2 + 0.28 * state.energy)
            canvas.stroke(Path(ellipseIn: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 2)),
                          with: .color(base.opacity(0.12 + 0.4 * state.energy * state.listening)), lineWidth: thin)
        }

        // Links: fade with their length and toward a quiet point, brighten toward a lit one.
        for (a, b) in links {
            let depth = (nodes[a].depth + nodes[b].depth) / 2
            let length = hypot(nodes[a].x - nodes[b].x, nodes[a].y - nodes[b].y)
            let quiet = (compact ? 0.32 : 0.1 + 0.2 * depth) * (1 - 0.45 * min(1, length / 1.2))
            var line = Path(); line.move(to: points[a]); line.addLine(to: points[b])
            let ends = Gradient(colors: [base.opacity(quiet + 0.5 * activity[a]), base.opacity(quiet + 0.5 * activity[b])])
            canvas.stroke(line, with: .linearGradient(ends, startPoint: points[a], endPoint: points[b]),
                          style: StrokeStyle(lineWidth: thin * CGFloat(0.6 + 0.6 * depth), lineCap: .round))
        }
        // Signal tails, like comets.
        for signal in signals {
            func at(_ t: Double) -> CGPoint {
                CGPoint(x: signal.from.x + (signal.to.x - signal.from.x) * CGFloat(t), y: signal.from.y + (signal.to.y - signal.from.y) * CGFloat(t))
            }
            let tail = at(max(0, signal.progress - 0.4)), head = at(signal.progress)
            var line = Path(); line.move(to: tail); line.addLine(to: head)
            canvas.stroke(line, with: .linearGradient(Gradient(colors: [spark.opacity(0), spark.opacity(0.85 * state.thinking)]), startPoint: tail, endPoint: head),
                          style: StrokeStyle(lineWidth: thin * 2.2, lineCap: .round))
        }

        // Points: a soft halo, the point, a small highlight; the hub gets a fine ring.
        for index in nodes.indices.sorted(by: { nodes[$0].depth < nodes[$1].depth }) {
            let node = nodes[index], lit = activity[index], spot = points[index]
            let core = radius * CGFloat((compact ? 0.1 : 0.024) + (compact ? 0.05 : 0.016) * node.weight) * CGFloat(0.75 + 0.45 * node.depth) * CGFloat(1 + 0.35 * lit)
            // No halo in small marks: it would reach past the frame and be cut into a square.
            let haloAlpha = compact ? 0 : 0.14 * node.depth + 0.45 * lit
            if haloAlpha > 0.01 {
                let halo = core * CGFloat(3 + 3 * lit)
                canvas.fill(Path(ellipseIn: CGRect(x: spot.x - halo, y: spot.y - halo, width: halo * 2, height: halo * 2)),
                            with: .radialGradient(Gradient(colors: [base.opacity(haloAlpha), base.opacity(0)]), center: spot, startRadius: core * 0.5, endRadius: halo))
            }
            let dot = Path(ellipseIn: CGRect(x: spot.x - core, y: spot.y - core, width: core * 2, height: core * 2))
            canvas.fill(dot, with: .color(base.opacity(0.55 + 0.45 * node.depth)))
            if lit > 0.02 { canvas.fill(dot, with: .color(glow.opacity(lit * 0.85))) }
            if !compact {
                if node.weight > 1 {
                    let ring = core * 1.9
                    canvas.stroke(Path(ellipseIn: CGRect(x: spot.x - ring, y: spot.y - ring, width: ring * 2, height: ring * 2)),
                                  with: .color(base.opacity(0.22 + 0.4 * state.energy)), lineWidth: thin * 0.8)
                }
            }
        }
        // Signal heads, on top.
        for signal in signals {
            let head = CGPoint(x: signal.from.x + (signal.to.x - signal.from.x) * CGFloat(signal.progress),
                               y: signal.from.y + (signal.to.y - signal.from.y) * CGFloat(signal.progress))
            let size = radius * (compact ? 0.08 : 0.045), halo = size * 3.2
            canvas.fill(Path(ellipseIn: CGRect(x: head.x - halo, y: head.y - halo, width: halo * 2, height: halo * 2)),
                        with: .radialGradient(Gradient(colors: [spark.opacity(0.45 * state.thinking), spark.opacity(0)]), center: head, startRadius: 0, endRadius: halo))
            canvas.fill(Path(ellipseIn: CGRect(x: head.x - size, y: head.y - size, width: size * 2, height: size * 2)),
                        with: .color(Color.white.opacity(0.95 * state.thinking)))
        }
    }

    private static func seed(_ index: Int) -> Double { fraction(sin(Double(index + 1) * 91.7) * 4375.85) }

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
            let count = compact ? 12 : 32, spin = state.phase * 0.4, tilt = 0.38
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
            let radii: [Double] = compact ? [0.5, 0.95] : [0.26, 0.48, 0.71, 0.94], turn = state.phase * 0.25
            nodes.append(Node(x: 0, y: 0, weight: 1.4))
            for arm in 0..<6 {
                for (step, distance) in radii.enumerated() {
                    let angle = turn + Double(arm) * .pi / 3 + Double(step) * 0.12 - .pi / 2
                    let reach = distance * (1 + 0.04 * sin(time * 1.1 + Double(arm)))
                    nodes.append(Node(x: cos(angle) * reach, y: sin(angle) * reach, weight: step == 0 ? 0.95 : 0.65 - 0.1 * Double(step)))
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
            let count = compact ? 13 : 34
            for index in 0..<count {
                let reach = 0.96 * ((Double(index) + 0.5) / Double(count)).squareRoot(), angle = Double(index) * golden + state.phase * 0.3
                nodes.append(Node(x: cos(angle) * reach, y: sin(angle) * reach, weight: 1 - reach * 0.5))
            }
            for index in 0..<count { for gap in [5, 8, 13] where index + gap < count && hypot(nodes[index].x - nodes[index + gap].x, nodes[index].y - nodes[index + gap].y) < (compact ? 0.62 : 0.42) { links.append((index, index + gap)) } }
        case .cluster:
            // A loose swarm that drifts; links follow whoever is close.
            let count = compact ? 10 : 24
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
