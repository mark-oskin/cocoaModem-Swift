//
//  FAXEngineCore.swift
//  CoreDSP
//
//  The single public entry point CoreDSP exports for HF-FAX (weather-fax /
//  radiofax image reception). Wraps FAXReceiver (FM demodulator) +
//  FAXPhasingDetector (phasing/hsync state machine + FAXFrame backing store)
//  behind a small, mode-agnostic surface: feed it Float samples at CMFs
//  (11025 Hz) mono, pull decoded grayscale image rows out. Everything below
//  this point is a faithful transplant of the original DSP; this facade is
//  new, written to give ModemKit (a separate module/package) something clean
//  to depend on without having to make every ported internal class public.
//
//  HF-FAX has no transmit path in this app:
//   - Radiofax/weather-fax stations are unattended, receive-only broadcast
//     services (coastal marine forecast fax, e.g. NMC/NMG/NOJ, or DWD) --
//     there is nothing to "talk back to" and the old cocoaModem's FAX.swift
//     itself only ever built an rx (FAXReceiver); there is no FAXModulator or
//     equivalent anywhere in the old source. produceTransmitSamples(_:count:)
//     therefore always fills the buffer with silence.
//   - FAX carries a scanned image, not text, so drainReceivedText() always
//     returns "" -- there is no text channel to decode.
//
//  Image-output representation: `receivedImageRows` is a growing, scrolling
//  array of scanlines (`[[Float]]`, brightness 0...1 per pixel), one entry per
//  completed row, in the order FAXPhasingDetector/FAXFrame produced them --
//  this is the natural shape the ported resampler already emits (see
//  FAXFrame.resampledRow(atRow:)), so no reshaping/transposition was needed.
//  Row width is either FAXFrame.fullWidth (1809) or FAXFrame.halfWidth (904)
//  samples depending on setHalfSize(_:) (rows are never mixed widths within
//  one contiguous run; the UI reads `imageWidth` to know which). To bound
//  memory for a long-running receiver, the buffer is capped at
//  maxBufferedRows (2x the original app's MAXFAXHEIGHT); the oldest rows are
//  dropped once exceeded, matching "scrolling" behavior in the original's
//  scrollable image view.
//
import Foundation
import Accelerate

/// A CMPipe whose data stream just points at caller-owned memory -- used to
/// hand a raw 512-sample buffer to FAXReceiver.importData(_:), which expects
/// to pull its input through the CMPipe stream() contract. (Mirrors
/// PSKEngineCore's RawBufferPipe; kept as a private file-scoped copy here
/// since CoreDSP's internal-by-default classes aren't shared across mode
/// facades.)
private final class FAXRawBufferPipe: CMPipe {
    func setBuffer(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        data.pointee.array = buffer
        data.pointee.samples = samples
        data.pointee.channels = 1
    }
}

public final class FAXEngineCore: FAXReceiverDelegate {

    /// Maximum number of scanlines retained in `receivedImageRows` before the oldest are
    /// dropped -- 2x MAXFAXHEIGHT (3200) from the original app's backing-store headroom.
    public static let maxBufferedRows = 6400

    private let receiver = FAXReceiver()
    private let phasing = FAXPhasingDetector()
    private let feedPipe = FAXRawBufferPipe()

    private var rxScratch = [Float](repeating: 0, count: 512)
    private var rxScratchCount = 0

    /// Growing, scrolling buffer of decoded scanlines (brightness 0...1 per pixel). See the
    /// file-level doc comment for the row-width / capping contract.
    public private(set) var receivedImageRows: [[Float]] = []

    /// Current row width in samples: FAXFrame.fullWidth (1809) or FAXFrame.halfWidth (904).
    public var imageWidth: Int {
        phasing.image.halfSize ? FAXFrame.halfWidth : FAXFrame.fullWidth
    }

    public init() {
        receiver.delegate = self
        receiver.enableReceiver(true)
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
                receiver.importData(feedPipe)
                rxScratchCount = 0
            }
        }

        let newRows = phasing.drainRows()
        if !newRows.isEmpty {
            receivedImageRows.append(contentsOf: newRows)
            if receivedImageRows.count > FAXEngineCore.maxBufferedRows {
                receivedImageRows.removeFirst(receivedImageRows.count - FAXEngineCore.maxBufferedRows)
            }
        }
    }

    /// FAX carries a scanned image, not text -- there is no text channel, so this always
    /// returns "" (documented above; present only to give a uniform surface across modes).
    public func drainReceivedText() -> String { "" }

    /// Discards any decoded image rows accumulated so far (e.g. for a "Clear"/"New image" UI action).
    public func clearReceivedImage() {
        receivedImageRows.removeAll()
    }

    /// Manually restart phasing/hsync acquisition (mirrors the original's "New" button); not
    /// required for normal operation since the phasing detector auto-detects image boundaries.
    public func startNewImage() {
        phasing.start()
    }

    public func setHalfSize(_ half: Bool) {
        phasing.setHalfSize(half)
    }

    /// v0.73 850 Hz deviation (DWD stations) vs. the default 400 Hz deviation.
    public func setDeviation850(_ dwd: Bool) {
        phasing.setDeviation(dwd)
    }

    /// A/D sample-clock offset in parts-per-million, for fine image-width correction.
    public func setPPM(_ ppm: Float) {
        phasing.setPPM(ppm)
    }

    public func setGrayscale(black: Float, white: Float) {
        phasing.setGrayscale(from: black, to: white)
    }

    /// Input bandwidth preset: 0 = narrow (480 Hz), 1 = normal (650 Hz, default), 2 = wide (1200 Hz).
    public func setBandwidth(_ index: Int32) {
        receiver.changeBandwidth(to: index)
    }

    // MARK: - TX

    /// HF-FAX is receive-only (see file header) -- there is nothing to transmit, so this
    /// always fills `buffer` with silence.
    public func produceTransmitSamples(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { buffer[i] = 0 }
    }

    /// No-op: HF-FAX has no transmit path (see file header).
    public func queueTransmitText(_ text: String) {}

    // MARK: - FAXReceiverDelegate

    public func faxReceiverDidDemodulate(_ value: Float) {
        phasing.addPixel(value)
    }
}
