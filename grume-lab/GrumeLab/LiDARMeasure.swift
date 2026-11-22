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

    let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    private weak var arView: ARView?
    private var anchors: [AnchorEntity] = []
    private var updateSubscription: Cancellable?
    private var frameCount = 0
    private var running = false

    var distance: Float? {
        points.count == 2 ? simd_distance(points[0], points[1]) : nil
    }

    func attach(_ view: ARView) {
        arView = view
        view.session.delegate = self
        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.tick()
        }
        resume()
    }

    func resume() {
        guard let view = arView, !running else { return }
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
