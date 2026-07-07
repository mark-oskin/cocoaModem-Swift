//
//  MFSKEngineCore.swift
//  CoreDSP
//
//  The single public entry point CoreDSP exports for MFSK.  Wraps
//  MFSK16Modulator + MFSK16Demodulator + MFSKReceiverFrontEnd (all internal
//  to this module) behind a small, mode-agnostic surface: feed it Float
//  samples at CMFs (11025 Hz) mono, get decoded text out; queue text, get
//  modulated samples out.  Mirrors PSKEngineCore's shape exactly.
//
//  Only MFSK16 is wired up -- see MODERNIZATION notes / the transplant report
//  for why DominoEX didn't make the cut this pass.
//

import Foundation
import Accelerate

public final class MFSKEngineCore: MFSKModulatorDelegate, MFSKDemodulatorDelegate {

    private let modulator = MFSK16Modulator()
    private let demodulator = MFSK16Demodulator()
    private lazy var frontEnd = MFSKReceiverFrontEnd(demodulator: demodulator)

    private var rxScratch = [Float](repeating: 0, count: 512)
    private var rxScratchCount = 0

    private var textLock = NSLock()
    private var pendingText = ""

    /// Latest receive-side spectrum magnitude (linear power), 384 bins -- feed a waterfall view with this.
    public private(set) var lastSpectrum = [Float](repeating: 0, count: 384)

    public init() {
        modulator.delegate = self
        demodulator.delegate = self
        selectFrequency(1000, fromWaterfall: true)
    }

    /// `fromWaterfall: true` re-triggers AFC/demodulator-state reset (user clicked a new frequency);
    /// `false` keeps the existing lock (e.g. restoring a saved frequency).
    public func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        modulator.setFrequency(freq)
        frontEnd.selectFrequency(freq, fromWaterfall: fromWaterfall)
    }

    // MARK: - RX

    /// Feed mono audio already at CMFs (11025 Hz); any chunk size is fine, this
    /// buffers internally to the receiver front end's native 512-sample frame.
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
                    frontEnd.importArray(buf.baseAddress!)
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

    // MARK: - TX

    public func queueTransmitText(_ text: String) {
        for scalar in text.unicodeScalars {
            modulator.appendASCII(Int32(scalar.value))
        }
    }

    /// Fill `buffer` with `count` samples of modulated audio at CMFs (11025 Hz).
    public func produceTransmitSamples(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        modulator.getBufferWithIdleFill(buffer, length: Int32(count))
    }

    // MARK: - MFSKModulatorDelegate

    func mfskTransmittedCharacter(_ ch: Int32) {
        //  echo of what was actually sent; no-op for now (UI can observe queueTransmitText's input instead)
    }

    func mfskChangeTransmitLight(_ state: Int32) {}

    // MARK: - MFSKDemodulatorDelegate

    func mfskDisplayCharacter(_ c: Int32) {
        textLock.lock()
        if let scalar = Unicode.Scalar(UInt32(bitPattern: c)), c > 0 {
            pendingText.unicodeScalars.append(scalar)
        }
        textLock.unlock()
    }

    func mfskApplyRxFreqOffset(_ offset: Float) {
        //  Slow AFC feedback that retunes the front-end mixer for large drift;
        //  the demodulator's internal bin-tracking AFC (+/-4 bins, ~62.5 Hz)
        //  handles the common case on its own. Not wired up in this pass --
        //  see the transplant report's known-limitations note.
    }

    func mfskNewSpectrum(_ spectrum: UnsafeMutablePointer<Float>, count: Int32) {
        lastSpectrum.withUnsafeMutableBufferPointer { dst in
            for i in 0..<Int(count) { dst[i] = spectrum[i] }
        }
    }
}
