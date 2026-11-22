import Foundation
import Accelerate

struct SpectrumPoint: Identifiable, Hashable {
    let id: Int
    let frequency: Double
    let db: Double
}

struct ResonanceAnalysis {
    var frequency: Double            // chosen fundamental, Hz
    var peaks: [Double]              // strongest peaks in the search range, Hz, ascending
    var harmonics: Int               // how many of 2f, 3f, 4f were found
    var dampingRatio: Double?
    var decay30ms: Double?
    var spectrum: [SpectrumPoint]    // for the chart, dB relative to the main peak
    var searchRange: ClosedRange<Double>
    var segment: [Float]             // recorded signal from the knock onward
    var sampleRate: Double
}

enum ResonanceAnalyzer {

    /// Finds the resonance frequency of a knock recording.
    /// - range: where the fundamental is expected (from the log length when known).
    static func analyze(samples: [Float], sampleRate: Double, range: ClosedRange<Double>) -> ResonanceAnalysis? {
        guard samples.count > 4096 else { return nil }

        // 1. Onset: loudest sample in the first 150 ms.
        let searchEnd = min(samples.count, Int(0.15 * sampleRate))
        var onset = 0
        var maxAbs: Float = 0
        for i in 0..<searchEnd {
            let a = abs(samples[i])
            if a > maxAbs { maxAbs = a; onset = i }
        }
        guard maxAbs > 1e-4 else { return nil }
        let end = min(samples.count, onset + Int(1.6 * sampleRate))
        let segment = Array(samples[onset..<end])
        guard segment.count > 2048 else { return nil }

        // 2. Window: flat, with a cosine taper on the last 15 %.
        var x = segment
        let taper = max(1, x.count * 15 / 100)
        for k in 0..<taper {
            let i = x.count - taper + k
            x[i] *= Float(0.5 * (1 + cos(Double.pi * Double(k) / Double(taper))))
        }

        // 3. FFT, zero padded to at least 2^16 points.
        var n = 1
        while n < max(x.count, 65_536) { n <<= 1 }
        let log2n = vDSP_Length(Int(log2(Double(n)).rounded()))
        x += [Float](repeating: 0, count: n - x.count)

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        let half = n / 2
        let binHz = sampleRate / Double(n)
        let nyquist = sampleRate / 2
        var db = [Double](repeating: -240, count: half)
        for i in 1..<half { db[i] = 10 * log10(Double(mags[i]) + 1e-24) }

        let lo = max(2, Int(range.lowerBound / binHz))
        let hi = min(half - 3, Int(min(range.upperBound, nyquist * 0.95) / binHz))
        guard hi > lo + 8 else { return nil }

        // 4. Strongest local maxima in the range, at least 8 % apart.
        var masked = [Bool](repeating: false, count: half)
        var peakBins: [Int] = []
        var rangeMax = -Double.infinity
        var attempts = 0
        while peakBins.count < 6 && attempts < 400 {
            attempts += 1
            var best = -1
            var bestDb = -Double.infinity
            for i in lo...hi where !masked[i] && db[i] > bestDb {
                best = i
                bestDb = db[i]
            }
            if best < 0 { break }
            let isLocalMax = db[best] >= db[best - 1] && db[best] >= db[best + 1]
            if !isLocalMax {
                masked[best] = true
                continue
            }
            if peakBins.isEmpty { rangeMax = bestDb }
            if bestDb < rangeMax - 20 { break }
            peakBins.append(best)
            let w = max(3, Int(Double(best) * 0.08))
            for j in max(lo, best - w)...min(hi, best + w) { masked[j] = true }
        }
        guard !peakBins.isEmpty else { return nil }

        func refine(_ i: Int) -> Double {
            let a = db[i - 1], b = db[i], c = db[i + 1]
            let denom = a - 2 * b + c
            let p = denom == 0 ? 0 : 0.5 * (a - c) / denom
            return (Double(i) + max(-0.5, min(0.5, p))) * binHz
        }

        // A harmonic counts when the spectrum has a clear local peak near k × f.
        func harmonicCount(_ f: Double, _ fDb: Double) -> Int {
            var count = 0
            for k in 2...4 {
                let t = f * Double(k)
                let a = Int(t * 0.97 / binHz), b = Int(t * 1.03 / binHz)
                guard a > 2, b < half - 2, b > a + 2 else { continue }
                var bi = a
                var bd = -Double.infinity
                for i in a...b where db[i] > bd { bd = db[i]; bi = i }
                let fa = max(1, Int(t * 0.85 / binHz)), fb = min(half - 1, Int(t * 1.15 / binHz))
                let around = db[fa...fb].sorted()
                let floorDb = around[around.count / 2]
                if bi > a && bi < b && bd > fDb - 35 && bd > floorDb + 10 { count += 1 }
            }
            return count
        }

        let peaks = peakBins.map { (f: refine($0), db: db[$0]) }
        let candidates = peaks.filter { $0.db >= rangeMax - 14 }   // ≥ 20 % of the main peak's amplitude
        let scored = candidates.map { (f: $0.f, db: $0.db, h: harmonicCount($0.f, $0.db)) }
        guard let chosen = scored.max(by: { a, b in
            if a.h != b.h { return a.h < b.h }
            return a.db < b.db   // same score: the louder peak wins
        }) else { return nil }

        let decay = decayRate(segment, sampleRate: sampleRate, f0: chosen.f)

        // 5. Spectrum for display.
        let dispHi = min(nyquist * 0.95, max(range.upperBound * 1.2, chosen.f * 4.5))
        let dispBins = min(half - 1, Int(dispHi / binHz))
        let step = max(1, dispBins / 300)
        var spectrum: [SpectrumPoint] = []
        var b = 1
        var idx = 0
        while b + step <= dispBins {
            var m = -Double.infinity
            for k in b..<(b + step) { m = max(m, db[k]) }
            let rel = max(-70, min(5, m - rangeMax))
            spectrum.append(SpectrumPoint(id: idx, frequency: (Double(b) + Double(step) / 2) * binHz, db: rel))
            idx += 1
            b += step
        }

        return ResonanceAnalysis(
            frequency: chosen.f,
            peaks: candidates.map(\.f).sorted(),
            harmonics: chosen.h,
            dampingRatio: decay?.zeta,
            decay30ms: decay?.t30ms,
            spectrum: spectrum,
            searchRange: range,
            segment: segment,
            sampleRate: sampleRate
        )
    }

