//
//  PSKEngineCore.swift
//  CoreDSP
//
//  The single public entry point CoreDSP exports for PSK. Wraps
//  CMPSKDemodulator + CMPSKModulator + CMVaricode (all internal to this
//  module) behind a small, mode-agnostic surface: feed it Float samples at
//  CMFs (11025 Hz) mono, get decoded text out; queue text, get modulated
//  samples out. Everything below this point is a faithful transplant of the
//  original DSP; this facade is new, written to give ModemKit (a separate
//  module/package) something clean to depend on without having to make every
//  ported internal class public.
//

import Foundation
import Accelerate

public enum PSKMode: Hashable {
    case bpsk31, bpsk63, qpsk31

    var rawValue: Int32 {
        switch self {
        case .bpsk31: return 0
        case .bpsk63: return 1
        case .qpsk31: return 2
        }
    }
}

/// A CMPipe whose data stream just points at caller-owned memory -- used to
/// hand a raw 512-sample buffer to CMPSKDemodulator.importData(_:), which
/// expects to pull its input through the CMPipe stream() contract.
private final class RawBufferPipe: CMPipe {
    func setBuffer(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        data.pointee.array = buffer
        data.pointee.samples = samples
        data.pointee.channels = 1
    }
}

public final class PSKEngineCore: CMPSKDemodulatorDelegate, CMPSKModulatorDelegate {

    private let demod = CMPSKDemodulator()
    private let mod = CMPSKModulator()
    private let feedPipe = RawBufferPipe()

    private var rxScratch = [Float](repeating: 0, count: 512)
    private var rxScratchCount = 0

    private var textLock = NSLock()
    private var pendingText = ""

    public var afcEnabled: Bool = true
    /// Latest receive-side spectrum magnitude (linear power), 512 bins -- feed a waterfall view with this.
    public private(set) var lastSpectrum = [Float](repeating: 0, count: 512)

    public init() {
        demod.delegate = self
        mod.delegate = self
        demod.setPSKMode(PSKMode.bpsk31.rawValue)
        mod.setPSKMode(PSKMode.bpsk31.rawValue)
    }

    public func setMode(_ mode: PSKMode) {
        demod.setPSKMode(mode.rawValue)
        mod.setPSKMode(mode.rawValue)
    }

    /// `fromWaterfall: true` re-triggers AFC acquisition (user clicked a new frequency);
    /// `false` keeps the existing lock (e.g. restoring a saved frequency).
    public func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        demod.selectFrequency(freq, fromWaterfall: fromWaterfall)
        mod.setFrequency(freq)
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
                }
                demod.importData(feedPipe)
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
            mod.appendASCII(Int32(scalar.value))
        }
    }

    /// Fill `buffer` with `count` samples of modulated audio at CMFs (11025 Hz).
    public func produceTransmitSamples(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        mod.getBufferWithIdleFill(buffer, length: Int32(count))
    }

    // MARK: - CMPSKDemodulatorDelegate

    public func pskReceivedCharacter(_ c: Int32, spectrum: UnsafeMutablePointer<Float>) {
        textLock.lock()
        if let scalar = Unicode.Scalar(UInt32(bitPattern: c)), c > 0 {
            pendingText.unicodeScalars.append(scalar)
        }
        textLock.unlock()
        lastSpectrum.withUnsafeMutableBufferPointer { dst in
            for i in 0..<512 { dst[i] = spectrum[i] }
        }
    }

    public func pskAfcEnabled() -> Bool { afcEnabled }

    // MARK: - CMPSKModulatorDelegate

    public func pskTransmittedCharacter(_ ch: Int32) {
        //  echo of what was actually sent; no-op for now (UI can observe queueTransmitText's input instead)
    }
}
