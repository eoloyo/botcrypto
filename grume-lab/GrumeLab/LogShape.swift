import Foundation
import simd

/// One cross-section of the log: centre offset from the straight reference axis and radius (metres).
struct LogSlice: Codable, Hashable {
    var z: Double
    var cx: Double
    var cy: Double
    var r: Double
}

/// The log as a stack of circular cross-sections, every ~10 cm.
struct LogShape: Codable, Hashable {
    enum Source: String, Codable {
        case scan       // measured with the LiDAR
        case estimate   // built from length, diameters and sweep
    }

    var slices: [LogSlice]
    var source: Source
    var lengthM: Double

    var volume: Double { LogShape.volume(of: slices) }

    static func volume(of slices: [LogSlice]) -> Double {
        guard slices.count >= 2 else { return 0 }
        var v = 0.0
        for i in 1..<slices.count {
            let a = slices[i - 1], b = slices[i]
            v += Double.pi * (a.r * a.r + b.r * b.r) / 2 * (b.z - a.z)
        }
        return v
    }

    var smallEndDiameter: Double { 2 * min(slices.first?.r ?? 0, slices.last?.r ?? 0) }
    var largeEndDiameter: Double { 2 * max(slices.first?.r ?? 0, slices.last?.r ?? 0) }

    /// Largest distance between a centre and the straight line joining the end centres.
    var sweep: Double {
        guard let f = slices.first, let l = slices.last, l.z > f.z else { return 0 }
        var m = 0.0
        for s in slices {
            let t = (s.z - f.z) / (l.z - f.z)
            let lx = f.cx + (l.cx - f.cx) * t
            let ly = f.cy + (l.cy - f.cy) * t
            m = max(m, hypot(s.cx - lx, s.cy - ly))
        }
        return m
    }

    /// Straight taper between the two end diameters, sweep as a bow in the horizontal plane.
    static func estimate(length: Double, smallDiameter: Double, largeDiameter: Double, sweep: Double) -> LogShape {
        let n = max(2, Int((length / 0.1).rounded()) + 1)
        var slices: [LogSlice] = []
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let r = (smallDiameter + (largeDiameter - smallDiameter) * t) / 2
            slices.append(LogSlice(z: length * t, cx: sweep * 4 * t * (1 - t), cy: 0, r: r))
        }
        return LogShape(slices: slices, source: .estimate, lengthM: length)
    }
}

/// Fits a LogShape to LiDAR mesh points, given the centres of the two end faces.
enum LogShapeFitter {

    static func fit(points: [SIMD3<Float>], endA: SIMD3<Float>, endB: SIMD3<Float>, expectedRadius: Double?) -> LogShape? {
        let a = SIMD3<Double>(Double(endA.x), Double(endA.y), Double(endA.z))
        let b = SIMD3<Double>(Double(endB.x), Double(endB.y), Double(endB.z))
        let axis = b - a
        let length = simd_length(axis)
        guard length > 0.3, points.count > 200 else { return nil }
        let w = axis / length
        // v: world "up" made perpendicular to the axis; u completes the frame.
        var v = SIMD3<Double>(0, 1, 0) - w.y * w
        if simd_length(v) < 1e-3 { v = SIMD3<Double>(1, 0, 0) - w.x * w }
        v = simd_normalize(v)
        let u = simd_cross(v, w)

        var local: [SIMD3<Double>] = []
        local.reserveCapacity(points.count)
        for p in points {
            let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) - a
            let z = simd_dot(d, w)
            guard z > 0.03, z < length - 0.03 else { continue }
            local.append(SIMD3<Double>(simd_dot(d, u), simd_dot(d, v), z))
        }
        guard local.count > 200 else { return nil }

        var rRef = expectedRadius ?? 0
        if rRef <= 0 {
            let upper = local.filter { $0.y > 0 }.map { hypot($0.x, $0.y) }.filter { $0 < 0.8 }.sorted()
            guard !upper.isEmpty else { return nil }
            rRef = upper[upper.count / 2]
        }
        guard rRef > 0.03 else { return nil }

        let binCount = max(1, Int(length / 0.10))
        var bins = Array(repeating: [SIMD2<Double>](), count: binCount)
        for p in local {
            let rr = hypot(p.x, p.y)
            // Keep the log surface; drop the ground and the supports under it.
            guard rr < 1.5 * rRef, rr > 0.4 * rRef, p.y > -0.7 * rRef else { continue }
            let i = min(binCount - 1, Int(p.z / length * Double(binCount)))
            bins[i].append(SIMD2<Double>(p.x, p.y))
        }

