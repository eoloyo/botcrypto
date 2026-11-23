import SwiftUI
import SceneKit

struct CutPlanView: View {
    @EnvironmentObject var store: LogStore
    @AppStorage("cut.kerfMm") private var kerfMm = 3.0
    @AppStorage("cut.boardMm") private var boardMm = 27.0
    @AppStorage("cut.minBoardCm") private var minBoardCm = 8.0
    @AppStorage("cut.sections") private var sectionsText = "20x20 15x22,5 15x15 12x12 10x20 7,5x22,5 7,5x15 6,3x17,5"
    @AppStorage("cut.preferBeams") private var preferBeams = true
    @AppStorage("cut.bucking") private var allowBucking = true
    @AppStorage("cut.minLength") private var minLength = 2.0
    @AppStorage("cut.centerOnPith") private var centerOnPith = true

    @State private var plans: [CutPlan] = []
    @State private var planShape: LogShape?
    @State private var selected = 0
    @State private var computing = false
    @State private var show3D = false
    @State private var demoShape: LogShape?
    @State private var juvenileRadius: Double?

    private var shape: LogShape? { demoShape ?? store.selected?.effectiveShape }

    /// Pith along the log, from the end photos (or the demo).
    private func pithLine(for sh: LogShape) -> CutOptimizer.PithLine? {
        if demoShape != nil {
            return { z in (0.02 + (0.035 - 0.02) * z / 6, 0.015 - 0.025 * z / 6) }
        }
        return store.selected?.pithLine(for: sh)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section("Grume") {
                    if demoShape == nil { LogPicker() } else { Text("Grume de démonstration").foregroundStyle(.secondary) }
                    if let sh = shape {
                        LabeledContent("Forme", value: sh.source == .scan ? "scan 3D" : "estimée")
                        LabeledContent("Longueur", value: "\(Fmt.num(sh.lengthM, 2)) m")
                        LabeledContent("Ø petit / gros bout", value: "\(Fmt.num(sh.smallEndDiameter * 100, 1)) / \(Fmt.num(sh.largeEndDiameter * 100, 1)) cm")
                        LabeledContent("Courbure (flèche)", value: "\(Fmt.num(sh.sweep * 100, 1)) cm")
                        LabeledContent("Volume", value: "\(Fmt.num(sh.volume, 3)) m³")
                        if sh.source == .estimate {
                            Text("Forme estimée à partir de la longueur, des diamètres et de la courbure saisis dans l'onglet Grumes. Pour la forme réelle, faites un scan 3D dans l'onglet LiDAR.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Saisissez la longueur et les diamètres de la grume dans l'onglet Grumes, ou faites un scan 3D.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Sciage") {
                    NumberField(title: "Trait de scie", unit: "mm", value: doubleBinding($kerfMm))
                    NumberField(title: "Épaisseur des planches", unit: "mm", value: doubleBinding($boardMm))
                    NumberField(title: "Largeur mini d'une planche", unit: "cm", value: doubleBinding($minBoardCm))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sections de poutres (cm)")
                        TextField("20x20 15x22,5", text: $sectionsText)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("Priorité aux poutres", isOn: $preferBeams)
                    Toggle("Centrer la poutre sur le cœur", isOn: $centerOnPith)
                    Toggle("Essayer de tronçonner", isOn: $allowBucking)
                    if allowBucking {
                        NumberField(title: "Longueur mini d'un tronçon", unit: "m", value: doubleBinding($minLength))
                    }
                }

                Section {
                    Button {
                        compute()
                    } label: {
                        HStack {
                            if computing { ProgressView().padding(.trailing, 4) }
                            Text(computing ? "Calcul…" : "Calculer le plan de coupe")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(shape == nil || computing)
                }
                .id("calculer")

                if !plans.isEmpty {
                    if plans.count > 1 {
                        Section {
                            Picker("Plan", selection: $selected) {
                                ForEach(plans.indices, id: \.self) { i in
                                    Text(plans[i].title).tag(i)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                    if plans.indices.contains(selected) {
                        PlanDetail(plan: plans[selected], comparedTo: selected == 0 && plans.count > 1 ? plans[1] : nil,
                                   juvenileRadius: juvenileRadius) {
                            show3D = true
                        }
                    }
                }
            }
            .navigationTitle("Plan de coupe")
            .scrollDismissesKeyboard(.interactively)
            .onAppear(perform: startDemoIfNeeded)
            .onChange(of: store.selectedID) { _, _ in plans = [] }
            .onChange(of: plans.count) { _, count in
                if count > 0 {
                    withAnimation { proxy.scrollTo("calculer", anchor: .top) }
                }
            }
            .sheet(isPresented: $show3D) {
                NavigationStack {
                    if let sh = planShape, plans.indices.contains(selected) {
                        Log3DView(shape: sh, plan: plans[selected])
                            .ignoresSafeArea(edges: .bottom)
                            .navigationTitle("Grume en 3D")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                Button("Fermer") { show3D = false }
                            }
                    }
                }
            }
            }
        }
    }

    private func doubleBinding(_ b: Binding<Double>) -> Binding<Double?> {
        Binding(get: { b.wrappedValue }, set: { if let v = $0, v >= 0 { b.wrappedValue = v } })
    }

    private var settings: CutSettings {
        CutSettings(kerf: kerfMm / 1000,
                    boardThickness: max(0.005, boardMm / 1000),
                    minBoardWidth: max(0.02, minBoardCm / 100),
                    beamSections: CutSettings.parseSections(sectionsText),
                    preferBeams: preferBeams,
                    allowBucking: allowBucking,
                    minPieceLength: max(0.5, minLength),
                    centerOnPith: centerOnPith)
    }

    private func compute() {
        guard let sh = shape else { return }
        computing = true
        let s = settings
        let pith = pithLine(for: sh)
        if demoShape != nil {
            juvenileRadius = 0.06
        } else {
            juvenileRadius = store.selected?.smallEnd?.juvenileDiameterMm.map { $0 / 2000 }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CutOptimizer.plans(for: sh, settings: s, pith: pith)
            DispatchQueue.main.async {
                plans = result
                planShape = sh
                selected = 0
                computing = false
                if UserDefaults.standard.bool(forKey: "demo3D"), !result.isEmpty { show3D = true }
            }
        }
    }

    /// Launch argument "-demoCut YES": 6 m log, Ø 30 → 38 cm, 3 cm of sweep.
    private func startDemoIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "demoCut"), demoShape == nil else { return }
        demoShape = LogShape.estimate(length: 6, smallDiameter: 0.30, largeDiameter: 0.38, sweep: 0.03)
        compute()
    }
}

struct PlanDetail: View {
    let plan: CutPlan
    let comparedTo: CutPlan?
    var juvenileRadius: Double?
    let open3D: () -> Void

    var body: some View {
        Section("Résultat") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Fmt.num(plan.yield * 100)) %")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("de rendement").foregroundStyle(.secondary)
            }
            LabeledContent("Bois scié", value: "\(Fmt.num(plan.piecesVolume, 3)) m³ sur \(Fmt.num(plan.logVolume, 3)) m³")
            if let other = comparedTo {
                let gain = (plan.yield - other.yield) * 100
                Text("Soit \(Fmt.num(gain, 1)) points de plus que « \(other.title) ».")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            Button {
                open3D()
            } label: {
                Label("Voir la grume en 3D", systemImage: "cube.transparent")
            }
        }

        ForEach(Array(plan.segments.enumerated()), id: \.element.id) { index, seg in
            Section(plan.segments.count > 1
                    ? "Tronçon \(index + 1) : \(Fmt.num(seg.z0, 2)) → \(Fmt.num(seg.z1, 2)) m"
                    : seg.pattern) {
                if plan.segments.count > 1 {
                    Text(seg.pattern).font(.subheadline).foregroundStyle(.secondary)
                }
                CrossSectionView(plan: seg, juvenileRadius: juvenileRadius)
                    .frame(height: 260)
                Text(seg.pithSmall == nil
                     ? "Vue depuis le petit bout. En clair : la partie sciable sur toute la longueur du tronçon. Cercles : petit et gros bout."
                     : "Vue depuis le petit bout. En clair : la partie sciable sur toute la longueur. Point rouge plein : cœur au petit bout ; rond rouge : cœur au gros bout ; pointillés rouges : bois juvénile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(summary(seg), id: \.self) { line in
                    Text(line).monospacedDigit()
                }
                LabeledContent("Rendement du tronçon", value: "\(Fmt.num(seg.logVolume > 0 ? seg.piecesVolume / seg.logVolume * 100 : 0)) %")
            }
        }
    }

    private func cm(_ m: Double) -> String {
        let v = (m * 1000).rounded() / 10
        return v == v.rounded() ? Fmt.num(v) : Fmt.num(v, 1)
    }

    private func summary(_ seg: SegmentPlan) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for p in seg.pieces {
            let a = min(p.width, p.height), b = max(p.width, p.height)
            let base = p.kind == .beam
                ? "poutre \(cm(a)) × \(cm(b)) cm"
                : "planche \(Fmt.num((a * 1000).rounded())) mm × \(cm(b)) cm"
            let key = p.containsPith ? base + " (avec cœur)" : base
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let len = Fmt.num(seg.length, 2)
        return order.map { "\(counts[$0]!) × \($0), \(len) m" }
    }
}

struct CrossSectionView: View {
    let plan: SegmentPlan
    var juvenileRadius: Double?

