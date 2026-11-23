import UIKit

/// Analysis of one end of the log, from a photo: pith, rings, heartwood.
struct EndFaceResult: Codable, Hashable {
    var imageFile: String?
    var imageWidth: Double
    var imageHeight: Double
    var circleX: Double          // edge of the end (under the bark), image pixels
    var circleY: Double
    var circleR: Double
    var pithX: Double
    var pithY: Double
    var diameterMm: Double       // scale: real diameter of the circle
    var ringCount: Double
    var ringCountLow: Double
    var ringCountHigh: Double
    var meanRingWidthMm: Double
    var innerWidthMm: Double     // first third from the pith
    var middleWidthMm: Double
    var outerWidthMm: Double     // last third, under the bark
    var juvenileDiameterMm: Double?
    var heartwoodDiameterMm: Double?

    var mmPerPixel: Double { diameterMm / (2 * circleR) }

    /// Pith offset from the centre of the end, photo axes: x to the right, y up (mm).
    var pithOffsetMm: (x: Double, y: Double) {
        ((pithX - circleX) * mmPerPixel, -(pithY - circleY) * mmPerPixel)
    }

    /// Pith offset as a fraction of the radius.
    var eccentricity: Double {
        hypot(pithOffsetMm.x, pithOffsetMm.y) / (diameterMm / 2)
    }
}

struct RingAnalysis {
    var result: EndFaceResult
    var boundaryPoints: [CGPoint]   // detected ring boundaries, image pixels
}

/// Grey and "redness" (R − B) planes of a photo, at most 2000 px on the long side.
struct PixelImage {
    let width: Int
    let height: Int
    let gray: [Float]
    let redness: [Float]
    let uiImage: UIImage

    init?(_ image: UIImage, maxSide: CGFloat = 2000) {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = upright.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var g = [Float](repeating: 0, count: w * h)
        var red = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[4 * i]), gg = Float(rgba[4 * i + 1]), b = Float(rgba[4 * i + 2])
            g[i] = 0.299 * r + 0.587 * gg + 0.114 * b
            red[i] = r - b
        }
        width = w
        height = h
        gray = g
        redness = red
        uiImage = upright
    }

    func sample(_ plane: [Float], _ x: Double, _ y: Double) -> Float {
        let xc = min(max(x, 0), Double(width - 2)), yc = min(max(y, 0), Double(height - 2))
        let x0 = Int(xc), y0 = Int(yc)
        let fx = Float(xc - Double(x0)), fy = Float(yc - Double(y0))
        let i = y0 * width + x0
        let a = plane[i] * (1 - fx) + plane[i + 1] * fx
        let b = plane[i + width] * (1 - fx) + plane[i + width + 1] * fx
        return a * (1 - fy) + b * fy
    }
}

enum EndFaceAnalyzer {

    // MARK: pith

