//
//  ASCIIEngineCore.swift
//  CoreDSP
//
//  The single public entry point CoreDSP exports for ASCII (async serial
//  ASCII-RTTY, e.g. "AMTOR-style" plain-ASCII digital mode). Wires together
//  ASCIIModulator (TX) and the RX chain -- CMBandpassFilter (already ported,
//  shared with every mode) -> ASCIIMixer -> ASCIIMatchedFilter -> ASCIIATC ->
//  ASCIIDecoderStage -- behind a small, mode-agnostic surface: feed it Float
//  samples at CMFs (11025 Hz) mono, get decoded text out; queue text, get
//  modulated samples out.
//
//  This facade (and the pipeline wiring it does) is new, written fresh to
//  replace the old app's UI-coupled coordinators (ASCII.swift/
//  ASCIITxConfig.swift/ASCIIReceiver.swift), which mixed this DSP wiring with
//  AppKit views, Preferences/Plist persistence and AppleScript hooks that
//  don't belong in a headless DSP core. The DSP algorithm itself (modulator
//  bit framing, mixer/matched-filter/ATC demodulation chain, decoder framing)
//  is a faithful transplant -- see ASCIIModulator.swift, ASCIIMixer.swift,
//  ASCIIMatchedFilter.swift, ASCIIATC.swift, ASCIIDecoderStage.swift.
//

import Foundation
import Accelerate

/// A CMPipe whose data stream just points at caller-owned memory -- used to
/// hand a raw 512-sample buffer to the bandpass filter's importData(_:).
private final class ASCIIRawBufferPipe: CMPipe {
    func setBuffer(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        data.pointee.array = buffer
        data.pointee.samples = samples
        data.pointee.channels = 1
    }
}

public final class ASCIIEngineCore: ASCIIDecoderDelegate {

    private let modulator = ASCIIModulator()
    private var bandpass: CMBandpassFilter
    private let mixer = ASCIIMixer()
    private let matchedFilter: ASCIIMatchedFilter
    private let atc = ASCIIATC()
    private let decoder = ASCIIDecoderStage()
    private let feedPipe = ASCIIRawBufferPipe()

    private var rxScratch = [Float](repeating: 0, count: 512)
    private var rxScratchCount = 0

    private var textLock = NSLock()
    private var pendingText = ""

    private var markHz: Double = 2125.0
    private var spaceHz: Double = 2295.0
    private var baud: Double = 110.0

    //  256-bin linear-power spectrum of the last processed receive block (waterfall feed).
    public private(set) var lastSpectrum = [Float](repeating: 0, count: 256)
    //  Leaked intentionally (process-lifetime, like CoreModem.swift's sin/cos tables):
    //  freeing it would require tearing down every ASCIIEngineCore, which never happens
    //  in practice (one engine per mode tab, alive for the app's lifetime).
    private let spectrumFFT = FFTSpectrum(9, true)

    public init() {
        bandpass = ASCIIEngineCore.makeBandpass(mark: 2125.0, space: 2295.0, width: 500.0)
        matchedFilter = ASCIIMatchedFilter(baudRate: 110.0)
        decoder.delegate = self

        atc.setClient(decoder)
        matchedFilter.setClient(atc)
        mixer.setClient(matchedFilter)
        bandpass.setClient(mixer)

        mixer.setTonePair(mark: markHz, space: spaceHz)
        atc.setBitsPerCharacter(7)
        atc.setBitSampling(baudRate: Float(baud))
        modulator.setTonePair(mark: markHz, space: spaceHz, baud: baud)
    }

    private static func makeBandpass(mark: Double, space: Double, width: Float) -> CMBandpassFilter {
        let lower = Float(min(mark, space))
        let upper = Float(max(mark, space))
        let shift = upper - lower
        let delta = max(0, (width - shift) * 0.5)
        return CMBandpassFilter(lowCutoff: lower - delta, highCutoff: upper + delta, length: 256)
    }

    // MARK: - Configuration

    /// Mark/space tone frequencies in Hz (default 2125/2295, the classic RTTY/ASCII pair).
    public func setTonePair(mark: Double, space: Double) {
        markHz = mark; spaceHz = space
        mixer.setTonePair(mark: mark, space: space)
        modulator.setTonePair(mark: markHz, space: spaceHz, baud: baud)
        bandpass = ASCIIEngineCore.makeBandpass(mark: mark, space: space, width: 500.0)
        bandpass.setClient(mixer)
    }

    /// Baud rate (default 110, standard async ASCII-RTTY).
    public func setBaudRate(_ rate: Double) {
        baud = rate
        modulator.setTonePair(mark: markHz, space: spaceHz, baud: baud)
        matchedFilter.setDataRate(Float(rate))
        atc.setBitSampling(baudRate: Float(rate))
    }

    /// 7 or 8 data bits per character (default 7).
    public func setBitsPerCharacter(_ bits: Int) {
        modulator.setBitsPerCharacter(Int32(bits))
        atc.setBitsPerCharacter(Int32(bits))
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
                    if let fft = spectrumFFT {
                        lastSpectrum.withUnsafeMutableBufferPointer { spec in
                            CMPerformFFT(fft, buf.baseAddress!, spec.baseAddress!)
                        }
                    }
                    feedPipe.setBuffer(buf.baseAddress!, samples: 512)
                    bandpass.importData(feedPipe)
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

    // MARK: - ASCIIDecoderDelegate

    public func asciiReceivedCharacter(_ c: Int32) {
        textLock.lock()
        if c > 0, let scalar = Unicode.Scalar(UInt32(bitPattern: c)) {
            pendingText.unicodeScalars.append(scalar)
        }
        textLock.unlock()
    }
}
