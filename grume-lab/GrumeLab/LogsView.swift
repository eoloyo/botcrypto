import SwiftUI

struct LogsView: View {
    @EnvironmentObject var store: LogStore

    var body: some View {
        NavigationStack {
            List {
                ForEach($store.logs) { $log in
                    NavigationLink {
                        LogDetailView(log: $log)
                    } label: {
                        LogRow(log: log)
                    }
                }
                .onDelete { offsets in
                    store.logs.remove(atOffsets: offsets)
                    if store.selectedIndex == nil { store.selectedID = store.logs.first?.id }
                }
            }
            .navigationTitle("Grumes")
            .toolbar {
                Button {
                    store.selectedID = store.addLog()
                } label: {
                    Image(systemName: "plus")
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
                NumberField(title: "Masse", unit: "kg", value: $log.massKg)
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
