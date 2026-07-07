import Foundation
@_exported import CoreDSP

/// ModemEngine adapter around CoreDSP's SITOREngineCore: handles the
/// device-rate <-> CMFs (11025 Hz) resampling in both directions so the DSP
/// core only ever sees its native rate, exactly like PSKEngine/RTTYEngine.
///
/// SITOR-B is receive-only in this app -- the original cocoaModem SITOR.swift
/// itself is explicit about this ("Receive-only (no transmitter)"), and no
/// SITORModulator exists anywhere in the old source (SITOR-B/NAVTEX shore
/// stations are a one-way broadcast service in this app's receive role) --
/// so `produceTransmitAudio` always plays silence and `queueTransmitText` is
/// a no-op, exactly like FAXEngine.
public final class SITOREngine: ModemEngine, ObservableObject {
    public let name = "SITOR-B"

    private let core = SITOREngineCore()
    private var rxResampler: LinearResampler?
    private var txResampler: LinearResampler?
    private var deviceSampleRate: Double = 44100

    private var rxScratch = [Float](repeating: 0, count: 4096)

    @Published public private(set) var receivedText: String = ""

    /// Receive lock/error indicator, mirrors the original SITORRxControl status lamp.
    @Published public private(set) var syncState: SITORSyncState = .off

    @Published public var squelch: Float = 0.6 {
        didSet { core.setSquelch(squelch) }
    }
    @Published public var usos: Bool = true {
        didSet { core.setUSOS(usos) }
    }
    @Published public var errorPrint: Bool = false {
        didSet { core.setErrorPrint(errorPrint) }
    }

    /// Linear-power spectrum (256 bins) of the last processed receive block; drives a waterfall view.
    @Published public private(set) var spectrum = [Float](repeating: 0, count: 256)

    public init() {
        core.setSquelch(squelch)
        core.setUSOS(usos)
        core.setErrorPrint(errorPrint)
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
        let text = core.drainReceivedText()
        let newSpectrum = core.lastSpectrum
        let newSyncState = core.syncState
        if !text.isEmpty || spectrumUpdateCounter % 4 == 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !text.isEmpty { self.receivedText += text }
                self.spectrum = newSpectrum
                self.syncState = newSyncState
            }
        }
        spectrumUpdateCounter += 1
    }

    private var spectrumUpdateCounter = 0

    /// SITOR-B has no transmit path (see header comment) -- always writes silence and
    /// reports the full buffer as "produced", matching FAXEngine's silent-fallback shape.
    public func produceTransmitAudio(_ buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        for i in 0..<count { buffer[i] = 0 }
        return count
    }

    /// SwiftUI observes `receivedText` directly (it accumulates, like the
    /// original app's RX pane); this satisfies the ModemEngine protocol for
    /// any non-UI consumer but isn't the primary read path here.
    public func drainReceivedText() -> String { "" }

    /// No-op: SITOR-B has no transmit path (see header comment).
    public func queueTransmitText(_ text: String) {}
}
