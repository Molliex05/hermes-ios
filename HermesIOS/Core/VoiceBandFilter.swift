import Foundation

/// Keeps only the band where speech lives (about 300 Hz to 3.4 kHz) so a car's engine and road rumble, which sit mostly below
/// 250 Hz, barely move the level used to decide that someone is talking. Two high-pass sections (a steep 4th-order roll-off)
/// and one low-pass section, as Butterworth biquads in direct form II transposed. State carries across buffers.
struct VoiceBandFilter {
    private struct Section {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var sections: [Section]
    let sampleRate: Double

    init(sampleRate: Double, lowCut: Double = 300, highCut: Double = 3_400) {
        self.sampleRate = sampleRate
        let q = 0.7071
        let high = min(highCut, sampleRate * 0.45)
        sections = [Self.highPass(lowCut, sampleRate, q), Self.highPass(lowCut, sampleRate, q), Self.lowPass(high, sampleRate, q)]
    }

    private static func make(_ f0: Double, _ fs: Double, _ q: Double, _ build: (Double, Double) -> (b0: Double, b1: Double, b2: Double)) -> Section {
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b = build(cos(w0), alpha)
        return Section(b0: b.b0 / a0, b1: b.b1 / a0, b2: b.b2 / a0, a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
    }

    private static func highPass(_ f0: Double, _ fs: Double, _ q: Double) -> Section {
        make(f0, fs, q) { c, _ in ((1 + c) / 2, -(1 + c), (1 + c) / 2) }
    }

    private static func lowPass(_ f0: Double, _ fs: Double, _ q: Double) -> Section {
        make(f0, fs, q) { c, _ in ((1 - c) / 2, 1 - c, (1 - c) / 2) }
    }

    /// RMS of the band-passed signal, on the same scale as the input (0...1 for float audio).
    mutating func rms(of samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var energy = 0.0
        for sample in samples {
            var value = Double(sample)
            for index in sections.indices { value = sections[index].process(value) }
            energy += value * value
        }
        let result = (energy / Double(samples.count)).squareRoot()
        return result.isFinite ? result : 0
    }
}
