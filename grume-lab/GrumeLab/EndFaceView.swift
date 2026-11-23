import SwiftUI
import PhotosUI

enum LogEnd: String, Identifiable {
    case small, large
    var id: String { rawValue }
    var title: String { self == .small ? "Petit bout" : "Gros bout" }
}

/// Photo of one end: place the circle on the edge, find the pith, count the rings.
struct EndFaceView: View {
    @Binding var log: WoodLog
    let end: LogEnd
    var demo = false

    @Environment(\.dismiss) private var dismiss
    @State private var pixels: PixelImage?
    @State private var circleX = 0.0
    @State private var circleY = 0.0
    @State private var circleR = 0.0
    @State private var pithX = 0.0
    @State private var pithY = 0.0
    @State private var analysis: RingAnalysis?
    @State private var diameterText = ""
    @State private var working = false
    @State private var message: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false

    private var diameterMm: Double? {
        guard let v = Double(diameterText.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return v * 10
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let px = pixels {
                        editor(px)
                        controls
                        if let a = analysis { results(a.result) }
                    } else {
                        intro
                    }
                    if let m = message {
                        Text(m).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle(end.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }.disabled(analysis == nil)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in load(image) }
                    .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await MainActor.run { load(image) }
                    }
                }
            }
            .onAppear(perform: start)
        }
    }

    // MARK: sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pour une bonne photo").font(.headline)
            Text("1. Recoupez une fine tranche à la tronçonneuse et mouillez la surface : les cernes ressortent.")
            Text("2. Photographiez bien de face, téléphone droit, la coupe remplissant presque tout l'écran.")
            Text("3. Évitez le soleil direct et les ombres fortes sur la coupe.")
            HStack {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Prendre une photo", systemImage: "camera.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choisir une photo", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .font(.subheadline)
    }

    private func editor(_ px: PixelImage) -> some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / CGFloat(px.width), geo.size.height / CGFloat(px.height))
            let w = CGFloat(px.width) * scale, h = CGFloat(px.height) * scale
            let ox = (geo.size.width - w) / 2, oy = (geo.size.height - h) / 2
            let toView = { (x: Double, y: Double) in CGPoint(x: ox + CGFloat(x) * scale, y: oy + CGFloat(y) * scale) }
            let toImage = { (p: CGPoint) in (Double((p.x - ox) / scale), Double((p.y - oy) / scale)) }

            ZStack(alignment: .topLeading) {
                Image(uiImage: px.uiImage)
                    .resizable()
                    .frame(width: w, height: h)
                    .offset(x: ox, y: oy)

                Canvas { ctx, _ in
                    let c = toView(circleX, circleY)
                    let rr = CGFloat(circleR) * scale
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                               with: .color(.cyan), lineWidth: 2)
                    if let a = analysis {
                        for p in a.boundaryPoints {
                            let v = toView(Double(p.x), Double(p.y))
                            ctx.fill(Path(ellipseIn: CGRect(x: v.x - 1.2, y: v.y - 1.2, width: 2.4, height: 2.4)),
                                     with: .color(.blue))
                        }
                        if let j = a.result.juvenileDiameterMm {
                            let jr = CGFloat(j / 2 / a.result.mmPerPixel) * scale
                            let p = toView(pithX, pithY)
                            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - jr, y: p.y - jr, width: 2 * jr, height: 2 * jr)),
                                       with: .color(.red), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        }
                    }
                }
                .allowsHitTesting(false)

                // Centre of the circle
                handle(color: .cyan, symbol: "arrow.up.and.down.and.arrow.left.and.right")
                    .position(toView(circleX, circleY))
                    .gesture(DragGesture().onChanged { g in
                        let p = toImage(g.location)
                        circleX = p.0; circleY = p.1
                        analysis = nil
                    })
                // Radius
                handle(color: .cyan, symbol: "arrow.left.and.right")
                    .position(toView(circleX + circleR, circleY))
                    .gesture(DragGesture().onChanged { g in
                        let p = toImage(g.location)
                        circleR = max(20, hypot(p.0 - circleX, p.1 - circleY))
                        analysis = nil
                    })
                // Pith
                Circle()
                    .fill(Color.red)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .position(toView(pithX, pithY))
                    .gesture(DragGesture().onChanged { g in
                        let p = toImage(g.location)
                        pithX = p.0; pithY = p.1
                        analysis = nil
                    })
            }
        }
        .frame(height: 380)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func handle(color: Color, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 28, height: 28)
            .background(color, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Placez le cercle bleu sur le bord du bois, juste sous l'écorce, et le point rouge sur le cœur. Vous pouvez les déplacer du doigt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Text("Ø de cette coupe sous écorce")
                Spacer()
                TextField("cm", text: $diameterText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                Text("cm").foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    autoPith()
                } label: {
                    Label("Trouver le cœur", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    runAnalysis()
                } label: {
                    HStack {
                        if working { ProgressView().padding(.trailing, 2) }
                        Text("Analyser les cernes")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || diameterMm == nil)
            }
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Autre photo", systemImage: "photo")
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Spacer()
                    Button { showCamera = true } label: { Label("Reprendre", systemImage: "camera") }
                }
            }
            .font(.footnote)
        }
    }

    private func results(_ r: EndFaceResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Résultat").font(.headline)
            row("Cernes", "≈ \(Int(r.ringCount.rounded()))  (\(Int(r.ringCountLow.rounded()))–\(Int(r.ringCountHigh.rounded())))")
            row("Largeur moyenne", "\(Fmt.num(r.meanRingWidthMm, 1)) mm")
            row("Près du cœur / milieu / sous l'écorce", "\(Fmt.num(r.innerWidthMm, 1)) / \(Fmt.num(r.middleWidthMm, 1)) / \(Fmt.num(r.outerWidthMm, 1)) mm")
            let off = r.pithOffsetMm
            row("Cœur décalé", "\(Fmt.num(hypot(off.x, off.y) / 10, 1)) cm (\(Fmt.num(r.eccentricity * 100)) % du rayon)")
            if let j = r.juvenileDiameterMm { row("Bois juvénile (12 premiers cernes)", "Ø \(Fmt.num(j / 10, 1)) cm") }
            if let h = r.heartwoodDiameterMm { row("Duramen (bois de cœur coloré)", "Ø \(Fmt.num(h / 10, 1)) cm") }
            Text(EndFaceText.advice(r))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Points bleus : limites de cernes trouvées. Pointillés rouges : zone de bois juvénile. Le comptage est une estimation (environ ± 5 %) : vérifiez à la loupe sur un rayon si besoin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k)
            Spacer()
            Text(v).monospacedDigit().bold().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    // MARK: actions

    private func start() {
        if diameterText.isEmpty {
            let d = end == .small ? log.smallEndCm : log.largeEndCm
            if let d { diameterText = Fmt.num(d, 1) }
        }
        let existing = end == .small ? log.smallEnd : log.largeEnd
        if demo, pixels == nil {
            if diameterText.isEmpty { diameterText = "35" }
            load(EndFaceAnalyzer.demoImage(), analyseAfter: true)
        } else if pixels == nil, let e = existing, let file = e.imageFile, let image = EndFaceStorage.load(file) {
            load(image, restoring: e)
        }
    }

    private func load(_ image: UIImage, restoring: EndFaceResult? = nil, analyseAfter: Bool = false) {
        working = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let px = PixelImage(image)
            DispatchQueue.main.async {
                working = false
                guard let px else { message = "Image illisible."; return }
                pixels = px
                analysis = nil
                if let e = restoring, abs(e.imageWidth - Double(px.width)) < 2 {
                    circleX = e.circleX; circleY = e.circleY; circleR = e.circleR
                    pithX = e.pithX; pithY = e.pithY
                    runAnalysis()
                } else {
                    circleX = Double(px.width) / 2
                    circleY = Double(px.height) / 2
                    circleR = 0.42 * Double(min(px.width, px.height))
                    pithX = circleX; pithY = circleY
                    autoPith(thenAnalyse: analyseAfter)
                }
            }
        }
    }

    private func autoPith(thenAnalyse: Bool = false) {
        guard let px = pixels else { return }
        working = true
        let cx = circleX, cy = circleY, r = circleR
        DispatchQueue.global(qos: .userInitiated).async {
            let p = EndFaceAnalyzer.findPith(px, cx: cx, cy: cy, r: r)
            DispatchQueue.main.async {
                pithX = p.x; pithY = p.y
                working = false
                analysis = nil
                if thenAnalyse { runAnalysis() }
            }
        }
    }

    private func runAnalysis() {
        guard let px = pixels, let d = diameterMm else { return }
        working = true
        message = nil
        let cx = circleX, cy = circleY, r = circleR, pX = pithX, pY = pithY
        DispatchQueue.global(qos: .userInitiated).async {
            let a = EndFaceAnalyzer.analyze(px, cx: cx, cy: cy, r: r, pithX: pX, pithY: pY, diameterMm: d)
            DispatchQueue.main.async {
                working = false
                analysis = a
                if a == nil { message = "Cernes introuvables. Vérifiez le cercle et le cœur, ou prenez une photo plus nette d'une coupe fraîche et mouillée." }
            }
        }
    }

    private func save() {
        guard var r = analysis?.result, let px = pixels else { return }
        if !demo {
            r.imageFile = EndFaceStorage.save(px.uiImage, name: "\(log.id.uuidString)-\(end.rawValue)")
        }
        if end == .small { log.smallEnd = r } else { log.largeEnd = r }
        if let d = diameterMm {
            if end == .small { log.smallEndCm = d / 10 } else { log.largeEndCm = d / 10 }
        }
        dismiss()
    }
}

enum EndFaceText {
    static func advice(_ r: EndFaceResult) -> String {
        var parts: [String] = []
        if r.eccentricity > 0.15 {
            parts.append("Cœur nettement décentré : probable bois de réaction (bois de compression chez les résineux), qui se déforme au séchage.")
        } else if r.eccentricity > 0.08 {
            parts.append("Cœur un peu décentré.")
        } else {
            parts.append("Cœur bien centré.")
        }
        if r.meanRingWidthMm > 6 {
            parts.append("Cernes larges : croissance rapide, bois souvent moins dense et moins rigide.")
        } else if r.meanRingWidthMm < 3 {
            parts.append("Cernes fins : croissance lente, bois souvent dense et rigide.")
        }
        return parts.joined(separator: " ")
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
