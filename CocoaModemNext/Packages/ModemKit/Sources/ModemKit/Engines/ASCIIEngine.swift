import Foundation
@_exported import CoreDSP

/// ModemEngine adapter around CoreDSP's ASCIIEngineCore: handles the
/// device-rate <-> CMFs (11025 Hz) resampling in both directions so the DSP
/// core only ever sees its native rate, exactly like PSKEngine.
public final class ASCIIEngine: ModemEngine, ObservableObject {
    public let name = "ASCII"

    private let core = ASCIIEngineCore()
    private var rxResampler: LinearResampler?
    private var txResampler: LinearResampler?
    private var deviceSampleRate: Double = 44100

    private var rxScratch = [Float](repeating: 0, count: 4096)
    private var txCoreScratch = [Float](repeating: 0, count: 4096)

    @Published public private(set) var receivedText: String = ""
    @Published public var markFrequency: Double = 2125.0 {
        didSet { core.setTonePair(mark: markFrequency, space: spaceFrequency) }
    }
    @Published public var spaceFrequency: Double = 2295.0 {
        didSet { core.setTonePair(mark: markFrequency, space: spaceFrequency) }
    }
    @Published public var baudRate: Double = 110.0 {
        didSet { core.setBaudRate(baudRate) }
    }
    @Published public var bitsPerCharacter: Int = 7 {
        didSet { core.setBitsPerCharacter(bitsPerCharacter) }
    }

    private var spectrumUpdateCounter = 0
    /// Linear-power spectrum (256 bins) of the last processed receive block; drives a waterfall view.
    @Published public private(set) var spectrum = [Float](repeating: 0, count: 256)

    public init() {}

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
        let text = core.drainReceivedText()
        let spectrum = core.lastSpectrum
        if !text.isEmpty || spectrumUpdateCounter % 4 == 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !text.isEmpty { self.receivedText += text }
                self.spectrum = spectrum
            }
        }
        spectrumUpdateCounter += 1
    }

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

    /// SwiftUI observes `receivedText` directly (it accumulates, like the
    /// original app's RX pane); this satisfies the ModemEngine protocol for
    /// any non-UI consumer but isn't the primary read path here.
    public func drainReceivedText() -> String { "" }

    public func queueTransmitText(_ text: String) {
        core.queueTransmitText(text)
    }
}
