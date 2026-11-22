import SwiftUI

struct LiDARView: View {
    @EnvironmentObject var store: LogStore
    @StateObject private var model = ARMeasureModel()
    @State private var target: Target = .length
    @State private var savedMessage: String?

    enum Target: String, CaseIterable, Identifiable {
        case length = "Longueur"
        case small = "Ø petit bout"
        case large = "Ø gros bout"
        var id: String { rawValue }

        var hint: String {
            switch self {
            case .length:
                return "Visez le centre d'un bout et touchez « Point ». Marchez jusqu'à l'autre bout en gardant la grume dans l'image, visez son centre et touchez « Point »."
            case .small, .large:
                return "Visez le bord de la coupe, juste sous l'écorce, et touchez « Point ». Puis visez le bord opposé, en passant par le cœur."
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
            Text(target.hint).font(.footnote)
            Text(model.status).font(.footnote).foregroundStyle(.secondary)
            if !model.hasLiDAR {
                Text("Pas de LiDAR sur ce téléphone : les mesures seront moins précises.")
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
            distanceText

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
                    model.addPoint()
                } label: {
                    Label("Point", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.clear()
                } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.points.isEmpty)
            }

            if let d = model.distance {
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

    private func format(_ meters: Float) -> String {
        let m = Double(meters)
        switch target {
        case .length: return "\(Fmt.num(m, 2)) m"
        case .small, .large: return "\(Fmt.num(m * 100, 1)) cm"
        }
    }

    private func save(_ meters: Float) {
        guard let id = store.selectedID else { return }
        let m = Double(meters)
        switch target {
        case .length: store.update(id) { $0.lengthM = (m * 100).rounded() / 100 }
        case .small: store.update(id) { $0.smallEndCm = (m * 1000).rounded() / 10 }
        case .large: store.update(id) { $0.largeEndCm = (m * 1000).rounded() / 10 }
        }
        savedMessage = "\(target.rawValue) enregistré(e) pour « \(store.selected?.name ?? "") »."
        model.clear()
    }
}