    /// Ring edges are perpendicular to the radius, so lines drawn along the image
    /// gradient all cross near the pith: the pith is where most lines meet.
    static func findPith(_ img: PixelImage, cx: Double, cy: Double, r: Double) -> (x: Double, y: Double) {
        let sc = min(1.0, 400 / max(1, 2 * r))
        let k = max(1, Int((1 / sc).rounded()))
        let sw = max(8, img.width / k), sh = max(8, img.height / k)
        var small = [Float](repeating: 0, count: sw * sh)
        for y in 0..<sh {
            for x in 0..<sw {
                var s: Float = 0
                for dy in 0..<k {
                    let row = min(img.height - 1, y * k + dy) * img.width
                    for dx in 0..<k { s += img.gray[row + min(img.width - 1, x * k + dx)] }
                }
                small[y * sw + x] = s / Float(k * k)
            }
        }
        let s = blur(small, sw, sh, sigma: 1.5)
        let scx = cx / Double(k), scy = cy / Double(k), sr = r / Double(k)

        var gx = [Float](repeating: 0, count: sw * sh)
        var gy = [Float](repeating: 0, count: sw * sh)
        var mag = [Float](repeating: 0, count: sw * sh)
        var mask = [Bool](repeating: false, count: sw * sh)
        var inMask: [Float] = []
        for y in 1..<(sh - 1) {
            for x in 1..<(sw - 1) {
                let i = y * sw + x
                gx[i] = (s[i + 1] - s[i - 1]) / 2
                gy[i] = (s[i + sw] - s[i - sw]) / 2
                mag[i] = (gx[i] * gx[i] + gy[i] * gy[i]).squareRoot()
                let dx = Double(x) - scx, dy = Double(y) - scy
                if dx * dx + dy * dy < (0.9 * sr) * (0.9 * sr) {
                    mask[i] = true
                    inMask.append(mag[i])
                }
            }
        }
        guard !inMask.isEmpty else { return (cx, cy) }
        inMask.sort()
        let threshold = inMask[inMask.count * 3 / 4]

        var acc = [Float](repeating: 0, count: sw * sh)
        let reach = Int(1.2 * sr)
        var counter = 0
        for y in 1..<(sh - 1) {
            for x in 1..<(sw - 1) {
                let i = y * sw + x
                guard mask[i], mag[i] > threshold else { continue }
                counter += 1
                if counter % 2 != 0 { continue }
                let ux = Double(gx[i] / mag[i]), uy = Double(gy[i] / mag[i])
                for t in -reach...reach {
                    let px = Int((Double(x) + Double(t) * ux).rounded())
                    let py = Int((Double(y) + Double(t) * uy).rounded())
                    if px >= 0 && px < sw && py >= 0 && py < sh { acc[py * sw + px] += 1 }
                }
            }
        }
        let accB = blur(acc, sw, sh, sigma: 2)
        var best = -1
        var bestV: Float = -1
        for i in 0..<(sw * sh) where mask[i] && accB[i] > bestV {
            bestV = accB[i]
            best = i
        }
        guard best >= 0 else { return (cx, cy) }
        return ((Double(best % sw) + 0.5) * Double(k), (Double(best / sw) + 0.5) * Double(k))
    }

    // MARK: rings