    var body: some View {
        Canvas { ctx, size in
            let disks = plan.disks
            guard let small = disks.first, let large = disks.last else { return }
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            for d in [small, large] {
                minX = min(minX, d.x - d.r); maxX = max(maxX, d.x + d.r)
                minY = min(minY, d.y - d.r); maxY = max(maxY, d.y + d.r)
            }
            let pad = 0.01
            let scale = min(size.width / (maxX - minX + 2 * pad), size.height / (maxY - minY + 2 * pad))
            let ox = size.width / 2 - (minX + maxX) / 2 * scale
            let oy = size.height / 2 + (minY + maxY) / 2 * scale
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * scale, y: oy - y * scale) }
            func circle(_ d: Disk) -> Path {
                Path(ellipseIn: CGRect(x: ox + (d.x - d.r) * scale, y: oy - (d.y + d.r) * scale,
                                       width: 2 * d.r * scale, height: 2 * d.r * scale))
            }

            ctx.fill(circle(large), with: .color(Color(red: 0.55, green: 0.40, blue: 0.28).opacity(0.25)))
            ctx.stroke(circle(large), with: .color(Color(red: 0.45, green: 0.32, blue: 0.22)), lineWidth: 1)
            ctx.stroke(circle(small), with: .color(Color(red: 0.45, green: 0.32, blue: 0.22)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            let outline = Region.boundary(disks, cx: plan.centerX, cy: plan.centerY)
            var region = Path()
            if let first = outline.first {
                region.move(to: pt(first.x, first.y))
                for p in outline.dropFirst() { region.addLine(to: pt(p.x, p.y)) }
                region.closeSubpath()
            }
            ctx.fill(region, with: .color(Color(red: 0.93, green: 0.82, blue: 0.64)))

            for p in plan.pieces {
                let rect = CGRect(x: ox + p.x0 * scale, y: oy - p.y1 * scale, width: p.width * scale, height: p.height * scale)
                let fill = p.kind == .beam ? Color.orange : Color(red: 0.98, green: 0.93, blue: 0.82)
                ctx.fill(Path(rect), with: .color(fill))
                ctx.stroke(Path(rect), with: .color(.black.opacity(0.65)), lineWidth: 0.8)
                if p.kind == .beam {
                    let label = "\(Fmt.num(p.width * 100, 1))×\(Fmt.num(p.height * 100, 1))"
                    ctx.draw(Text(label).font(.caption.bold()).foregroundColor(.black),
                             at: CGPoint(x: rect.midX, y: rect.midY + 12))
                }
            }

            if let ps = plan.pithSmall {
                let c = pt(ps.x, ps.y)
                if let jr = juvenileRadius {
                    let r = jr * scale
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.red), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.red))
            }
            if let pl = plan.pithLarge {
                let c = pt(pl.x, pl.y)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                           with: .color(.red), lineWidth: 1.5)
            }
        }
    }
}

