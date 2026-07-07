//
//  SITOREngineCore.swift
//  CoreDSP
//
//  The single public entry point CoreDSP exports for SITOR-B (maritime/
//  NAVTEX-style teleprinter over 7-bit CCIR-476 Moore code with built-in FEC).
//  Wraps SITORFSKDemodulator (RX: audio -> bandpass -> mixer -> matched
//  filter -> bit-sync -> Moore/FEC decoder -> ASCII), all internal to this
//  module, behind the same small mode-agnostic surface RTTYEngineCore/
//  PSKEngineCore use: feed it Float samples at CMFs (11025 Hz) mono, get
//  decoded text out.
//
//  SITOR-B is receive-only in this app, exactly like HF-FAX (see
//  HFFAX/FAXEngineCore.swift's header comment for the same reasoning applied
//  there): the original cocoaModem SITOR.swift is explicit about this --
//  its own doc comment reads "Receive-only (no transmitter):
//  -enterTransmitMode: and -flushAndLeaveTransmit do nothing and no txConfig
//  is initialised" -- and no SITORModulator (or any modulator-shaped class)
//  exists anywhere in the old source tree (confirmed by an exhaustive search
//  of both Sources/Swift/Modems/SITOR-B and Sources/Swift/SITOR-B). SITOR-B
//  as actually used by shore stations/NAVTEX is a one-way broadcast service
//  in this app's receive role, so there is genuinely nothing to transmit.
//  `queueTransmitText(_:)` is therefore a documented no-op and
//  `produceTransmitSamples(_:count:)` always fills silence (same shape as
//  FAXEngineCore's transmit stubs).
//
//  `lastSpectrum`: SITORReceiver's own control (SITORRxControl.awakeFromNib)
//  explicitly sets `spectrumView = nil` and `waterfall = nil` -- there is no
//  SITOR-specific FFT anywhere in the ported DSP chain to reuse. Exactly like
//  RTTYEngineCore, a small purpose-built power spectrum (same shared CMFFT
//  kernel) is computed directly on the raw receive-side audio so a waterfall
//  view has something to draw; it is not fed back into the decode path.
//

import Foundation
import Accelerate

/// A CMPipe whose data stream just points at caller-owned memory -- used to
/// hand a raw 512-sample buffer to SITORFSKDemodulator.importData(_:), which
/// expects to pull its input through the CMPipe stream() contract. (Mirrors
/// RTTYEngineCore's RawBufferPipe; kept as a private file-scoped copy since
/// CoreDSP's internal-by-default classes aren't shared across mode facades.)
private final class SITORRawBufferPipe: CMPipe {
    func setBuffer(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        data.pointee.array = buffer
        data.pointee.samples = samples
        data.pointee.channels = 1
    }
}

public final class SITOREngineCore: SITORDemodulatorDelegate {

    private let demodulator = SITORFSKDemodulator()
    private let feedPipe = SITORRawBufferPipe()

    private var rxScratch = [Float](repeating: 0, count: 512)
    private var rxScratchCount = 0

    private var textLock = NSLock()
    private var pendingText = ""

    //  512-sample real-input power spectrum (256 bins), purely for waterfall display.
    private let spectrumFFT = FFTSpectrum(9, true)
    private var spectrumScratch = [Float](repeating: 0, count: 256)
    /// Latest receive-side spectrum magnitude (linear power), 256 bins -- feed a waterfall view with this.
    public private(set) var lastSpectrum = [Float](repeating: 0, count: 256)

    /// Current receive lock/error state (drives a SITORRxControl-style status lamp in the UI).
    public private(set) var syncState: SITORSyncState = .off

    public init() {
        demodulator.delegate = self
        //  0.6 matches SITORRxControl.setupDefaultPreferences' default squelch
        //  slider value; MooreDecoder's "perfect copy" fast path is squelch-
        //  independent, but the single/double-bit-error FEC tolerance paths
        //  are gated on it (see MooreDecoder.decodeFrom), so a receive-only
        //  engine with squelch left at 0 would silently reject every
        //  imperfect (real-world, noisy) reception.
        demodulator.setSquelch(0.6)
    }

    deinit {
        CMDeleteFFT(spectrumFFT)
    }

    // MARK: - Configuration

    public func setSquelch(_ value: Float) {
        demodulator.setSquelch(value)
    }

    public func setUSOS(_ state: Bool) {
        demodulator.setUSOS(state)
    }

    public func setBell(_ state: Bool) {
        demodulator.setBell(state)
    }

    public func setErrorPrint(_ state: Bool) {
        demodulator.setErrorPrint(state)
    }

    public func setInvert(_ state: Bool) {
        demodulator.setInvert(state)
    }

    // MARK: - RX

    /// Feed mono audio already at CMFs (11025 Hz); any chunk size is fine, this
    /// buffers internally to the demodulator's native 512-sample frame.
    public func receiveSamples(_ samples: UnsafePointer<Float>, count: Int) {
        var offset = 0
        while offset < count {
            let take = min(512 - rxScratchCount, count - offset)
            rxScratch.withUnsafeMutableBufferPointer { dst in
                for i in 0..<take { dst[rxScratchCount + i] = samples[offset + i] }
            }
            rxScratchCount += take
            offset += take
            if rxScratchCount == 512 {
                rxScratch.withUnsafeMutableBufferPointer { buf in
                    feedPipe.setBuffer(buf.baseAddress!, samples: 512)
                    demodulator.importData(feedPipe)
                    spectrumScratch.withUnsafeMutableBufferPointer { specBuf in
                        CMPerformFFT(spectrumFFT, buf.baseAddress!, specBuf.baseAddress!)
                    }
                    lastSpectrum = spectrumScratch
                }
                rxScratchCount = 0
            }
        }
    }

    /// Decoded text accumulated since the last call; empty string if nothing new.
    public func drainReceivedText() -> String {
        textLock.lock()
        let s = pendingText
        pendingText = ""
        textLock.unlock()
        return s
    }

    // MARK: - TX (SITOR-B is receive-only in this app -- see header comment)

    /// No-op: SITOR-B has no transmit path anywhere in the original app.
    public func queueTransmitText(_ text: String) {}

    /// Always fills `buffer` with silence: SITOR-B has no transmit path (see header comment).
    public func produceTransmitSamples(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { buffer[i] = 0 }
    }

    // MARK: - SITORDemodulatorDelegate

    public func sitorReceivedCharacter(_ c: Int32) {
        textLock.lock()
        if c > 0, let scalar = Unicode.Scalar(UInt32(bitPattern: c)) {
            pendingText.unicodeScalars.append(scalar)
        }
        textLock.unlock()
    }

    public func sitorSyncStateChanged(_ state: SITORSyncState) {
        syncState = state
    }
}
