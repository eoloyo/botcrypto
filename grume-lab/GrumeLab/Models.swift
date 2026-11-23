import Foundation
import SwiftUI

/// One resonance measurement (a hammer knock on the end of the log).
struct ResonanceResult: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var frequency: Double          // Hz
    var lengthM: Double            // length used for the speed
    var dampingRatio: Double?      // fraction (0.01 = 1 %)
    var decay30ms: Double?         // time for the ring to drop by 30 dB
    var harmonics: Int = 0

    /// Longitudinal speed of sound: v = 2 × L × f
    var speed: Double { 2 * lengthM * frequency }
}

struct WoodLog: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var species: String = ""
    var lengthM: Double?
    var smallEndCm: Double?
    var largeEndCm: Double?
    var massKg: Double?
    var notes: String = ""
    var measurements: [ResonanceResult] = []
    var sweepCm: Double?            // bow of the log (flèche), cm
    var shape: LogShape?            // from the LiDAR scan
    var smallEnd: EndFaceResult?    // photo analysis of each end
    var largeEnd: EndFaceResult?

    /// Green softwood, order of magnitude, used when the mass is unknown.
    static let assumedGreenDensity = 850.0

    /// Frustum volume from the two end diameters (one diameter is enough).
    var volumeM3: Double? {
        guard let L = lengthM, L > 0 else { return nil }
        let ds = [smallEndCm, largeEndCm].compactMap { $0 }.filter { $0 > 0 }
        guard let first = ds.first, let last = ds.last else { return nil }
        let a = first / 100, b = last / 100
        return Double.pi * L / 12 * (a * a + a * b + b * b)
    }

    var measuredDensity: Double? {
        guard let m = massKg, m > 0, let v = volumeM3, v > 0 else { return nil }
        return m / v
    }

    var densityForCalc: (value: Double, assumed: Bool) {
        if let d = measuredDensity { return (d, false) }
        return (WoodLog.assumedGreenDensity, true)
    }

    /// Dynamic modulus of elasticity, GPa: E = ρ × v²
    func modulusGPa(speed: Double) -> Double {
        densityForCalc.value * speed * speed / 1e9
    }

    var latest: ResonanceResult? { measurements.max { $0.date < $1.date } }

    /// The scanned shape, or one estimated from the length, diameters and sweep.
    var effectiveShape: LogShape? {
        if let s = shape { return s }
        guard let L = lengthM, L > 0.3 else { return nil }
        let ds = [smallEndCm, largeEndCm].compactMap { $0 }.filter { $0 > 0 }
        guard let a = ds.first, let b = ds.last else { return nil }
        return LogShape.estimate(length: L, smallDiameter: min(a, b) / 100, largeDiameter: max(a, b) / 100,
                                 sweep: (sweepCm ?? 0) / 100)
    }

    /// Pith position along the log, in the shape's frame (metres), from the end photos.
    /// Photos are taken facing the end, phone upright: photo x maps to ∓u depending on the end.
    func pithLine(for shape: LogShape) -> ((Double) -> (x: Double, y: Double))? {
        let sorted = shape.slices.sorted { $0.z < $1.z }
        guard let first = sorted.first, let last = sorted.last, last.z > first.z else { return nil }
        let smallAtStart = first.r <= last.r
        func offset(_ e: EndFaceResult?, atStart: Bool) -> (x: Double, y: Double)? {
            guard let e else { return nil }
            let o = e.pithOffsetMm
            return ((atStart ? -o.x : o.x) / 1000, o.y / 1000)
        }
        let startOffset = offset(smallAtStart ? smallEnd : largeEnd, atStart: true)
        let endOffset = offset(smallAtStart ? largeEnd : smallEnd, atStart: false)
        guard let a = startOffset ?? endOffset, let b = endOffset ?? startOffset else { return nil }
        let p0 = (x: first.cx + a.x, y: first.cy + a.y)
        let p1 = (x: last.cx + b.x, y: last.cy + b.y)
        return { z in
            let t = (z - first.z) / (last.z - first.z)
            return (p0.x + (p1.x - p0.x) * t, p0.y + (p1.y - p0.y) * t)
        }
    }

    var meanSpeed: Double? {
        guard !measurements.isEmpty else { return nil }
        return measurements.map(\.speed).reduce(0, +) / Double(measurements.count)
    }
}

@MainActor
final class LogStore: ObservableObject {
    @Published var logs: [WoodLog] = [] {
        didSet { save() }
    }
    @Published var selectedID: UUID?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("grumes.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([WoodLog].self, from: data) {
            logs = saved
        } else {
            logs = [
                WoodLog(name: "Pin – bille de pied", species: "Pin sylvestre", lengthM: 6,
                        smallEndCm: 35, largeEndCm: 35,
                        notes: "Diamètres à préciser aux deux bouts."),
                WoodLog(name: "Pin – surbille", species: "Pin sylvestre", lengthM: 6,
                        smallEndCm: 35, largeEndCm: 35,
                        notes: "Même arbre que la bille de pied.")
            ]
            save()
        }
        selectedID = logs.first?.id
    }

    func save() {
        guard let data = try? JSONEncoder().encode(logs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    var selectedIndex: Int? { logs.firstIndex { $0.id == selectedID } }
    var selected: WoodLog? { selectedIndex.map { logs[$0] } }

    @discardableResult
    func addLog() -> UUID {
        let log = WoodLog(name: "Grume \(logs.count + 1)")
        logs.append(log)
        return log.id
    }

    func update(_ id: UUID, _ change: (inout WoodLog) -> Void) {
        guard let i = logs.firstIndex(where: { $0.id == id }) else { return }
        change(&logs[i])
    }

    func add(_ result: ResonanceResult, to id: UUID) {
        update(id) { $0.measurements.append(result) }
    }
}

enum Fmt {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        return f
    }()

    static func num(_ x: Double, _ digits: Int = 0) -> String {
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: x)) ?? String(format: "%.\(digits)f", x)
    }
}

/// Picker bound to the selected log, shared by the measuring screens.
struct LogPicker: View {
    @EnvironmentObject var store: LogStore

    var body: some View {
        Picker("Grume", selection: $store.selectedID) {
            ForEach(store.logs) { log in
                Text(log.name).tag(Optional(log.id))
            }
        }
    }
}
