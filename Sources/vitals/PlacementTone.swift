import AVFoundation
import os

/// A sine tone whose pitch follows the placement quality, so the device can be
/// turned without looking at the screen. Pitch and volume glide toward their
/// targets inside the render callback, which avoids clicks at every update.
final class PlacementTone: @unchecked Sendable {
    private struct Target {
        var frequency = 440.0
        var amplitude = 0.0
    }

    private let target = OSAllocatedUnfairLock(initialState: Target())
    private var engine: AVAudioEngine?

    /// Sets pitch and volume (0...1). Volume 0 silences the tone.
    func set(frequency: Double, volume: Double) {
        let amplitude = 0.3 * volume * volume
        target.withLock {
            $0.frequency = frequency
            $0.amplitude = amplitude
        }
        if amplitude > 0 { startIfNeeded() }
    }

    func silence() {
        target.withLock { $0.amplitude = 0 }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }

    private func startIfNeeded() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let target = self.target
        var phase = 0.0
        var frequency = 440.0
        var amplitude = 0.0
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let wanted = target.withLock { $0 }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                frequency += (wanted.frequency - frequency) * 0.0015
                amplitude += (wanted.amplitude - amplitude) * 0.0015
                let value = Float(sin(phase) * amplitude)
                phase += 2 * Double.pi * frequency / sampleRate
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            Printer.err("placement tone: \(error.localizedDescription)")
        }
    }
}
