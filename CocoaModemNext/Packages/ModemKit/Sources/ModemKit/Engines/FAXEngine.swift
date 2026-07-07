import Foundation
@_exported import CoreDSP

/// ModemEngine adapter around CoreDSP's FAXEngineCore: handles the
/// device-rate <-> CMFs (11025 Hz) resampling in both directions so the DSP
/// core only ever sees its native rate, exactly like PSKEngine.
///
/// HF-FAX is a receive-only broadcast format (unattended weather-fax coastal
/// stations) -- there is no transmit path (see FAXEngineCore's header
/// comment), so `produceTransmitAudio` always plays silence and
/// `queueTransmitText` is a no-op. The receive side publishes a growing
/// grayscale image (`receivedImageRows`) instead of text; `receivedText`
/// stays permanently empty to satisfy ModemEngine's uniform surface without
/// implying FAX decodes any text.
public final class FAXEngine: ModemEngine, ObservableObject {
    public let name = "HF-FAX"

    private let core = FAXEngineCore()
    private var rxResampler: LinearResampler?
    private var txResampler: LinearResampler?
    private var deviceSampleRate: Double = 44100

    private var rxScratch = [Float](repeating: 0, count: 4096)

    /// Growing, scrolling grayscale image (brightness 0...1 per pixel), one entry per decoded
    /// scanline -- see FAXEngineCore.receivedImageRows for the row-width contract.
    @Published public private(set) var receivedImageRows: [[Float]] = []

    /// Always empty: HF-FAX carries a scanned image, not text (see FAXEngineCore's header comment).
    @Published public private(set) var receivedText: String = ""

    @Published public var halfSize: Bool = true {
        didSet { core.setHalfSize(halfSize) }
    }
    @Published public var deviation850: Bool = false {
        didSet { core.setDeviation850(deviation850) }
    }

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
        let rows = core.receivedImageRows
        DispatchQueue.main.async { [weak self] in
            self?.receivedImageRows = rows
        }
    }

    /// HF-FAX has no transmit path -- always writes silence and reports the full buffer as
    /// "produced" (matches PSKEngine's silent-fallback shape when there's nothing to send).
    public func produceTransmitAudio(_ buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        for i in 0..<count { buffer[i] = 0 }
        return count
    }

    /// Always "": HF-FAX has no text channel (see FAXEngineCore's header comment).
    public func drainReceivedText() -> String { "" }

    /// No-op: HF-FAX has no transmit path.
    public func queueTransmitText(_ text: String) {}

    /// Clears the accumulated image (e.g. a "Clear"/"New image" UI action).
    public func clearReceivedImage() {
        core.clearReceivedImage()
        receivedImageRows = []
    }

    /// Manually restarts phasing/hsync acquisition; not required for normal operation since
    /// the phasing detector auto-detects image start/stop tones on its own.
    public func startNewImage() {
        core.startNewImage()
    }

    /// Input bandwidth preset: 0 = narrow (480 Hz), 1 = normal (650 Hz, default), 2 = wide (1200 Hz).
    public func setBandwidth(_ index: Int32) {
        core.setBandwidth(index)
    }
}
