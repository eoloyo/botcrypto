import SwiftUI

struct LiDARView: View {
    @EnvironmentObject var store: LogStore
    @StateObject private var model = ARMeasureModel()
    @State private var target: Target = .length
    @State private var savedMessage: String?
    @State private var scanning = false
    @State private var scannedShape: LogShape?
    @State private var scanError: String?

    enum Target: String, CaseIterable, Identifiable {
        case length = "Longueur"
        case small = "Ø petit"
        case large = "Ø gros"
        case scan = "Scan 3D"
        var id: String { rawValue }
    }

    private var hint: String {
        switch target {
        case .length:
            return "Visez le centre d'un bout et touchez « Point ». Marchez jusqu'à l'autre bout en gardant la grume dans l'image, visez son centre et touchez « Point »."
        case .small, .large:
            return "Visez le bord de la coupe, juste sous l'écorce, et touchez « Point ». Puis visez le bord opposé, en passant par le cœur."
        case .scan:
            switch model.points.count {
            case 0: return "1. Visez le cœur du premier bout et touchez « Point »."
            case 1: return "2. Visez le cœur de l'autre bout et touchez « Point »."
            default: return "3. Tournez lentement autour de la grume, à environ 1 m, en filmant le dessus et les côtés sur toute la longueur. Puis touchez « Calculer la forme »."
            }
        }
    }

    var body: some View {
        ZStack {
            ARMeasureContainer(model: model)
                .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)

            VStack(spacing: 12) {
                topPanel
                Spacer()
                bottomPanel
            }
            .padding()
        }
        .onAppear { model.resume() }
        .onDisappear { model.pause() }
        .onChange(of: target) { _, newValue in
            model.scanMode = newValue == .scan
            model.clear()
            savedMessage = nil
            scannedShape = nil
            scanError = nil
        }
    }

    private var topPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Grume").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                LogPicker().labelsHidden()
            }
            Picker("Mesure", selection: $target) {
                ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(hint).font(.footnote)
            Text(model.status).font(.footnote).foregroundStyle(.secondary)
            if !model.hasLiDAR {
                Text("Pas de LiDAR sur ce téléphone : mesures moins précises, scan 3D impossible.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Toggle("Afficher le maillage LiDAR", isOn: $model.showMesh)
                .font(.footnote)
                .disabled(!model.hasLiDAR)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if target == .scan {
                scanStatus
            } else {
                distanceText
            }

            HStack(spacing: 12) {
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.points.isEmpty)

                Button {
                    savedMessage = nil
                    scannedShape = nil
                    model.addPoint()
                } label: {
                    Label("Point", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.clear()
                    scannedShape = nil
                } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.points.isEmpty)
            }

            if target == .scan {
                scanButtons
            } else if let d = model.distance {
                Button {
                    save(d)
                } label: {
                    Label("Enregistrer : \(target.rawValue)", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(store.selectedID == nil)
            }
            if let m = savedMessage {
                Text(m).font(.footnote).foregroundStyle(.green)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var distanceText: some View {
        if let d = model.distance {
            Text(format(d)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
        } else if let live = model.liveDistance {
            Text(format(live)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text(model.points.isEmpty ? "Premier point" : "Second point")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var scanStatus: some View {
        if let sh = scannedShape {
            VStack(spacing: 4) {
                Text("\(Fmt.num(sh.lengthM, 2)) m · Ø \(Fmt.num(sh.smallEndDiameter * 100, 1)) / \(Fmt.num(sh.largeEndDiameter * 100, 1)) cm")
                    .font(.headline)
                    .monospacedDigit()
                Text("Courbure \(Fmt.num(sh.sweep * 100, 1)) cm · \(Fmt.num(sh.volume, 3)) m³")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if model.points.count == 2 {
            VStack(spacing: 2) {
                Text("\(model.meshPointCount) points sur la grume")
                    .font(.headline)
                    .monospacedDigit()
                Text(model.meshPointCount < 3000 ? "Continuez à tourner autour de la grume." : "Assez de points : vous pouvez calculer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(model.points.isEmpty ? "Cœur du premier bout" : "Cœur du second bout")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        if let e = scanError {
            Text(e).font(.footnote).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var scanButtons: some View {
        if let sh = scannedShape {
            Button {
                saveShape(sh)
            } label: {
                Label("Enregistrer la forme dans la grume", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(store.selectedID == nil)
        } else if model.points.count == 2 {
            Button {
                scanning = true
                scanError = nil
                let expected = store.selected.flatMap { log -> Double? in
                    let ds = [log.smallEndCm, log.largeEndCm].compactMap { $0 }
                    return ds.isEmpty ? nil : ds.reduce(0, +) / Double(ds.count) / 200
                }
                model.computeShape(expectedRadius: expected) { shape in
                    scanning = false
                    if let shape {
                        scannedShape = shape
                    } else {
                        scanError = "Forme introuvable. Scannez plus de surface autour de la grume, ou vérifiez les deux points des bouts."
                    }
                }
            } label: {
                HStack {
                    if scanning { ProgressView().padding(.trailing, 4) }
                    Text(scanning ? "Calcul…" : "Calculer la forme")
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .disabled(scanning || model.meshPointCount < 300)
        }
    }

    private func format(_ meters: Float) -> String {
        let m = Double(meters)
        switch target {
        case .length: return "\(Fmt.num(m, 2)) m"
        case .small, .large, .scan: return "\(Fmt.num(m * 100, 1)) cm"
        }
    }

    private func save(_ meters: Float) {
        guard let id = store.selectedID else { return }
        let m = Double(meters)
        switch target {
        case .length: store.update(id) { $0.lengthM = (m * 100).rounded() / 100 }
        case .small: store.update(id) { $0.smallEndCm = (m * 1000).rounded() / 10 }
        case .large: store.update(id) { $0.largeEndCm = (m * 1000).rounded() / 10 }
        case .scan: return
        }
        savedMessage = "\(target.rawValue) enregistré pour « \(store.selected?.name ?? "") »."
        model.clear()
    }

    private func saveShape(_ shape: LogShape) {
        guard let id = store.selectedID else { return }
        store.update(id) {
            $0.shape = shape
            $0.lengthM = (shape.lengthM * 100).rounded() / 100
            $0.smallEndCm = (shape.smallEndDiameter * 1000).rounded() / 10
            $0.largeEndCm = (shape.largeEndDiameter * 1000).rounded() / 10
            $0.sweepCm = (shape.sweep * 1000).rounded() / 10
        }
        savedMessage = "Forme 3D enregistrée pour « \(store.selected?.name ?? "") ». Ouvrez l'onglet Débit."
        scannedShape = nil
        model.clear()
    }
}
