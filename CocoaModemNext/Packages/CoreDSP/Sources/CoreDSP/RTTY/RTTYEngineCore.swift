//
//  RTTYEngineCore.swift
//  CoreDSP
//
//  The single public entry point CoreDSP exports for RTTY. Wraps
//  CMFSKModulator (TX: ASCII -> Baudot -> FSK-keyed audio) and
//  CMFSKDemodulator (RX: audio -> bandpass -> mixer -> matched filter -> ATC
//  bit-sync/threshold -> Baudot decoder -> ASCII), all internal to this
//  module, behind a small mode-agnostic surface: feed it Float samples at
//  CMFs (11025 Hz) mono, get decoded text out; queue text, get modulated
//  samples out. Everything below this point is a faithful transplant of the
//  original DSP; this facade is new, written to give ModemKit (a separate
//  module/package) something clean to depend on, exactly like PSKEngineCore.
//
//  Unlike PSK's demodulator (a CMToneReceiver, which runs its own AFC loop and
//  produces a genuine acquisition-spectrum FFT as a side effect of decoding),
//  RTTY's CMFSKDemodulator chain has no native spectrum step -- it never needs
//  one, since the bandpass filter is fixed once mark/space/baud are set. The
//  `lastSpectrum` here is therefore a small purpose-built power spectrum
//  (using the same shared CMFFT kernel PSK uses) computed directly on the raw
//  receive-side audio, independent of -- and not fed back into -- the decode
//  path. It exists solely so a waterfall view has something to draw.
//

import Foundation
import Accelerate

/// A CMPipe whose data stream just points at caller-owned memory -- used to
/// hand a raw 512-sample buffer to CMFSKDemodulator.importData(_:), which
/// expects to pull its input through the CMPipe stream() contract.
private final class RawBufferPipe: CMPipe {
    func setBuffer(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        data.pointee.array = buffer
        data.pointee.samples = samples
        data.pointee.channels = 1
    }
}

public final class RTTYEngineCore: CMFSKDemodulatorDelegate {

    private let modulator = CMFSKModulator()
    private let demodulator = CMFSKDemodulator()
    private let feedPipe = RawBufferPipe()

    private var rxScratch = [Float](repeating: 0, count: 512)
    private var rxScratchCount = 0

    private var textLock = NSLock()
    private var pendingText = ""

    private var currentMark: Float = 2125.0
    private var currentSpace: Float = 2295.0
    private var currentBaud: Float = 45.45

    //  512-sample real-input power spectrum (256 bins), purely for waterfall display.
    private let spectrumFFT = FFTSpectrum(9, true)
    private var spectrumScratch = [Float](repeating: 0, count: 256)
    /// Latest receive-side spectrum magnitude (linear power), 256 bins -- feed a waterfall view with this.
    public private(set) var lastSpectrum = [Float](repeating: 0, count: 256)

    public init() {
        demodulator.delegate = self
        applyTonePair()
    }

    deinit {
        CMDeleteFFT(spectrumFFT)
    }

    private func applyTonePair() {
        var pair = CMTonePair(mark: Double(currentMark), space: Double(currentSpace), baud: Double(currentBaud))
        modulator.setTonePair(&pair)
        demodulator.setTonePair(&pair)
    }

    // MARK: - Configuration

    public func setMarkFrequency(_ hz: Float) {
        currentMark = hz
        applyTonePair()
    }

    public func setSpaceFrequency(_ hz: Float) {
        currentSpace = hz
        applyTonePair()
    }

    /// Convenience for the common "center frequency + shift" way RTTY controls are usually presented.
    public func setShift(mark: Float, space: Float) {
        currentMark = mark
        currentSpace = space
        applyTonePair()
    }

    public func setBaudRate(_ baud: Float) {
        currentBaud = baud
        applyTonePair()
    }

    public func setUSOS(_ state: Bool) {
        modulator.setUSOS(state)
        demodulator.setUSOS(state)
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

    // MARK: - TX

    public func queueTransmitText(_ text: String) {
        for scalar in text.unicodeScalars {
            modulator.appendASCII(Int32(scalar.value))
        }
    }

    /// Fill `buffer` with `count` samples of modulated audio at CMFs (11025 Hz).
    public func produceTransmitSamples(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        modulator.getBufferWithDiddleFill(buffer, length: Int32(count))
    }

    // MARK: - CMFSKDemodulatorDelegate

    func fskReceivedCharacter(_ c: Int32) {
        textLock.lock()
        if c > 0, let scalar = Unicode.Scalar(UInt32(bitPattern: c)) {
            pendingText.unicodeScalars.append(scalar)
        }
        textLock.unlock()
    }
}
