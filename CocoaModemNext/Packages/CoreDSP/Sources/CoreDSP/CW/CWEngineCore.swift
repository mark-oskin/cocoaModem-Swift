//
//  CWEngineCore.swift
//  CoreDSP
//
//  The single public entry point CoreDSP exports for Wideband CW (Morse).
//  Wraps CWModulator (TX) + CWMixer/CWPipeline/CWSpeedPipeline/CWMatchedFilter
//  + CWMorseDecoder (RX, all internal to this module) behind the same small,
//  mode-agnostic surface PSKEngineCore exposes: feed it Float samples at CMFs
//  (11025 Hz) mono, get decoded text out; queue text, get modulated samples
//  out. Everything below this point is a faithful transplant of the original
//  DSP (see the per-file port notes in this folder for exact deviations);
//  this facade is new, written to give ModemKit something clean to depend on.
//
//  WATERFALL: CW's demod chain works entirely in mixed-down I/Q baseband (see
//  CWMixer) and never computes a spectrum of its own the way PSK's AFC does.
//  So `lastSpectrum` here is synthesized independently and separately from
//  decoding: a running 1024-sample window of the raw receive audio is
//  power-spectrum'd with CMFFT on every 512-sample block, purely for
//  waterfall display -- it plays no part in decoding.
//

import Foundation
import Accelerate

public final class CWEngineCore {

    private let modulator = CWModulator()
    private let mixer = CWMixer()
    private let matchedFilter = CWMatchedFilter()
    private let decoder = CWMorseDecoder()

    private var rxScratch = [Float](repeating: 0, count: 512)
    private var rxScratchCount = 0

    private var iBlock = [Float](repeating: 0, count: 512)
    private var qBlock = [Float](repeating: 0, count: 512)

    private var textLock = NSLock()
    private var pendingText = ""

    //  waterfall spectrum synthesis (see file header) -- log2n=10 => size 1024,
    //  nby2 = 512 output bins, matching PSKEngineCore's 512-bin convention.
    private let fft: UnsafeMutablePointer<CMFFT> = FFTSpectrum(10, true)
    private var fftWindow = [Float](repeating: 0, count: 1024)
    /// Latest synthesized receive-side spectrum (linear power), 512 bins -- feed a waterfall view with this.
    public private(set) var lastSpectrum = [Float](repeating: 0, count: 512)

    public init() {
        matchedFilter.decoder = decoder
        decoder.onCharacter = { [weak self] c in
            self?.appendDecoded(c)
        }
    }

    deinit {
        CMDeleteFFT(fft)
    }

    // MARK: - Configuration

    /// Sets both the receive mixer's mark frequency and the transmit carrier
    /// (mirrors PSKEngineCore.selectFrequency setting demod + mod together).
    public func setToneFrequency(_ freq: Float) {
        mixer.setMarkFrequency(freq)
        modulator.setCarrier(freq)
    }

    /// Sets the transmit keying speed and, by default, also pins the receive
    /// matched filter to that same speed (bypassing the auto speed-estimation
    /// warm-up so a locally-generated signal decodes immediately). Pass
    /// `autoReceiveSpeed: true` to leave the RX side in the original's "auto"
    /// tracking mode, which estimates the incoming code speed on the fly.
    public func setWPM(_ wpm: Float, autoReceiveSpeed: Bool = false) {
        modulator.setSpeed(wpm)
        matchedFilter.changeCodeSpeed(to: autoReceiveSpeed ? 0 : Int32(wpm.rounded()))
    }

    /// Live adaptive speed estimate (wpm) from the receive side.
    public var estimatedWPM: Float { matchedFilter.currentWPM }

    // MARK: - RX

    /// Feed mono audio already at CMFs (11025 Hz); any chunk size is fine, this
    /// buffers internally to the demod chain's native 512-sample frame.
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
                rxScratch.withUnsafeBufferPointer { buf in
                    let block = buf.baseAddress!
                    iBlock.withUnsafeMutableBufferPointer { ib in
                        qBlock.withUnsafeMutableBufferPointer { qb in
                            mixer.importBlock(block, iOut: ib.baseAddress!, qOut: qb.baseAddress!)
                            matchedFilter.importBlock(ib.baseAddress!, qb.baseAddress!)
                        }
                    }
                    updateSpectrum(block)
                }
                rxScratchCount = 0
            }
        }
    }

    private func updateSpectrum(_ block: UnsafePointer<Float>) {
        fftWindow.withUnsafeMutableBufferPointer { win in
            for i in 0..<512 { win[i] = win[i + 512] }
            for i in 0..<512 { win[i + 512] = block[i] }
            lastSpectrum.withUnsafeMutableBufferPointer { out in
                CMPerformFFT(fft, win.baseAddress!, out.baseAddress!)
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

    private func appendDecoded(_ c: Int32) {
        guard let scalar = Unicode.Scalar(UInt32(bitPattern: c)) else { return }
        textLock.lock()
        pendingText.unicodeScalars.append(scalar)
        textLock.unlock()
    }

    // MARK: - TX

    public func queueTransmitText(_ text: String) {
        for scalar in text.unicodeScalars {
            modulator.appendASCII(Int32(scalar.value))
        }
    }

    /// Queues the ^E end-of-transmit marker (mirrors the original's
    /// -insertEndOfTransmit / "%[rx]" macro).
    public func insertEndOfTransmit() {
        modulator.insertEndOfTransmit()
    }

    public func bufferEmpty() -> Bool {
        modulator.bufferEmpty()
    }

    /// Fill `buffer` with `count` samples of keyed CW audio at CMFs (11025 Hz).
    public func produceTransmitSamples(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        var offset = 0
        while offset < count {
            let take = min(512, count - offset)
            modulator.produceSamples(buffer + offset, samples: Int32(take))
            offset += take
        }
    }
}
