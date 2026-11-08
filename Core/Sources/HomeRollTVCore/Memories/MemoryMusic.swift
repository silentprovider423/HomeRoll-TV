import AVFoundation
import Foundation

// Hintergrundmusik der Rückblicke und Diashows – selbst erzeugt (Akkordfläche, Glocken-Arpeggio, Bass),
// übernommen aus HomeRoll (App/Collections/Memories.swift). Keine Musikdateien, keine Lizenzen.

final class MemoryMusic: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let synth = Synth()

    func play(_ mood: MemoryMood) {
        stop()
        guard mood != .none else { return }
        #if os(tvOS) || os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        synth.configure(mood, sampleRate: sr > 0 ? sr : 44100)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: synth.sr, channels: 2)!
        let s = synth
        let n = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            s.render(Int(frames), UnsafeMutableAudioBufferListPointer(abl)); return noErr
        }
        node = n
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.9
        try? engine.start()
    }
    var muted: Bool {
        get { synth.muted }
        set { synth.muted = newValue }
    }
    func pause() { synth.paused = true }
    func resume() { synth.paused = false }
    func stop() {
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }
}

final class Synth: @unchecked Sendable {
    var sr: Double = 44100
    var paused = false
    var muted = false
    private var t: Int = 0
    private var gain: Double = 0
    private var lp: Double = 0
    private var bpm: Double = 72
    private var chords: [[Double]] = []
    private var pattern: [Int] = [0, 1, 2, 1]
    private var stepsPerBeat: Double = 1
    private var padLevel = 0.05, bellLevel = 0.11, bassLevel = 0.07, bright = 0.25

    func configure(_ mood: MemoryMood, sampleRate: Double) {
        sr = sampleRate; t = 0; gain = 0; lp = 0
        padLevel = 0.05; bellLevel = 0.11; bassLevel = 0.07; bright = 0.25
        switch mood {
        case .gentle:
            bpm = 72; stepsPerBeat = 1; pattern = [0, 1, 2, 1]
            chords = [[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]]
        case .happy:
            bpm = 112; stepsPerBeat = 2; pattern = [0, 1, 2, 1, 0, 2, 1, 2]; padLevel = 0.035; bellLevel = 0.09; bright = 0.45
            chords = [[55, 59, 62], [52, 55, 59], [48, 52, 55], [50, 54, 57]]
        case .thoughtful:
            bpm = 64; stepsPerBeat = 1; pattern = [0, 2, 1, 2]; bright = 0.18
            chords = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
        case .epic:
            bpm = 80; stepsPerBeat = 2; pattern = [0, 1, 2, 1, 0, 1, 2, 1]; padLevel = 0.07; bassLevel = 0.11; bright = 0.3
            chords = [[50, 53, 57], [46, 50, 53], [48, 52, 55], [45, 49, 52]]
        case .none: chords = [[60, 64, 67]]
        }
    }

    private func hz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

    func render(_ frames: Int, _ abl: UnsafeMutableAudioBufferListPointer) {
        let twoPi = 2 * Double.pi
        let beatLen = 60 / bpm, segLen = beatLen * 8          // Akkordwechsel alle 2 Takte
        let stepLen = beatLen / stepsPerBeat
        for f in 0..<frames {
            var v = 0.0
            if !paused {
                let time = Double(t) / sr
                let seg = Int(time / segLen), inSeg = time - Double(seg) * segLen
                let chord = chords[seg % chords.count]
                // Fläche: weich ein-/ausblenden je Akkord, leicht verstimmte Sinus-Paare
                let padEnv = min(1, inSeg / 0.8) * min(1, (segLen - inSeg) / 0.6)
                for m in chord {
                    let fr = hz(m)
                    v += padLevel * padEnv * (sin(twoPi * fr * time) + 0.6 * sin(twoPi * fr * 1.003 * time)) * 0.6
                }
                // Glocken-Arpeggio
                let step = Int(time / stepLen), inStep = time - Double(step) * stepLen
                let note = chord[pattern[step % pattern.count] % chord.count] + 12
                let env = min(1, inStep / 0.006) * exp(-inStep * 3.2)
                let bf = hz(note)
                v += bellLevel * env * (sin(twoPi * bf * inStep) + bright * sin(twoPi * bf * 2 * inStep))
                // Bass auf jedem Takt
                let bar = Int(time / (beatLen * 4)), inBar = time - Double(bar) * beatLen * 4
                let benv = min(1, inBar / 0.02) * exp(-inBar * 0.9)
                v += bassLevel * benv * sin(twoPi * hz(chord[0] - 12) * time)
                t += 1
            }
            // sanft starten/anhalten, dann leichter Tiefpass gegen Härte
            gain += ((paused || muted ? 0 : 1) - gain) * 0.00005
            lp += (v * gain - lp) * 0.35
            let out = Float(max(-1, min(1, lp)))
            for b in 0..<abl.count { abl[b].mData?.assumingMemoryBound(to: Float.self)[f] = out }
        }
    }
}
