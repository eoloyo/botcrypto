import Foundation

struct Disk: Hashable {
    var x: Double
    var y: Double
    var r: Double
}

struct CutSettings {
    var kerf: Double              // m
    var boardThickness: Double    // m
    var minBoardWidth: Double     // m
    var beamSections: [(b: Double, h: Double)]
    var preferBeams: Bool
    var allowBucking: Bool
    var minPieceLength: Double    // m
    var centerOnPith: Bool = true

    /// "20x20 15x22,5 7,5x22,5" (cm) → sections in metres.
    static func parseSections(_ text: String) -> [(b: Double, h: Double)] {
        text.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "\n" }).compactMap { token in
            let parts = token.lowercased()
                .replacingOccurrences(of: ",", with: ".")
                .split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == "*" })
            guard parts.count == 2, let b = Double(parts[0]), let h = Double(parts[1]), b > 0, h > 0 else { return nil }
            return (b / 100, h / 100)
        }
    }
}

struct CutPiece: Hashable {
    enum Kind: Hashable { case beam, board }
    var kind: Kind
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double
    var containsPith = false

    var width: Double { x1 - x0 }
    var height: Double { y1 - y0 }
    var area: Double { width * height }
}

/// How one length of log (the whole log or one part after cross-cutting) is sawn.
struct SegmentPlan: Identifiable {
    let id = UUID()
    var z0: Double
    var z1: Double
    var angle: Double            // the cross-section is rotated by -angle in the pattern frame
    var pattern: String
    var pieces: [CutPiece]
    var disks: [Disk]            // pattern frame, small end first
    var centerX: Double
    var centerY: Double
    var logVolume: Double
    var score: Double
    var pithSmall: PlanePoint?   // pith at the small and large end of this length, pattern frame
    var pithLarge: PlanePoint?

    var length: Double { z1 - z0 }
    var piecesVolume: Double { pieces.reduce(0) { $0 + $1.area } * length }
}

struct PlanePoint: Hashable {
    var x: Double
    var y: Double
}

struct CutPlan: Identifiable {
    let id = UUID()
    var title: String
    var segments: [SegmentPlan]

    var logVolume: Double { segments.reduce(0) { $0 + $1.logVolume } }
    var piecesVolume: Double { segments.reduce(0) { $0 + $1.piecesVolume } }
    var yield: Double { logVolume > 0 ? piecesVolume / logVolume : 0 }
    var score: Double { segments.reduce(0) { $0 + $1.score } }
}

/// The usable cross-section of a straight length of log is the intersection of all its
/// slice circles (taper and sweep make it shrink). It is convex, so a rectangle fits
/// when its four corners are inside every circle.
enum Region {
    static func inside(_ x: Double, _ y: Double, _ disks: [Disk]) -> Bool {
        for d in disks {
            let dx = x - d.x, dy = y - d.y
            if dx * dx + dy * dy > d.r * d.r { return false }
        }
        return true
    }

    static func fits(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ disks: [Disk]) -> Bool {
        inside(x0, y0, disks) && inside(x1, y0, disks) && inside(x0, y1, disks) && inside(x1, y1, disks)
    }

    static func xRange(atY y: Double, _ disks: [Disk]) -> (lo: Double, hi: Double)? {
        var lo = -Double.infinity, hi = Double.infinity
        for d in disks {
            let dy = y - d.y
            let s = d.r * d.r - dy * dy
            if s <= 0 { return nil }
            let h = s.squareRoot()
            lo = max(lo, d.x - h)
            hi = min(hi, d.x + h)
            if lo >= hi { return nil }
        }
        return (lo, hi)
    }

    static func yRange(atX x: Double, _ disks: [Disk]) -> (lo: Double, hi: Double)? {
        var lo = -Double.infinity, hi = Double.infinity
        for d in disks {
            let dx = x - d.x
            let s = d.r * d.r - dx * dx
            if s <= 0 { return nil }
            let h = s.squareRoot()
            lo = max(lo, d.y - h)
            hi = min(hi, d.y + h)
            if lo >= hi { return nil }
        }
        return (lo, hi)
    }

