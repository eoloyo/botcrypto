import SwiftUI
import Charts

struct ResonanceView: View {
    @EnvironmentObject var store: LogStore
    @StateObject private var recorder = ResonanceRecorder()
    @State private var lengthText = ""
    @State private var autoRange = true
    @State private var sensitivity = 1
    @State private var chosenFrequency: Double?
    @State private var chosenDecay: (zeta: Double, t30ms: Double)?
    @State private var savedMessage: String?

    private var length: Double? {
        let v = Double(lengthText.replacingOccurrences(of: ",", with: "."))
        return (v ?? 0) > 0 ? v : nil
    }

    /// Expected fundamental from the length: longitudinal speed 2 000 to 6 500 m/s.
    private var searchRange: ClosedRange<Double> {
        if autoRange, let L = length {
            let lo = max(20, 2000 / (2 * L))
            let hi = min(8000, 6500 / (2 * L))
            if hi > lo { return lo...hi }
        }
        return 20...5000
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section("Grume") {
                    LogPicker()
                    HStack {
                        Text("Longueur")
                        Spacer()
                        TextField("0", text: $lengthText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        Text("m").foregroundStyle(.secondary)
                    }
                    Toggle("Chercher selon la longueur", isOn: $autoRange)
                    Picker("Sensibilité", selection: $sensitivity) {
                        Text("Basse").tag(0)
                        Text("Normale").tag(1)
                        Text("Haute").tag(2)
                    }
                }

                Section { controls }
                    .id("controls")

                if let a = recorder.analysis, recorder.phase == .done {
                    results(a)
                }

                Section("Comment faire") {
                    Text("1. Posez la grume sur deux cales, elle ne doit pas toucher le sol.")
                    Text("2. Tenez le téléphone près d'un bout, micro vers le bois.")
                    Text("3. Touchez « Écouter », puis donnez un coup de marteau sec sur l'autre bout, dans l'axe de la grume.")
                    Text("4. Faites 3 mesures et comparez : elles doivent donner presque la même fréquence.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Résonance")
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                syncLength()
                // Launch argument "-demoResonance YES": analyse a synthetic knock.
                if UserDefaults.standard.bool(forKey: "demoResonance"), recorder.phase == .idle {
                    let L = store.selected?.lengthM ?? 6
                    recorder.runDemo(range: max(20, 2000 / (2 * L))...min(8000, 6500 / (2 * L)))
                }
            }
            .onChange(of: store.selectedID) { _, _ in syncLength() }
            .onChange(of: recorder.phase) { _, phase in
                if phase == .done {
                    withAnimation { proxy.scrollTo("controls", anchor: .top) }
                }
            }
            }
        }
    }

    private func syncLength() {
        if let L = store.selected?.lengthM { lengthText = Fmt.num(L, 2) }
    }

    @ViewBuilder private var controls: some View {
        switch recorder.phase {
        case .idle, .done, .failed:
            Button {
                chosenFrequency = nil
                chosenDecay = nil
                savedMessage = nil
                recorder.minThreshold = [0.12, 0.05, 0.02][sensitivity]
                recorder.start(range: searchRange)
            } label: {
                Label(recorder.phase == .idle ? "Écouter" : "Nouvelle mesure", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            if case .failed(let message) = recorder.phase {
                Text(message).foregroundStyle(.red)
            }
            Text("Fréquence cherchée entre \(Fmt.num(searchRange.lowerBound)) et \(Fmt.num(searchRange.upperBound)) Hz.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .listening:
            VStack(alignment: .leading, spacing: 10) {
                Text("Frappez le bout de la grume…").font(.headline)
                ProgressView(value: min(1, max(0, (recorder.levelDb + 80) / 80)))
                    .tint(.orange)
                Button("Annuler", role: .cancel) { recorder.cancel() }
            }
        case .analyzing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Analyse du son…")
            }
        }
    }

    @ViewBuilder private func results(_ a: ResonanceAnalysis) -> some View {
        let f = chosenFrequency ?? a.frequency
        let zeta = chosenDecay?.zeta ?? (chosenFrequency == nil ? a.dampingRatio : nil)
        let t30 = chosenDecay?.t30ms ?? (chosenFrequency == nil ? a.decay30ms : nil)
        Section("Résultat") {
            row("Fréquence", "\(Fmt.num(f, 1)) Hz")
            if let L = length {
                let v = 2 * L * f
                row("Vitesse du son", "\(Fmt.num(v)) m/s")
                if let log = store.selected {
                    let d = log.densityForCalc
                    row("Rigidité dynamique", "\(Fmt.num(d.value * v * v / 1e9, 1)) GPa")
                    if d.assumed {
                        Text("Densité supposée : 850 kg/m³ (bois vert). Entrez la masse et les diamètres dans l'onglet Grumes pour un calcul exact.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let z = zeta { row("Amortissement", "\(Fmt.num(z * 100, 2)) %") }
            if let t = t30 { row("Durée −30 dB", "\(Fmt.num(t)) ms") }
            row("Harmoniques", a.harmonics > 0 ? "\(a.harmonics) trouvée(s)" : "aucune")

            if a.peaks.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Autres pics : touchez pour choisir")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(a.peaks, id: \.self) { p in
                                Button("\(Fmt.num(p)) Hz") {
                                    chosenFrequency = p
                                    chosenDecay = ResonanceAnalyzer.decayRate(a.segment, sampleRate: a.sampleRate, f0: p)
                                }
                                .buttonStyle(.bordered)
                                .tint(abs(p - f) < 0.5 ? .orange : .gray)
                            }
                        }
                    }
                }
            }

            SpectrumChart(points: a.spectrum, marker: f)
                .frame(height: 180)

            Button {
                save(a, frequency: f, zeta: zeta, t30: t30)
            } label: {
                Label("Enregistrer dans la grume", systemImage: "square.and.arrow.down")
            }
            .disabled(store.selectedID == nil || length == nil)
            if let m = savedMessage {
                Text(m).foregroundStyle(.green)
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value).monospacedDigit().bold()
        }
    }

    private func save(_ a: ResonanceAnalysis, frequency: Double, zeta: Double?, t30: Double?) {
        guard let id = store.selectedID, let L = length else { return }
        let result = ResonanceResult(frequency: frequency, lengthM: L,
                                     dampingRatio: zeta, decay30ms: t30, harmonics: a.harmonics)
        store.add(result, to: id)
        if store.selected?.lengthM == nil {
            store.update(id) { $0.lengthM = L }
        }
        savedMessage = "Mesure enregistrée dans « \(store.selected?.name ?? "") »."
    }
}

struct SpectrumChart: View {
    let points: [SpectrumPoint]
    let marker: Double

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Fréquence", p.frequency),
                         yStart: .value("dB", -70),
                         yEnd: .value("dB", p.db))
                    .foregroundStyle(Color.orange.opacity(0.18))
                LineMark(x: .value("Fréquence", p.frequency), y: .value("dB", p.db))
                    .foregroundStyle(Color.orange)
            }
            RuleMark(x: .value("Pic", marker))
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartYScale(domain: -70...5)
        .chartYAxis(.hidden)
        .chartXAxisLabel("Hz")
    }
}