// MARK: 3D

struct Log3DView: View {
    @State private var scene: SCNScene
    @State private var camera: SCNNode

    init(shape: LogShape, plan: CutPlan?) {
        let built = LogScene.make(shape: shape, plan: plan)
        _scene = State(initialValue: built.scene)
        _camera = State(initialValue: built.camera)
    }

    var body: some View {
        SceneView(scene: scene, pointOfView: camera, options: [.allowsCameraControl, .autoenablesDefaultLighting])
    }
}

enum LogScene {
    static func make(shape: LogShape, plan: CutPlan?) -> (scene: SCNScene, camera: SCNNode) {
        let scene = SCNScene()
        scene.background.contents = UIColor.systemGroupedBackground
        let zs = shape.slices.map(\.z)
        let zMid = ((zs.min() ?? 0) + (zs.max() ?? 0)) / 2

        let log = SCNNode(geometry: logGeometry(shape, zMid: zMid, segments: shape.colorAngles ?? 40))
        let wood = SCNMaterial()
        wood.diffuse.contents = shape.colors == nil ? UIColor(red: 0.62, green: 0.45, blue: 0.30, alpha: 1) : UIColor.white
        wood.transparency = plan == nil ? 1 : 0.28
        wood.isDoubleSided = true
        wood.writesToDepthBuffer = plan == nil
        log.geometry?.materials = [wood]
        log.renderingOrder = 10
        scene.rootNode.addChildNode(log)

        if let plan {
            for seg in plan.segments {
                let c = cos(seg.angle), s = sin(seg.angle)
                for p in seg.pieces {
                    let box = SCNBox(width: CGFloat(p.width), height: CGFloat(p.height),
                                     length: CGFloat(max(0.01, seg.length - 0.006)), chamferRadius: 0)
                    let m = SCNMaterial()
                    m.diffuse.contents = p.kind == .beam
                        ? UIColor.systemOrange
                        : UIColor(red: 0.95, green: 0.88, blue: 0.72, alpha: 1)
                    box.materials = [m]
                    let node = SCNNode(geometry: box)
                    let px = (p.x0 + p.x1) / 2, py = (p.y0 + p.y1) / 2
                    node.position = SCNVector3(Float(px * c - py * s), Float(px * s + py * c),
                                               Float((seg.z0 + seg.z1) / 2 - zMid))
                    node.eulerAngles.z = Float(seg.angle)
                    scene.rootNode.addChildNode(node)
                }
            }
        }

        // Three-quarter view from the small end: the cut pattern shows on the end face
        // and the length recedes in perspective. Drag to turn, pinch to zoom.
        let sorted = shape.slices.sorted { $0.z < $1.z }
        let smallAtStart = (sorted.first?.r ?? 0) <= (sorted.last?.r ?? 0)
        let endZ = Float(smallAtStart ? (sorted.first?.z ?? 0) - zMid : (sorted.last?.z ?? 0) - zMid)
        let dir: Float = smallAtStart ? 1 : -1
        let R = Float(max(sorted.first?.r ?? 0.15, sorted.last?.r ?? 0.15))
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 100
        cameraNode.camera?.fieldOfView = 55
        cameraNode.position = SCNVector3(R * 3.2, R * 2.4, endZ - dir * R * 5.5)
        cameraNode.look(at: SCNVector3(0, 0, endZ + dir * R * 4))
        scene.rootNode.addChildNode(cameraNode)
        return (scene, cameraNode)
    }

