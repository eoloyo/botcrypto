import SwiftUI

struct LogsView: View {
    @EnvironmentObject var store: LogStore
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.logs) { log in
                    NavigationLink(value: log.id) {
                        LogRow(log: log)
                    }
                }
                .onDelete { offsets in
                    store.logs.remove(atOffsets: offsets)
                    if store.selectedIndex == nil { store.selectedID = store.logs.first?.id }
                }
            }
            .navigationTitle("Grumes")
            .navigationDestination(for: UUID.self) { id in
                if let i = store.logs.firstIndex(where: { $0.id == id }) {
                    LogDetailView(log: $store.logs[i])
                } else {
                    Text("Cette grume a été supprimée.")
                }
            }
            .toolbar {
                Button {
                    store.selectedID = store.addLog()
                } label: {
                    Image(systemName: "plus")
                }
            }
            .onAppear {
                // Launch argument "-openLog YES": open the first log (simulator screenshots).
                if path.isEmpty, UserDefaults.standard.bool(forKey: "openLog"), let first = store.logs.first {
                    path = [first.id]
                }
            }
        }
    }
}

struct LogRow: View {
    let log: WoodLog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(log.name).font(.headline)
            Text(dimensions).font(.subheadline).foregroundStyle(.secondary)
            if let r = log.latest {
                Text("\(Fmt.num(r.frequency, 1)) Hz · \(Fmt.num(r.speed)) m/s · \(Fmt.num(log.modulusGPa(speed: r.speed), 1)) GPa")
                    .font(.subheadline)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var dimensions: String {
        var parts: [String] = []
        if !log.species.isEmpty { parts.append(log.species) }
        if let L = log.lengthM { parts.append("\(Fmt.num(L, 2)) m") }
        let ds = [log.smallEndCm, log.largeEndCm].compactMap { $0 }.map { Fmt.num($0, 1) }
        if !ds.isEmpty { parts.append("Ø " + ds.joined(separator: " / ") + " cm") }
        return parts.isEmpty ? "Dimensions à saisir" : parts.joined(separator: " · ")
    }
}

struct LogDetailView: View {
    @Binding var log: WoodLog
    @State private var endSheet: LogEnd?
    @State private var demoEnd = false
    @State private var show3D = false