    static func analyze(_ img: PixelImage, cx: Double, cy: Double, r: Double,
                        pithX: Double, pithY: Double, diameterMm: Double) -> RingAnalysis? {
        let rays = 72
        var counts: [Double] = []
        var points: [CGPoint] = []
        var zoneSum = [0.0, 0.0, 0.0], zoneN = [0.0, 0.0, 0.0]
        var juvenile: [Double] = []
        var heart: [Double] = []
        var edges: [Double] = []

        for k in 0..<rays {
            let a = 2 * Double.pi * Double(k) / Double(rays)
            let ux = cos(a), uy = sin(a)
            guard let R = edgeDistance(pithX, pithY, cx, cy, r, ux, uy), R > 30 else { continue }
            edges.append(R)
            let start = 0.02 * R, end = 0.985 * R, step = 0.5
            let n = Int((end - start) / step)
            guard n > 40 else { continue }
            var prof = [Float](repeating: 0, count: n)
            var red = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let rr = start + Double(i) * step
                var sum: Float = 0
                for d in [-1.5, 0.0, 1.5] {
                    sum += img.sample(img.gray, pithX + rr * ux - d * uy, pithY + rr * uy + d * ux)
                }
                prof[i] = sum / 3
                red[i] = img.sample(img.redness, pithX + rr * ux, pithY + rr * uy)
            }
            let sm = smooth1D(highPass(prof, window: 41), sigma: 2.4)
            let mean = sm.reduce(0, +) / Float(n)
            let sd = (sm.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(n)).squareRoot()

            var mins: [Double] = []
            var lastR = -1e9
            var lastV: Float = 0
            for i in 2..<(n - 2) where sm[i] < sm[i - 1] && sm[i] <= sm[i + 1] && sm[i] < -0.25 * sd {
                let rr = start + Double(i) * step
                if rr - lastR >= 3 {
                    mins.append(rr)
                    lastR = rr
                    lastV = sm[i]
                } else if sm[i] < lastV {
                    mins[mins.count - 1] = rr
                    lastR = rr
                    lastV = sm[i]
                }
            }
            guard mins.count >= 4 else { continue }
            var spacing: [Double] = []
            for i in 1..<mins.count { spacing.append(mins[i] - mins[i - 1]) }
            let firstSp = spacing.prefix(3).reduce(0, +) / Double(min(3, spacing.count))
            let lastSp = spacing.suffix(3).reduce(0, +) / Double(min(3, spacing.count))
            let inner = max(0, mins[0] / firstSp - 1)
            let outer = (R - mins[mins.count - 1]) / lastSp
            counts.append(Double(mins.count) + inner + outer)

            for (j, w) in spacing.enumerated() {
                let mid = (mins[j] + mins[j + 1]) / 2 / R
                let zone = mid < 1.0 / 3 ? 0 : (mid < 2.0 / 3 ? 1 : 2)
                zoneSum[zone] += w
                zoneN[zone] += 1
            }
            let j = 11 - Int(inner.rounded())
            if j >= 0 && j < mins.count { juvenile.append(mins[j]) }
            if let h = heartBoundary(red, start: start, step: step, R: R) { heart.append(h) }
            for rr in mins { points.append(CGPoint(x: pithX + rr * ux, y: pithY + rr * uy)) }
        }
        guard counts.count >= rays / 3, !edges.isEmpty else { return nil }
        counts.sort()
        edges.sort()
        let count = counts[counts.count / 2]
        let mmPerPx = diameterMm / (2 * r)
        let meanEdge = edges[edges.count / 2]
        func zoneMm(_ z: Int) -> Double { zoneN[z] > 0 ? zoneSum[z] / zoneN[z] * mmPerPx : 0 }
        juvenile.sort()
        heart.sort()
        let result = EndFaceResult(
            imageFile: nil,
            imageWidth: Double(img.width), imageHeight: Double(img.height),
            circleX: cx, circleY: cy, circleR: r,
            pithX: pithX, pithY: pithY,
            diameterMm: diameterMm,
            ringCount: count,
            ringCountLow: counts[counts.count / 4],
            ringCountHigh: counts[counts.count * 3 / 4],
            meanRingWidthMm: meanEdge * mmPerPx / max(1, count),
            innerWidthMm: zoneMm(0), middleWidthMm: zoneMm(1), outerWidthMm: zoneMm(2),
            juvenileDiameterMm: count >= 15 && juvenile.count >= rays / 3 ? 2 * juvenile[juvenile.count / 2] * mmPerPx : nil,
            heartwoodDiameterMm: heart.count >= rays / 2 ? 2 * heart[heart.count / 2] * mmPerPx : nil
        )
        return RingAnalysis(result: result, boundaryPoints: points)
    }

    /// Heartwood is redder than sapwood: largest drop of R − B along the ray.
    private static func heartBoundary(_ red: [Float], start: Double, step: Double, R: Double) -> Double? {
        let n = red.count
        let win = max(3, Int(0.08 * R / step))
        let s = movingAverage(red, window: win)
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(s[i]) }
        let a = n / 20, lo = n / 10, hi = n * 95 / 100
        guard hi > lo + 2, lo > a else { return nil }
        var best = 0.0
        var bestI = -1
        for i in lo..<hi {
            let inner = (prefix[i] - prefix[a]) / Double(i - a)
            let outer = (prefix[n] - prefix[i]) / Double(n - i)
            if inner - outer > best {
                best = inner - outer
                bestI = i
            }
        }
        guard bestI >= 0, best > 8 else { return nil }
        return start + Double(bestI) * step
    }

    static func edgeDistance(_ px: Double, _ py: Double, _ cx: Double, _ cy: Double, _ r: Double,
                             _ ux: Double, _ uy: Double) -> Double? {
        let ox = px - cx, oy = py - cy
        let b = ux * ox + uy * oy
        let c = ox * ox + oy * oy - r * r
        let disc = b * b - c
        guard disc > 0 else { return nil }
        let t = -b + disc.squareRoot()
        return t > 0 ? t : nil
    }

    // MARK: signal helpers

    private static func movingAverage(_ v: [Float], window: Int) -> [Float] {
        let n = v.count, h = window / 2
        var prefix = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + v[i] }
        return (0..<n).map { i in
            let a = max(0, i - h), b = min(n, i + h + 1)
            return (prefix[b] - prefix[a]) / Float(b - a)
        }
    }

    private static func highPass(_ v: [Float], window: Int) -> [Float] {
        let trend = movingAverage(v, window: window)
        return zip(v, trend).map { $0 - $1 }
    }

    private static func smooth1D(_ v: [Float], sigma: Double) -> [Float] {
        let r = max(1, Int(3 * sigma))
        let kernel = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let ks = kernel.reduce(0, +)
        let n = v.count
        return (0..<n).map { i in
            var s: Float = 0
            for (j, w) in kernel.enumerated() {
                let idx = min(n - 1, max(0, i + j - r))
                s += v[idx] * w
            }
            return s / ks
        }
    }

    private static func blur(_ a: [Float], _ w: Int, _ h: Int, sigma: Double) -> [Float] {
        let r = max(1, Int(3 * sigma))
        let kernel = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let ks = kernel.reduce(0, +)
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for (j, k) in kernel.enumerated() { s += a[y * w + min(w - 1, max(0, x + j - r))] * k }
                tmp[y * w + x] = s / ks
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for (j, k) in kernel.enumerated() { s += tmp[min(h - 1, max(0, y + j - r)) * w + x] * k }
                out[y * w + x] = s / ks
            }
        }
        return out
    }

    // MARK: demo

    /// Synthetic end grain for the simulator: 48 rings, off-centre pith, red heartwood.
    static func demoImage(size: Int = 1000) -> UIImage {
        let n = 48
        let R = Double(size) * 0.42
        let cx = Double(size) / 2, cy = Double(size) / 2
        let px = cx + 0.08 * R, py = cy - 0.05 * R
        var widths = (0..<n).map { 1.8 - 1.2 * Double($0) / Double(n - 1) }
        let total = widths.reduce(0, +)
        widths = widths.map { $0 / total }
        var bounds: [Double] = []
        var acc = 0.0
        for w in widths { acc += w; bounds.append(acc) }
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) % 1000) / 1000 - 0.5
        }
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let dxc = Double(x) - cx, dyc = Double(y) - cy
                var r = 70.0, g = 80.0, b = 60.0
                if dxc * dxc + dyc * dyc < R * R {
                    let a = atan2(Double(y) - py, Double(x) - px)
                    let ux = cos(a), uy = sin(a)
                    let edge = edgeDistance(px, py, cx, cy, R, ux, uy) ?? R
                    let d = hypot(Double(x) - px, Double(y) - py) / edge * (1 + 0.015 * sin(5 * a))
                    var left = 0, right = n - 1
                    while left < right {
                        let mid = (left + right) / 2
                        if bounds[mid] >= d { right = mid } else { left = mid + 1 }
                    }
                    let hi = bounds[left]
                    let lo = left > 0 ? bounds[left - 1] : 0
                    let frac = (d - lo) / max(1e-6, hi - lo)
                    let late = frac > 0.75 ? 1.0 : 0.0
                    let heartwood = d < 0.6
                    r = (heartwood ? 215 : 222) - 45 * late
                    g = (heartwood ? 165 : 200) - 45 * late
                    b = (heartwood ? 130 : 160) - 40 * late
                    let nz = 16 * noise() + 5 * sin(Double(x) * 0.15 + Double(y) * 0.05)
                    r += nz; g += nz; b += nz
                }
                rgba[i] = UInt8(max(0, min(255, r)))
                rgba[i + 1] = UInt8(max(0, min(255, g)))
                rgba[i + 2] = UInt8(max(0, min(255, b)))
                rgba[i + 3] = 255
            }
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return UIImage()
        }
        return UIImage(cgImage: cg)
    }
}

/// End photos stored next to the log data.
enum EndFaceStorage {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bouts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ image: UIImage, name: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let file = name + ".jpg"
        do {
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    static func load(_ file: String) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(file).path)
    }
}
