import SwiftUI
import ARKit
import RealityKit
import Combine

/// Point-to-point measuring with ARKit. With LiDAR, raycasts hit any surface accurately.
final class ARMeasureModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var points: [SIMD3<Float>] = []
    @Published private(set) var liveDistance: Float?
    @Published private(set) var status = "Bougez lentement le téléphone pour démarrer."
    @Published var showMesh = false {
        didSet { applyDebugOptions() }
    }
    /// Mesh points found around the log (scan mode, once both ends are marked).
    @Published private(set) var meshPointCount = 0
    var scanMode = false {
        didSet {
            if scanMode && hasLiDAR { showMesh = true }
            meshPointCount = 0
        }
    }

    let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    private weak var arView: ARView?
    private var anchors: [AnchorEntity] = []
    private var updateSubscription: Cancellable?
    private var frameCount = 0
    private var running = false
    private var colorSamples: [(p: SIMD3<Float>, rgb: UInt32)] = []

    var distance: Float? {
        points.count == 2 ? simd_distance(points[0], points[1]) : nil
    }

    func attach(_ view: ARView) {
        arView = view
        view.session.delegate = self
        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.tick()
        }
        // attach() runs inside SwiftUI's view update: publish state on the next turn.
        DispatchQueue.main.async { [weak self] in self?.resume() }
    }

    func resume() {
        guard let view = arView, !running else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            status = "La réalité augmentée n'est pas disponible sur cet appareil (simulateur ?)."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if hasLiDAR { config.sceneReconstruction = .mesh }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        view.session.run(config)
        running = true
        applyDebugOptions()
    }

    func pause() {
        arView?.session.pause()
        running = false
    }

    private func applyDebugOptions() {
        guard let view = arView else { return }
        if showMesh {
            view.debugOptions.insert(.showSceneUnderstanding)
        } else {
            view.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    private func centerHit() -> SIMD3<Float>? {
        guard let view = arView, view.bounds.width > 0 else { return nil }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let hit = view.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first else {
            return nil
        }
        let t = hit.worldTransform.columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    private func tick() {
        frameCount += 1
        if scanMode, points.count == 2, frameCount % 45 == 0 {
            meshPointCount = nearbyMeshPoints().count
        }
        if scanMode, points.count == 2, frameCount % 20 == 10 {
            sampleColors()
        }
        guard frameCount % 5 == 0 else { return }
        if points.count == 1, let p = centerHit() {
            liveDistance = simd_distance(points[0], p)
        } else if points.count != 1, liveDistance != nil {
            liveDistance = nil
        }
    }

    func addPoint() {
        guard let p = centerHit() else {
            status = "Aucune surface visée. Rapprochez-vous (moins de 4 m) et visez le bois."
            return
        }
        if points.count >= 2 { clear() }
        points.append(p)
        addMarker(at: p)
        if points.count == 2 {
            addLine(points[0], points[1])
            liveDistance = nil
        }
    }

    func undo() {
        guard !points.isEmpty else { return }
        points.removeLast()
        rebuild()
    }

    func clear() {
        colorSamples.removeAll()
        points.removeAll()
        liveDistance = nil
        rebuild()
    }

    private func rebuild() {
        anchors.forEach { $0.removeFromParent() }
        anchors.removeAll()
        for p in points { addMarker(at: p) }
        if points.count == 2 { addLine(points[0], points[1]) }
    }

    private func addMarker(at p: SIMD3<Float>) {
        guard let view = arView else { return }
        let anchor = AnchorEntity(world: p)
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.008),
                                 materials: [SimpleMaterial(color: .systemOrange, isMetallic: false)])
        anchor.addChild(sphere)
        view.scene.addAnchor(anchor)
        anchors.append(anchor)
    }

    private func addLine(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
        guard let view = arView else { return }
        let d = simd_distance(a, b)
        guard d > 0.001 else { return }
        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        let bar = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.003, 0.003, d)),
                              materials: [SimpleMaterial(color: .white, isMetallic: false)])
        bar.look(at: b, from: (a + b) / 2, relativeTo: nil)
        anchor.addChild(bar)
        view.scene.addAnchor(anchor)
        anchors.append(anchor)
    }

    // MARK: 3D scan

    /// LiDAR mesh vertices within `maxDistance` of the segment joining the two marked ends.
    func nearbyMeshPoints(maxDistance: Float = 0.8) -> [SIMD3<Float>] {
        guard points.count == 2, let frame = arView?.session.currentFrame else { return [] }
        let a = points[0], b = points[1]
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 0.01 else { return [] }
        var out: [SIMD3<Float>] = []
        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let source = mesh.geometry.vertices
            let base = source.buffer.contents()
            let transform = mesh.transform
            for i in 0..<source.count {
                let ptr = base.advanced(by: source.offset + source.stride * i).assumingMemoryBound(to: Float.self)
                let w = transform * SIMD4<Float>(ptr[0], ptr[1], ptr[2], 1)
                let p = SIMD3<Float>(w.x, w.y, w.z)
                let t = simd_dot(p - a, ab) / len2
                guard t > -0.05, t < 1.05 else { continue }
                if simd_distance(p, a + t * ab) < maxDistance { out.append(p) }
            }
        }
        return out
    }

    /// Fits the log shape from the mesh. Calls back on the main thread.
    func computeShape(expectedRadius: Double?, completion: @escaping (LogShape?) -> Void) {
        guard points.count == 2 else { completion(nil); return }
        let cloud = nearbyMeshPoints()
        let a = points[0], b = points[1]
        let colors = colorSamples
        DispatchQueue.global(qos: .userInitiated).async {
            let shape = LogShapeFitter.fit(points: cloud, endA: a, endB: b, expectedRadius: expectedRadius,
                                           colorSamples: colors)
            DispatchQueue.main.async { completion(shape) }
        }
    }

    /// Colours the mesh points seen by the camera ("photogrammétrie" light): each point
    /// facing the camera takes the colour of the pixel it projects to.
    private func sampleColors() {
        guard points.count == 2, let frame = arView?.session.currentFrame else { return }
        let cloud = nearbyMeshPoints(maxDistance: 0.6)
        guard !cloud.isEmpty else { return }
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let camera = frame.camera
        let viewport = CGSize(width: width, height: height)
        let toCamera = camera.transform.inverse
        let eye = SIMD3<Float>(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        let a = points[0], ab = points[1] - points[0]
        let len2 = simd_length_squared(ab)
        let step = max(1, cloud.count / 4000)
        var i = 0
        while i < cloud.count {
            let p = cloud[i]
            i += step
            let c = toCamera * SIMD4<Float>(p.x, p.y, p.z, 1)
            guard c.z < -0.1, c.z > -4 else { continue }
            // Keep points on the side of the log facing the camera.
            let t = simd_dot(p - a, ab) / len2
            let normal = p - (a + t * ab)
            guard simd_dot(normal, eye - p) > 0 else { continue }
            let s = camera.projectPoint(p, orientation: .landscapeRight, viewportSize: viewport)
            let x = Int(s.x), y = Int(s.y)
            guard x >= 0, y >= 0, x < width, y < height else { continue }
            let Y = Float(yBase[y * yStride + x])
            let ci = (y / 2) * cStride + (x / 2) * 2
            let cb = Float(cBase[ci]) - 128, cr = Float(cBase[ci + 1]) - 128
            let r = UInt32(max(0, min(255, Y + 1.402 * cr)))
            let g = UInt32(max(0, min(255, Y - 0.344 * cb - 0.714 * cr)))
            let b = UInt32(max(0, min(255, Y + 1.772 * cb)))
            colorSamples.append((p, (r << 16) | (g << 8) | b))
        }
        if colorSamples.count > 150_000 {
            colorSamples.removeFirst(colorSamples.count - 150_000)
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            status = hasLiDAR
                ? "Prêt. Visez avec la croix, puis touchez « Point »."
                : "Prêt, mais sans LiDAR : la précision est réduite."
        case .notAvailable:
            status = "Suivi indisponible."
        case .limited(let reason):
            switch reason {
            case .initializing: status = "Initialisation… bougez lentement le téléphone."
            case .excessiveMotion: status = "Bougez moins vite."
            case .insufficientFeatures: status = "Pas assez de détails : éclairez ou rapprochez-vous."
            case .relocalizing: status = "Relocalisation…"
            @unknown default: status = "Suivi limité."
            }
        }
    }
}

struct ARMeasureContainer: UIViewRepresentable {
    let model: ARMeasureModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        model.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}