    static func yExtent(_ disks: [Disk]) -> (lo: Double, hi: Double)? {
        guard !disks.isEmpty else { return nil }
        var lo = disks.map { $0.y - $0.r }.max()!
        var hi = disks.map { $0.y + $0.r }.min()!
        while lo < hi && xRange(atY: lo, disks) == nil { lo += 0.001 }
        while hi > lo && xRange(atY: hi, disks) == nil { hi -= 0.001 }
        return hi > lo ? (lo, hi) : nil
    }

    /// Point farthest from the region's edge.
    static func innerCenter(_ disks: [Disk]) -> (x: Double, y: Double) {
        var cx = disks.map(\.x).reduce(0, +) / Double(disks.count)
        var cy = disks.map(\.y).reduce(0, +) / Double(disks.count)
        func clearance(_ x: Double, _ y: Double) -> Double {
            disks.map { $0.r - hypot(x - $0.x, y - $0.y) }.min() ?? 0
        }
        var step = (disks.map(\.r).min() ?? 0.1) / 4
        var best = clearance(cx, cy)
        while step > 0.0005 {
            var improved = false
            let moves: [(Double, Double)] = [(step, 0), (-step, 0), (0, step), (0, -step),
                                             (step, step), (-step, -step), (step, -step), (-step, step)]
            for (dx, dy) in moves {
                let c = clearance(cx + dx, cy + dy)
                if c > best {
                    best = c
                    cx += dx
                    cy += dy
                    improved = true
                    break
                }
            }
            if !improved { step /= 2 }
        }
        return (cx, cy)
    }

    /// Outline of the region, for drawing.
    static func boundary(_ disks: [Disk], cx: Double, cy: Double, steps: Int = 144) -> [(x: Double, y: Double)] {
        (0..<steps).map { i in
            let a = 2 * Double.pi * Double(i) / Double(steps)
            let ux = cos(a), uy = sin(a)
            var t = Double.infinity
            for d in disks {
                let ox = cx - d.x, oy = cy - d.y
                let b = ux * ox + uy * oy
                let c = ox * ox + oy * oy - d.r * d.r
                let disc = b * b - c
                if disc > 0 { t = min(t, -b + disc.squareRoot()) } else { t = 0 }
            }
            if !t.isFinite { t = 0 }
            return (cx + t * ux, cy + t * uy)
        }
    }

    static func rotate(_ disks: [Disk], by a: Double) -> [Disk] {
        let c = cos(a), s = sin(a)
        return disks.map { Disk(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c, r: $0.r) }
    }
}

enum CutOptimizer {

    // MARK: boards

    /// Edged board between two horizontal saw lines, as wide as the region allows (whole cm).
    static func horizontalBoard(_ y0: Double, _ y1: Double, _ disks: [Disk], _ s: CutSettings) -> CutPiece? {
        guard let a = Region.xRange(atY: y0, disks), let b = Region.xRange(atY: y1, disks) else { return nil }
        let lo = max(a.lo, b.lo), hi = min(a.hi, b.hi)
        let w = ((hi - lo) * 100 + 1e-9).rounded(.down) / 100
        guard w >= s.minBoardWidth else { return nil }
        let c = (lo + hi) / 2
        return CutPiece(kind: .board, x0: c - w / 2, y0: y0, x1: c + w / 2, y1: y1)
    }

    /// Board cut from the side of the cant, between two vertical saw lines.
    static func verticalBoard(_ x0: Double, _ x1: Double, yLo: Double, yHi: Double, _ disks: [Disk], _ s: CutSettings) -> CutPiece? {
        guard let a = Region.yRange(atX: x0, disks), let b = Region.yRange(atX: x1, disks) else { return nil }
        let lo = max(a.lo, b.lo, yLo), hi = min(a.hi, b.hi, yHi)
        let h = ((hi - lo) * 100 + 1e-9).rounded(.down) / 100
        guard h >= s.minBoardWidth else { return nil }
        let c = (lo + hi) / 2
        return CutPiece(kind: .board, x0: x0, y0: c - h / 2, x1: x1, y1: c + h / 2)
    }