    /// Damping of one mode: band-pass around f0, then fit the decay of the envelope in dB.
    static func decayRate(_ x: [Float], sampleRate: Double, f0: Double) -> (zeta: Double, t30ms: Double)? {
        guard f0 > 0, f0 < sampleRate / 2.2 else { return nil }
        let w0 = 2 * Double.pi * f0 / sampleRate
        let q = 5.0
        let alpha = sin(w0) / (2 * q)
        let b0 = alpha, b2 = -alpha
        let a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xi = Double(x[i])
            let yi = (b0 * xi + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = xi
            y2 = y1; y1 = yi
            y[i] = yi
        }

        // Envelope: power in 10 ms windows, in dB.
        let win = max(16, Int(0.01 * sampleRate))
        var env: [Double] = []
        var i = 0
        while i + win <= y.count {
            var s = 0.0
            for k in i..<(i + win) { s += y[k] * y[k] }
            env.append(10 * log10(s / Double(win) + 1e-30))
            i += win
        }
        guard env.count > 10, let maxIdx = env.indices.max(by: { env[$0] < env[$1] }) else { return nil }
        let peak = env[maxIdx]
        let tailCount = max(3, env.count / 10)
        let floorDb = env.suffix(tailCount).reduce(0, +) / Double(tailCount)
        let stop = max(peak - 35, floorDb + 6)
        guard peak - stop >= 10 else { return nil }

        var xs: [Double] = []
        var ys: [Double] = []
        var j = maxIdx + 1
        while j < env.count && env[j] > stop {
            xs.append(Double(j * win) / sampleRate)
            ys.append(env[j])
            j += 1
        }
        guard xs.count >= 4 else { return nil }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0
        for k in xs.indices {
            sxy += (xs[k] - mx) * (ys[k] - my)
            sxx += (xs[k] - mx) * (xs[k] - mx)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx            // dB per second, negative
        guard slope < -1 else { return nil }
        let rate = -slope
        let zeta = rate / (8.686 * 2 * Double.pi * f0)
        return (zeta, 30 / rate * 1000)
    }
}