        var fits: [LogSlice?] = []
        for i in 0..<binCount {
            let z = (Double(i) + 0.5) * length / Double(binCount)
            if let c = robustCircle(bins[i], rRef: rRef) {
                fits.append(LogSlice(z: z, cx: c.c.x, cy: c.c.y, r: c.r))
            } else {
                fits.append(nil)
            }
        }
        let found = fits.compactMap { $0 }
        guard found.count >= max(3, binCount / 3) else { return nil }

        var slices: [LogSlice] = []
        for i in 0..<binCount {
            if let f = fits[i] {
                slices.append(f)
                continue
            }
            let z = (Double(i) + 0.5) * length / Double(binCount)
            let prev = found.last { $0.z < z }
            let next = found.first { $0.z > z }
            if let p = prev, let n = next {
                let t = (z - p.z) / (n.z - p.z)
                slices.append(LogSlice(z: z, cx: p.cx + (n.cx - p.cx) * t, cy: p.cy + (n.cy - p.cy) * t, r: p.r + (n.r - p.r) * t))
            } else if let p = prev ?? next {
                slices.append(LogSlice(z: z, cx: p.cx, cy: p.cy, r: p.r))
            }
        }
        slices = medianSmooth(slices)
        if let first = slices.first {
            slices.insert(LogSlice(z: 0, cx: first.cx, cy: first.cy, r: first.r), at: 0)
        }
        if let last = slices.last {
            slices.append(LogSlice(z: length, cx: last.cx, cy: last.cy, r: last.r))
        }
        return LogShape(slices: slices, source: .scan, lengthM: length)
    }

    static func robustCircle(_ pts: [SIMD2<Double>], rRef: Double) -> (c: SIMD2<Double>, r: Double)? {
        guard pts.count >= 15 else { return nil }
        let tol = max(0.008, 0.04 * rRef)
        var best: [SIMD2<Double>] = []
        for _ in 0..<80 {
            let sample = (0..<3).map { _ in pts[Int.random(in: 0..<pts.count)] }
            guard let c = kasa(sample), c.r > 0.6 * rRef, c.r < 1.5 * rRef else { continue }
            let inliers = pts.filter { abs(simd_distance($0, c.c) - c.r) < tol }
            if inliers.count > best.count { best = inliers }
        }
        guard best.count >= max(12, pts.count * 3 / 10), let refined = kasa(best) else { return nil }
        guard refined.r > 0.5 * rRef, refined.r < 1.6 * rRef else { return nil }
        return refined
    }

    /// Algebraic least-squares circle fit.
    static func kasa(_ pts: [SIMD2<Double>]) -> (c: SIMD2<Double>, r: Double)? {
        guard pts.count >= 3 else { return nil }
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0
        var sxz = 0.0, syz = 0.0, sz = 0.0
        let n = Double(pts.count)
        for p in pts {
            let z = p.x * p.x + p.y * p.y
            sxx += p.x * p.x; sxy += p.x * p.y; syy += p.y * p.y
            sx += p.x; sy += p.y
            sxz += p.x * z; syz += p.y * z; sz += z
        }
        let m = simd_double3x3(rows: [
            SIMD3<Double>(sxx, sxy, sx),
            SIMD3<Double>(sxy, syy, sy),
            SIMD3<Double>(sx, sy, n)
        ])
        guard abs(m.determinant) > 1e-14 else { return nil }
        let sol = m.inverse * SIMD3<Double>(-sxz, -syz, -sz)
        let cx = -sol.x / 2, cy = -sol.y / 2
        let r2 = cx * cx + cy * cy - sol.z
        guard r2 > 0 else { return nil }
        return (SIMD2<Double>(cx, cy), sqrt(r2))
    }

    private static func medianSmooth(_ s: [LogSlice]) -> [LogSlice] {
        guard s.count >= 3 else { return s }
        func med(_ a: Double, _ b: Double, _ c: Double) -> Double { max(min(a, b), min(max(a, b), c)) }
        var out = s
        for i in 1..<(s.count - 1) {
            out[i].cx = med(s[i - 1].cx, s[i].cx, s[i + 1].cx)
            out[i].cy = med(s[i - 1].cy, s[i].cy, s[i + 1].cy)
            out[i].r = med(s[i - 1].r, s[i].r, s[i + 1].r)
        }
        return out
    }
}