    /// Through-and-through sawing: parallel boards, edged.
    static func boardsOnly(_ disks: [Disk], _ s: CutSettings) -> [CutPiece]? {
        guard let ext = Region.yExtent(disks) else { return nil }
        let t = s.boardThickness, k = s.kerf
        var best: [CutPiece] = []
        var bestArea = 0.0
        var offset = 0.0
        while offset < t + k {
            var pieces: [CutPiece] = []
            var y = ext.lo + offset
            while y + t <= ext.hi {
                if let p = horizontalBoard(y, y + t, disks, s) { pieces.append(p) }
                y += t + k
            }
            let area = pieces.reduce(0) { $0 + $1.area }
            if area > bestArea {
                bestArea = area
                best = pieces
            }
            offset += 0.002
        }
        return best.isEmpty ? nil : best
    }

    /// One or two beams in the middle, boards above and below, then boards on the sides.
    static func cant(_ disks: [Disk], cx: Double, cy: Double, b: Double, h: Double, n: Int, _ s: CutSettings) -> [CutPiece]? {
        let k = s.kerf, t = s.boardThickness
        let totalW = Double(n) * b + Double(n - 1) * k
        let x0 = cx - totalW / 2, y0 = cy - h / 2
        let x1 = x0 + totalW, y1 = y0 + h
        guard Region.fits(x0, y0, x1, y1, disks) else { return nil }
        var pieces: [CutPiece] = (0..<n).map { i in
            let bx = x0 + Double(i) * (b + k)
            return CutPiece(kind: .beam, x0: bx, y0: y0, x1: bx + b, y1: y1)
        }
        var y = y1 + k
        while let p = horizontalBoard(y, y + t, disks, s) {
            pieces.append(p)
            y += t + k
        }
        y = y0 - k
        while let p = horizontalBoard(y - t, y, disks, s) {
            pieces.append(p)
            y -= t + k
        }
        var x = x1 + k
        while let p = verticalBoard(x, x + t, yLo: y0, yHi: y1, disks, s) {
            pieces.append(p)
            x += t + k
        }
        x = x0 - k
        while let p = verticalBoard(x - t, x, yLo: y0, yHi: y1, disks, s) {
            pieces.append(p)
            x -= t + k
        }
        return pieces
    }

    // MARK: one length of log

    typealias PithLine = (Double) -> (x: Double, y: Double)

    static func segmentPlan(_ slices: [LogSlice], z0: Double, z1: Double, beams: Bool, _ s: CutSettings,
                            pith: PithLine? = nil) -> SegmentPlan? {
        let seg = slices.filter { $0.z >= z0 - 1e-6 && $0.z <= z1 + 1e-6 }
        guard seg.count >= 2 else { return nil }
        var base = seg.map { Disk(x: $0.cx, y: $0.cy, r: $0.r) }
        let smallFirst = (seg.first?.r ?? 0) <= (seg.last?.r ?? 0)
        if !smallFirst { base.reverse() }   // small end first
        let pithEnds: (small: PlanePoint, large: PlanePoint)? = pith.map { f in
            let a = f(z0), b = f(z1)
            let pa = PlanePoint(x: a.x, y: a.y), pb = PlanePoint(x: b.x, y: b.y)
            return smallFirst ? (pa, pb) : (pb, pa)
        }
        let logVolume = LogShape.volume(of: seg)
        let length = z1 - z0
        let beamWeight = s.preferBeams ? 1.35 : 1.0
        let shifts = [-0.01, -0.005, 0.0, 0.005, 0.01]
        var best: SegmentPlan?

        let angles = beams ? [0.0, Double.pi / 2] : [0.0, Double.pi / 4, Double.pi / 2, 3 * Double.pi / 4]
        for angle in angles {
            let disks = Region.rotate(base, by: -angle)
            let ca = cos(-angle), sa = sin(-angle)
            func rot(_ p: PlanePoint) -> PlanePoint { PlanePoint(x: p.x * ca - p.y * sa, y: p.x * sa + p.y * ca) }
            let pithS = pithEnds.map { rot($0.small) }
            let pithL = pithEnds.map { rot($0.large) }
            var c = Region.innerCenter(disks)
            if s.centerOnPith, beams, let ps = pithS, let pl = pithL {
                let m = (x: (ps.x + pl.x) / 2, y: (ps.y + pl.y) / 2)
                if Region.inside(m.x, m.y, disks) { c = m }
            }
            func markPith(_ pieces: [CutPiece]) -> [CutPiece] {
                pieces.map { p in
                    var q = p
                    for pt in [pithS, pithL].compactMap({ $0 }) where pt.x > p.x0 && pt.x < p.x1 && pt.y > p.y0 && pt.y < p.y1 {
                        q.containsPith = true
                    }
                    return q
                }
            }
            if beams {
                for sec in s.beamSections {
                    for (b, h) in [(sec.b, sec.h), (sec.h, sec.b)] {
                        for n in 1...2 {
                            for dx in shifts {
                                for dy in shifts {
                                    guard let pieces = cant(disks, cx: c.x + dx, cy: c.y + dy, b: b, h: h, n: n, s) else { continue }
                                    let score = pieces.reduce(0.0) { $0 + $1.area * ($1.kind == .beam ? beamWeight : 1) } * length
                                    if score > (best?.score ?? 0) {
                                        best = SegmentPlan(z0: z0, z1: z1, angle: angle,
                                                           pattern: n == 1 ? "Poutre et planches" : "Deux poutres et planches",
                                                           pieces: markPith(pieces), disks: disks, centerX: c.x, centerY: c.y,
                                                           logVolume: logVolume, score: score,
                                                           pithSmall: pithS, pithLarge: pithL)
                                    }
                                }
                            }
                        }
                    }
                }
            } else if let pieces = boardsOnly(disks, s) {
                let score = pieces.reduce(0) { $0 + $1.area } * length
                if score > (best?.score ?? 0) {
                    best = SegmentPlan(z0: z0, z1: z1, angle: angle, pattern: "Planches (sciage en plot)",
                                       pieces: markPith(pieces), disks: disks, centerX: c.x, centerY: c.y,
                                       logVolume: logVolume, score: score,
                                       pithSmall: pithS, pithLarge: pithL)
                }
            }
        }
        return best
    }

