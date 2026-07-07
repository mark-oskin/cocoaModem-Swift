import Foundation
@_exported import CoreDSP

/// ModemEngine adapter around CoreDSP's HellEngineCore: handles the
/// device-rate <-> CMFs (11025 Hz) resampling in both directions, exactly like
/// PSKEngine does for PSK.
///
/// Hellschreiber is a facsimile mode, not a decoded-text mode: the receive
/// side is a scrolling pixel image, not text. `receivedText` therefore always
/// stays empty (kept only so any generic UI expecting a `receivedText`
/// published property doesn't need special-casing); the real receive-side
/// product a Hell view should observe is `receivedImageColumns`.
public final class HellEngine: ModemEngine, ObservableObject {
    public let name = "Hellschreiber"

    private let core = HellEngineCore()
    private var rxResampler: LinearResampler?
    private var txResampler: LinearResampler?
    private var deviceSampleRate: Double = 44100

    private var rxScratch = [Float](repeating: 0, count: 4096)
    private var txCoreScratch = [Float](repeating: 0, count: 4096)

    /// Always empty -- Hellschreiber has no decoded text (see type doc).
    @Published public private(set) var receivedText: String = ""
    @Published public var centerFrequency: Float = 1000 {
        didSet { core.selectFrequency(centerFrequency) }
    }
    @Published public var mode: HellMode = .feldHell {
        didSet { core.setMode(mode) }
    }

    /// Scrolling receive-side pixel raster; one 28-element (0...1 brightness)
    /// column per demodulated column, oldest first. Mirrors
    /// HellEngineCore.receivedImageRows -- refreshed on the main thread as
    /// receive audio is processed, for a SwiftUI view to observe directly.
    @Published public private(set) var receivedImageColumns: [[Float]] = []

    public init() {
        core.selectFrequency(centerFrequency)
    }

    /// Called once the audio engine knows the hardware's actual sample rate.
    public func configure(deviceSampleRate: Double) {
        self.deviceSampleRate = deviceSampleRate
        rxResampler = LinearResampler(inputRate: deviceSampleRate, outputRate: CoreDSPSampleRate)
        txResampler = LinearResampler(inputRate: CoreDSPSampleRate, outputRate: deviceSampleRate)
    }

    public func processReceiveAudio(_ samples: UnsafePointer<Float>, count: Int) {
        guard let rxResampler else { return }
        if rxScratch.count < count { rxScratch = [Float](repeating: 0, count: count) }
        let produced = rxScratch.withUnsafeMutableBufferPointer { buf in
            rxResampler.process(samples, inputCount: count, output: buf.baseAddress!, outputCapacity: buf.count)
        }
        rxScratch.withUnsafeBufferPointer { buf in
            core.receiveSamples(buf.baseAddress!, count: produced)
        }
        imageUpdateCounter += 1
        // the image only gains a handful of columns per audio callback; no
        // need to hop to the main thread on every single buffer.
        if imageUpdateCounter % 2 == 0 {
            let columns = core.receivedImageRows
            DispatchQueue.main.async { [weak self] in
                self?.receivedImageColumns = columns
            }
        }
    }

    private var imageUpdateCounter = 0

    public func produceTransmitAudio(_ buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard let txResampler else {
            for i in 0..<count { buffer[i] = 0 }
            return count
        }
        // Ask the DSP core for enough native-rate samples to cover this device-rate
        // buffer after resampling, with margin for the rate ratio.
        let neededCore = Int(Double(count) * (CoreDSPSampleRate / deviceSampleRate)) + 8
        if txCoreScratch.count < neededCore { txCoreScratch = [Float](repeating: 0, count: neededCore) }
        txCoreScratch.withUnsafeMutableBufferPointer { buf in
            core.produceTransmitSamples(buf.baseAddress!, count: neededCore)
        }
        let produced = txCoreScratch.withUnsafeBufferPointer { buf in
            txResampler.process(buf.baseAddress!, inputCount: neededCore, output: buffer, outputCapacity: count)
        }
        for i in produced..<count { buffer[i] = 0 }
        return count
    }

    /// Always "" -- see type doc; Hellschreiber has no decoded text.
    public func drainReceivedText() -> String { "" }

    public func queueTransmitText(_ text: String) {
        core.queueTransmitText(text)
    }
}