    static func logGeometry(_ shape: LogShape, zMid: Double, segments: Int = 40) -> SCNGeometry {
        let slices = shape.slices.sorted { $0.z < $1.z }
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        for sl in slices {
            for j in 0..<segments {
                let a = 2 * Double.pi * Double(j) / Double(segments)
                vertices.append(SCNVector3(Float(sl.cx + sl.r * cos(a)), Float(sl.cy + sl.r * sin(a)), Float(sl.z - zMid)))
                normals.append(SCNVector3(Float(cos(a)), Float(sin(a)), 0))
            }
        }
        if slices.count >= 2 {
            for i in 0..<(slices.count - 1) {
                for j in 0..<segments {
                    let a = Int32(i * segments + j)
                    let b = Int32(i * segments + (j + 1) % segments)
                    let c = a + Int32(segments)
                    let d = b + Int32(segments)
                    indices += [a, b, c, b, d, c]
                }
            }
        }
        var sources = [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)]
        if let colors = shape.colors, shape.colorAngles == segments, colors.count == slices.count * segments {
            // Colours were stored in the order of shape.slices, which is already sorted by z.
            var rgb: [Float] = []
            rgb.reserveCapacity(colors.count * 3)
            for c in colors {
                rgb.append(Float((c >> 16) & 0xFF) / 255)
                rgb.append(Float((c >> 8) & 0xFF) / 255)
                rgb.append(Float(c & 0xFF) / 255)
            }
            let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: colors.count,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                             dataStride: MemoryLayout<Float>.size * 3))
        }
        let geometry = SCNGeometry(sources: sources,
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        return geometry
    }
}
