import Foundation

/// A simple phase-accumulator linear-interpolation resampler between arbitrary
/// sample rates. Not as clean as a proper polyphase/FIR resampler, but more
/// than adequate for feeding narrowband digital-mode demodulators (a few kHz
/// of bandwidth) from whatever rate AVAudioEngine hands us -- and it works for
/// any input/output ratio, including the non-integer ones real devices use
/// (e.g. 48000 -> 11025).
public final class LinearResampler {
    private let inputRate: Double
    private let outputRate: Double
    private var lastSample: Float = 0
    private var phase: Double = 0

    public init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        self.outputRate = outputRate
    }

    /// Consumes `input`, appends resampled output into `output`, returns the
    /// number of output samples produced.
    public func process(_ input: UnsafePointer<Float>, inputCount: Int, output: UnsafeMutablePointer<Float>, outputCapacity: Int) -> Int {
        guard inputRate > 0, outputRate > 0, inputCount > 0 else { return 0 }
        let ratio = inputRate / outputRate
        var outCount = 0
        let prev = lastSample
        while outCount < outputCapacity {
            // phase is the fractional input-sample position of the next output sample,
            // relative to the start of this call's input buffer.
            let pos = phase
            if pos >= Double(inputCount) { break }
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let s0 = (idx == 0) ? prev : input[idx - 1]
            let s1 = input[idx]
            output[outCount] = s0 + (s1 - s0) * frac
            outCount += 1
            phase += ratio
        }
        phase -= Double(inputCount)
        if phase < 0 { phase = 0 }
        lastSample = input[inputCount - 1]
        return outCount
    }
}