    /// Best plan for a length, following the beam preference.
    static func preferredPlan(_ slices: [LogSlice], z0: Double, z1: Double, _ s: CutSettings,
                              pith: PithLine? = nil) -> SegmentPlan? {
        let withBeams = s.beamSections.isEmpty ? nil : segmentPlan(slices, z0: z0, z1: z1, beams: true, s, pith: pith)
        if s.preferBeams, let p = withBeams { return p }
        let boards = segmentPlan(slices, z0: z0, z1: z1, beams: false, s, pith: pith)
        switch (withBeams, boards) {
        case let (a?, b?): return a.piecesVolume >= b.piecesVolume ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    // MARK: whole log

    private static func meters(_ x: Double) -> String {
        String(format: "%.2f", x).replacingOccurrences(of: ".", with: ",")
    }

    static func plans(for shape: LogShape, settings s: CutSettings, pith: PithLine? = nil) -> [CutPlan] {
        let slices = shape.slices.sorted { $0.z < $1.z }
        guard let start = slices.first?.z, let end = slices.last?.z, end - start > 0.3 else { return [] }

        var result: [CutPlan] = []
        let whole = preferredPlan(slices, z0: start, z1: end, s, pith: pith).map {
            CutPlan(title: "Sans tronçonner (\(meters(end - start)) m)", segments: [$0])
        }

        var bucked: CutPlan?
        if s.allowBucking {
            var cut = start + s.minPieceLength
            while cut <= end - s.minPieceLength + 1e-9 {
                if let a = preferredPlan(slices, z0: start, z1: cut, s, pith: pith),
                   let b = preferredPlan(slices, z0: cut, z1: end, s, pith: pith) {
                    let plan = CutPlan(title: "Tronçonner à \(meters(cut - start)) m", segments: [a, b])
                    if plan.score > (bucked?.score ?? 0) { bucked = plan }
                }
                cut += 0.5
            }
        }

        if let b = bucked, let w = whole, b.score > w.score * 1.02 {
            result = [b, w]
        } else if let w = whole {
            result = [w]
        } else if let b = bucked {
            result = [b]
        }

        if s.preferBeams, let boards = segmentPlan(slices, z0: start, z1: end, beams: false, s, pith: pith) {
            result.append(CutPlan(title: "Planches seulement", segments: [boards]))
        }
        return result
    }
}
