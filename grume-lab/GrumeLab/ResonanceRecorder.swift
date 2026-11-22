import Foundation
import AVFoundation
import Accelerate

/// Listens to the microphone, waits for the hammer knock, records 2 s and analyses it.
final class ResonanceRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, analyzing, done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var levelDb: Double = -80
    @Published private(set) var analysis: ResonanceAnalysis?

    /// Minimum peak level (full scale = 1) that counts as a knock.
    var minThreshold: Float = 0.05

    private let engine = AVAudioEngine()
    private var sampleRate: Double = 48_000
    private var pre: [Float] = []
    private var captured: [Float] = []
    private var capturing = false
    private var finished = false
    private var armedAfter = Date.distantFuture
    private var noise: Float = 0.002
    private var lastLevelUpdate = Date.distantPast
    private var range: ClosedRange<Double> = 20...5000
    private let captureSeconds = 2.0

    func start(range: ClosedRange<Double>) {
        self.range = range
        analysis = nil
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.begin()
                } else {
                    self.phase = .failed("Autorisez le micro : Réglages › Grume Lab › Micro.")
                }
            }
        }
    }

    func cancel() {
        stopEngine()
        phase = .idle
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try? session.setPreferredSampleRate(48_000)
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                phase = .failed("Micro indisponible.")
                return
            }
            sampleRate = format.sampleRate
            pre = []
            captured = []
            capturing = false
            finished = false
            noise = 0.002
            armedAfter = Date().addingTimeInterval(0.4)   // ignore the tap on the button

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            engine.prepare()
            try engine.start()
            phase = .listening
        } catch {
            phase = .failed("Micro indisponible : \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Called on the audio thread.
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard !finished, let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: n))

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(n))

        let now = Date()
        if now.timeIntervalSince(lastLevelUpdate) > 0.05 {
            lastLevelUpdate = now
            let level = 20 * log10(Double(max(rms, 1e-6)))
            DispatchQueue.main.async { self.levelDb = level }
        }

        if capturing {
            captured.append(contentsOf: samples)
            if Double(captured.count) >= captureSeconds * sampleRate {
                capturing = false
                finished = true
                let data = captured
                let sr = sampleRate
                let r = range
                DispatchQueue.main.async {
                    self.stopEngine()
                    self.phase = .analyzing
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = ResonanceAnalyzer.analyze(samples: data, sampleRate: sr, range: r)
                    DispatchQueue.main.async {
                        self.analysis = result
                        self.phase = result == nil
                            ? .failed("Pas de résonance nette. Frappez un coup sec, téléphone près du bout, et recommencez.")
                            : .done
                    }
                }
            }
            return
        }

        let threshold = max(minThreshold, noise * 12)
        if now > armedAfter && peak > threshold {
            capturing = true
            captured = pre + samples
        } else {
            noise = 0.97 * noise + 0.03 * rms
            pre.append(contentsOf: samples)
            let keep = Int(0.05 * sampleRate)
            if pre.count > keep { pre.removeFirst(pre.count - keep) }
        }
    }
}