    var body: some View {
        Form {
            Section("Grume") {
                TextField("Nom", text: $log.name)
                TextField("Essence", text: $log.species)
            }

            Section("Dimensions") {
                NumberField(title: "Longueur", unit: "m", value: $log.lengthM)
                NumberField(title: "Ø petit bout", unit: "cm", value: $log.smallEndCm)
                NumberField(title: "Ø gros bout", unit: "cm", value: $log.largeEndCm)
                NumberField(title: "Courbure (flèche)", unit: "cm", value: $log.sweepCm)
                NumberField(title: "Masse", unit: "kg", value: $log.massKg)
                if let sh = log.shape {
                    LabeledContent("Forme 3D", value: "scannée, \(sh.slices.count) coupes")
                    Button("Supprimer la forme scannée", role: .destructive) { log.shape = nil }
                }
            }

            Section("Calculs") {
                if let v = log.volumeM3 {
                    LabeledContent("Volume", value: "\(Fmt.num(v, 3)) m³")
                }
                if let d = log.measuredDensity {
                    LabeledContent("Densité", value: "\(Fmt.num(d)) kg/m³")
                } else if let v = log.volumeM3 {
                    LabeledContent("Masse estimée", value: "≈ \(Fmt.num(v * WoodLog.assumedGreenDensity)) kg")
                }
                if let s = log.meanSpeed {
                    LabeledContent("Vitesse moyenne", value: "\(Fmt.num(s)) m/s")
                    LabeledContent("Rigidité dynamique", value: "\(Fmt.num(log.modulusGPa(speed: s), 1)) GPa")
                    if log.densityForCalc.assumed {
                        Text("Calculée avec une densité supposée de 850 kg/m³. Entrez la masse pour un résultat exact.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Faites une mesure dans l'onglet Résonance.")
                        .foregroundStyle(.secondary)
                }
            }

            EndsSection(log: log) { endSheet = $0 }

            if let sh = log.shape {
                Section {
                    Button {
                        show3D = true
                    } label: {
                        Label("Voir la grume scannée en 3D", systemImage: "cube.transparent")
                    }
                    .sheet(isPresented: $show3D) {
                        NavigationStack {
                            Log3DView(shape: sh, plan: nil)
                                .ignoresSafeArea(edges: .bottom)
                                .navigationTitle(log.name)
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar { Button("Fermer") { show3D = false } }
                        }
                    }
                }
            }

            Section("Mesures de résonance") {
                if log.measurements.isEmpty {
                    Text("Aucune mesure pour l'instant.").foregroundStyle(.secondary)
                }
                ForEach(log.measurements) { m in
                    MeasurementRow(m: m)
                }
                .onDelete { log.measurements.remove(atOffsets: $0) }
            }

            Section("Notes") {
                TextEditor(text: $log.notes)
                    .frame(minHeight: 100)
            }
        }
        .navigationTitle(log.name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .fullScreenCover(item: $endSheet) { end in
            EndFaceView(log: $log, end: end, demo: demoEnd)
        }
        .onAppear {
            // Launch argument "-demoEnd YES": analyse a synthetic end photo (simulator screenshots).
            if UserDefaults.standard.bool(forKey: "demoEnd"), !demoEnd {
                demoEnd = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { endSheet = .small }
            }
        }
    }
}

/// Pith and rings at both ends, and how they compare.
struct EndsSection: View {
    let log: WoodLog
    let open: (LogEnd) -> Void

    var body: some View {
        Section("Cœur et cernes (photos des bouts)") {
            endRow(.small, log.smallEnd)
            endRow(.large, log.largeEnd)
            if let s = log.smallEnd, let l = log.largeEnd {
                let diff = l.ringCount - s.ringCount
                LabeledContent("Écart de cernes", value: "\(Int(diff.rounded())) cernes")
                if diff > 0 {
                    Text("Le gros bout a environ \(Int(diff.rounded())) cernes de plus : l'arbre a mis à peu près autant d'années pour pousser de la hauteur du gros bout à celle du petit bout.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Largeur des cernes", value: "\(Fmt.num(s.meanRingWidthMm, 1)) / \(Fmt.num(l.meanRingWidthMm, 1)) mm")
                if let L = log.lengthM, L > 0 {
                    let taper = (l.diameterMm - s.diameterMm) / 10 / L
                    LabeledContent("Conicité de la grume", value: "\(Fmt.num(taper, 1)) cm/m")
                }
                LabeledContent("Cœur décalé (petit / gros)", value: "\(Fmt.num(s.eccentricity * 100)) / \(Fmt.num(l.eccentricity * 100)) % du rayon")
                if let js = s.juvenileDiameterMm, let jl = l.juvenileDiameterMm {
                    LabeledContent("Bois juvénile", value: "Ø \(Fmt.num(js / 10, 1)) / \(Fmt.num(jl / 10, 1)) cm")
                }
                if let hs = s.heartwoodDiameterMm, let hl = l.heartwoodDiameterMm {
                    LabeledContent("Duramen", value: "Ø \(Fmt.num(hs / 10, 1)) / \(Fmt.num(hl / 10, 1)) cm")
                }
                Text("La position du cœur aux deux bouts est reportée sur le plan de coupe (onglet Débit).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Photographiez les deux bouts pour comparer les cernes et suivre le cœur sur la longueur.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func endRow(_ end: LogEnd, _ r: EndFaceResult?) -> some View {
        Button {
            open(end)
        } label: {
            HStack {
                Image(systemName: r == nil ? "camera" : "checkmark.circle.fill")
                    .foregroundStyle(r == nil ? Color.accentColor : Color.green)
                Text(end.title)
                Spacer()
                if let r {
                    Text("≈ \(Int(r.ringCount.rounded())) cernes · cœur \(Fmt.num(r.eccentricity * 100)) %")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Photo à prendre").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MeasurementRow: View {
    let m: ResonanceResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(m.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(Fmt.num(m.frequency, 1)) Hz · \(Fmt.num(m.speed)) m/s")
                .monospacedDigit()
            if let z = m.dampingRatio {
                Text("Amortissement \(Fmt.num(z * 100, 2)) %" + (m.decay30ms.map { " · −30 dB en \(Fmt.num($0)) ms" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Text field for an optional number, accepting a comma or a dot.
struct NumberField: View {
    let title: String
    let unit: String
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("—", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .onChange(of: text) { _, newValue in
                    let cleaned = newValue.replacingOccurrences(of: ",", with: ".")
                    value = cleaned.isEmpty ? nil : Double(cleaned)
                }
            Text(unit).foregroundStyle(.secondary)
        }
        .onAppear {
            if let v = value { text = Fmt.num(v, unit == "m" ? 2 : 1).replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: "\u{00A0}", with: "") }
        }
    }
}
