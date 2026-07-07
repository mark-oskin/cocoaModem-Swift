//
//  HellEngineCore.swift
//  CoreDSP
//
//  The single public entry point CoreDSP exports for Hellschreiber. Wraps
//  HellModulator + HellReceiver (both internal to this module) behind a small,
//  mode-agnostic surface: feed it Float samples at CMFs (11025 Hz) mono, get a
//  scrolling pixel-raster image out; queue text, get modulated samples out.
//
//  Hellschreiber is fundamentally a facsimile mode, not a decoded-text mode --
//  the receiver reconstructs a scrolling image of pixel columns that a human
//  reads visually, it does not decode characters. So unlike PSKEngineCore,
//  there is no decoded-text output: `drainReceivedText()` is a documented
//  no-op returning "", and the real receive-side product is
//  `receivedImageRows`.
//
//  Image representation: `receivedImageRows` is `[[Float]]`, one element per
//  demodulated column (oldest first, newest appended at the end), each column
//  28 Floats in 0...1 (brightness, 0 = dark/off, 1 = full brightest pixel) --
//  exactly the "double height" 28-half-pixel column HellReceiver's
//  feldDemodulate/fmResample105/fmResample245 already produce internally (see
//  their `pixelColumn` buffer and the original app's
//  `addColumn(_:index:xScale:)` contract). This shape was chosen because it's
//  what the ported DSP naturally emits per demodulated column -- no
//  reprocessing needed, and a UI can render it directly as a scrolling
//  grayscale raster (each element of the outer array is one image column;
//  transpose/rotate however the view wants to draw it). The buffer is capped
//  at `maxColumns` (oldest columns are dropped) so a long-running receive
//  session doesn't grow unbounded.
//

import Foundation

public enum HellMode: Hashable {
    case feldHell, fmHell245, fmHell105

    var rawValue: Int32 {
        switch self {
        case .feldHell: return HELLFELD
        case .fmHell245: return HELLFM245
        case .fmHell105: return HELLFM105
        }
    }
}

/// A CMPipe whose data stream just points at caller-owned memory -- used to
/// hand a raw 512-sample buffer to HellReceiver.importData(_:), which expects
/// to pull its input through the CMPipe stream() contract. (Same idiom as
/// PSKEngineCore's file-private RawBufferPipe; file-private names don't
/// collide across files in the same module.)
private final class RawBufferPipe: CMPipe {
    func setBuffer(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        data.pointee.array = buffer
        data.pointee.samples = samples
        data.pointee.channels = 1
    }
}

public final class HellEngineCore: HellModulatorDelegate, HellReceiverDelegate {

    private let mod = HellModulator()
    private let rx = HellReceiver()
    private let feedPipe = RawBufferPipe()

    private var rxScratch = [Float](repeating: 0, count: 512)
    private var rxScratchCount = 0

    private let imageLock = NSLock()
    /// Maximum number of columns retained in `receivedImageRows` before the
    /// oldest are dropped.
    public var maxColumns = 2048

    /// Scrolling receive-side pixel raster: one 28-element (0...1 brightness)
    /// column per demodulated column, oldest first. See file header for why
    /// this shape was chosen.
    public private(set) var receivedImageRows: [[Float]] = []

    public init() {
        mod.delegate = self
        rx.delegate = self
        mod.setMode(HellMode.feldHell.rawValue)
        rx.setMode(HellMode.feldHell.rawValue)
        selectFrequency(1000)
    }

    public func setMode(_ mode: HellMode) {
        mod.setMode(mode.rawValue)
        rx.setMode(mode.rawValue)
    }

    public func selectFrequency(_ freq: Float) {
        rx.selectFrequency(freq, fromWaterfall: false)
        mod.setFrequency(freq)
    }

    // MARK: - RX

    /// Feed mono audio already at CMFs (11025 Hz); any chunk size is fine, this
    /// buffers internally to the receiver's native 512-sample frame.
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
                rx.importData(feedPipe)
                rxScratchCount = 0
            }
        }
    }

    /// Hellschreiber is a facsimile mode: there is no decoded text, only a
    /// scrolling pixel image (see `receivedImageRows`). This always returns ""
    /// -- kept only so callers that expect a ModemEngine-shaped text drain
    /// don't need special-casing.
    public func drainReceivedText() -> String { "" }

    // MARK: - TX

    public func queueTransmitText(_ text: String) {
        for scalar in text.unicodeScalars {
            mod.appendASCII(Int32(scalar.value))
        }
    }

    /// Fill `buffer` with `count` samples of modulated audio at CMFs (11025 Hz).
    public func produceTransmitSamples(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        var offset = 0
        while offset < count {
            let take = min(512, count - offset)
            mod.getBufferWithIdleFill(buffer + offset, length: Int32(take))
            offset += take
        }
    }

    // MARK: - HellReceiverDelegate

    public func hellAddColumn(_ column: [Float], index: Int32) {
        imageLock.lock()
        receivedImageRows.append(column)
        if receivedImageRows.count > maxColumns {
            receivedImageRows.removeFirst(receivedImageRows.count - maxColumns)
        }
        imageLock.unlock()
    }
}
