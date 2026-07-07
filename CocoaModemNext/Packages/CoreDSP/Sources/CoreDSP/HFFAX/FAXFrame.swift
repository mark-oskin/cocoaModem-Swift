//
//  FAXFrame.swift
//  CoreDSP
//
//  Swift port of the DSP-relevant half of FAXFrame.m/.swift (old cocoaModem).
//  FAXFrame owns the "backing store": a large circular byte buffer holding
//  one raw (0...255) brightness sample per input audio sample, exactly as
//  FAXReceiver/addPixel produced it, plus a 256-entry grayscale lookup table
//  (black level / contrast). Its job is to resample a completed scanline out
//  of that oversampled backing store down to a fixed-width row of pixels.
//
//  Everything UI-coupled in the original -- NSImage / NSBitmapImageRep /
//  scrolling / PDF export / mouse handling -- is dropped entirely.
//  `resampledRow(atRow:)` returns a plain `[Float]` (brightness 0...1) instead
//  of writing into a bitmap; FAXEngineCore collects these into the public
//  image-row buffer the UI observes.
//
//  Fidelity notes:
//   - The resampling math (nearest-neighbor decimation for full-size, the
//     "Hamming window the fast scan direction" 2-row average for half-size)
//     is transplanted verbatim from -drawLineAtRow:, including the exact
//     magic constants (2.348, 8.696) from the original weighted average.
//   - -setSamplingParameters hardcodes IOC to 576 in the original ("fix IOC
//     to 576 for now") and the scanline loop bounds in -drawLineAtRow: (1809
//     full-size / 1808 half-size) are likewise hardcoded rather than derived
//     from `actualWidth` -- both quirks are preserved here rather than
//     "fixed", per the port's mechanical-conversion rules.
//   - modPos/cInt/dInt are the same guarded/wrapping helpers used elsewhere
//     in this port (see FAXFrame.m's originals); backingByte/intensityByte
//     always wrap or clamp so a bad decimation value can never index out of
//     bounds, matching the original's stated invariant.
//

import Foundation

final class FAXFrame {

    /// Fixed output row width in full-size mode (IOC=576 => 1809 samples/line, matching -drawLineAtRow:'s hardcoded loop bound).
    static let fullWidth = 1809
    /// Fixed output row width in half-size mode (1808 input columns averaged 2-at-a-time => 904 output samples).
    static let halfWidth = 904

    private(set) var frame = BackingFrame()

    //  raw oversampled brightness bytes (addPixel appends here), circular over kFAXMaxBacking samples
    private let backing: UnsafeMutablePointer<UInt8>
    //  256-entry grayscale lookup table (recomputed whenever black level / contrast changes)
    private let intensity: UnsafeMutablePointer<UInt8>

    private(set) var halfSize: Bool = true

    //  resampling by 11025/(IOC*pi*2) nominal decimation -- recomputed by setSamplingParameters()
    private var IOC: Int32 = 576
    private var imageWidth: Float = 0
    private var actualWidth: Int32 = 0
    private(set) var decimationRatio: Float = 1
    private var inputImageWidth: Float = 0
    private var ppm: Float = 0

    init() {
        backing = UnsafeMutablePointer<UInt8>.allocate(capacity: kFAXMaxBacking)
        backing.initialize(repeating: 0, count: kFAXMaxBacking)
        intensity = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        intensity.initialize(repeating: 0, count: 256)
        frame.halfSize = true

        //  nominal black=32, contrast=192 -- the defaults FAXDisplay.init used
        setGrayscale(from: 32, to: 32 + 192)
        setSamplingParameters()
    }

    deinit {
        backing.deallocate()
        intensity.deallocate()
    }

    // ---- guarded conversions / index helpers (verbatim from FAXFrame.swift) ----

    @inline(__always) private func cInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int32.max }
        if t <= -2147483648.0 { return Int32.min }
        return Int32(t)
    }

    @inline(__always) private func cInt(_ x: Double) -> Int32 {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int32.max }
        if t <= -2147483648.0 { return Int32.min }
        return Int32(t)
    }

    @inline(__always) private func dInt(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 9.0e18 { return Int.max }
        if t <= -9.0e18 { return Int.min }
        return Int(t)
    }

    @inline(__always) private func modPos(_ x: Int, _ m: Int) -> Int {
        let r = x % m
        return r < 0 ? r + m : r
    }

    @inline(__always) private func backingByte(_ i: Int) -> UInt8 {
        backing[modPos(i, kFAXMaxBacking)]
    }

    @inline(__always) private func intensityByte(_ i: Int) -> UInt8 {
        var j = i
        if j < 0 { j = 0 } else if j > 255 { j = 255 }
        return intensity[j]
    }

    // ---- frame lifecycle ----

    func resetFrame() {
        frame.displayRow = 0
        frame.origin = 0
        frame.input = 0
        frame.mark = 0
        frame.correction = 0.0
    }

    /// Position frame parameters to the start of a new image (mirrors -startNewImage).
    func startNewImage() {
        frame.origin = (frame.horizontalOffset &+ frameOffsetForSample(0, ofRow: frame.displayRow)) % Int32(kFAXMaxBacking)
        frame.displayRow = 0
        frame.skipRow = 0
        frame.input = 0
        //  trigger point for dumping row
        frame.mark = frameOffsetForSample(2, ofRow: frame.displayRow &+ 1)
    }

    func setHalfSize(_ isHalfSize: Bool) {
        frame.halfSize = isHalfSize
        halfSize = isHalfSize
    }

    /// Create a grayscale table (recomputed each time black level / contrast changes).
    func setGrayscale(from black: Float, to white: Float) {
        let range = white - black
        for i in 0..<256 {
            var v = cInt((Float(i) - black) * 256.0 / range)
            if v < 0 { v = 0 } else if v > 255 { v = 255 }
            intensity[i] = UInt8(v)
        }
    }

    func setPPM(_ p: Float) {
        ppm = p
    }

    /// Change decimation ratio and fractional width of the FAX transmission.
    func setSamplingParameters() {
        IOC = 576                                        //  fixed IOC to 576 for now (preserved from the original)
        imageWidth = Float(Double(IOC) * 3.1415926)       //  fractional width
        actualWidth = cInt(imageWidth)                    //  integral width (informational only -- see file header note)
        decimationRatio = Float((11025.0 / (Double(IOC) * 3.1415926535 * 2)) * (1.0 + Double(ppm) / 1_000_000.0))
        inputImageWidth = imageWidth * decimationRatio    //  actual 1/2 second of data
    }

    // ---- backing store ----

    /// Appends one raw (already 0...255-scaled) demodulated sample into the backing store.
    func addPixel(_ v: Int32) {
        let index = Int((frame.origin &+ frame.input) % Int32(kFAXMaxBacking))
        backing[modPos(index, kFAXMaxBacking)] = UInt8(truncatingIfNeeded: v)
        frame.input = frame.input &+ 1
    }

    func passedMark() -> Bool {
        frame.input > frame.mark
    }

    func frameOffsetForSample(_ h: Int32, ofRow v: Int32) -> Int32 {
        cInt((Double(h) + Double(frame.horizontalOffset)) * Double(decimationRatio) + Double(v) * Double(inputImageWidth) + 0.5)
    }

    func setHorizontalOffset(_ position: Int32) {
        frame.horizontalOffset = frame.horizontalOffset &+ cInt(Float(position) / decimationRatio)
        frame.horizontalOffset %= 1809
        frame.skipRow = frame.displayRow
    }

    func setFrameMark(_ offset: Int32) {
        frame.mark = frameOffsetForSample(1, ofRow: frame.displayRow &+ offset)
    }

    func markDisplayRow() {
        frame.rows = frame.displayRow
    }

    /// Advances displayRow and returns the row index that was just completed (mirrors -drawLineAndAdvanceRow's row bookkeeping half).
    @discardableResult
    func advanceDisplayRow() -> Int32 {
        let row = frame.displayRow
        frame.displayRow = row &+ 1
        return row
    }

    /// Reads `count` raw backing-store bytes starting at a circular offset -- used by the
    /// hsync/vsync correlators (FAXPhasingDetector), which in the original read directly
    /// through the C `backing` pointer. Always wraps (via modPos), which is stricter than
    /// the original's occasional un-wrapped pointer arithmetic right at the buffer boundary.
    func rawWindow(startingAtCircularOffset offset: Int, count: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = backing[modPos(offset + i, kFAXMaxBacking)]
        }
        return result
    }

    // ---- resampling (mirrors -drawLineAtRow:, minus the NSBitmapImageRep write) ----

    /// Resample a completed scanline into a fixed-width row of brightness values (0...1).
    /// Returns nil for even rows in half-size mode (the original only produces output on
    /// odd rows there, averaging it with the previous scanline).
    func resampledRow(atRow row: Int32) -> [Float]? {
        if halfSize {
            if (row & 1) == 0 { return nil }

            let previousRow = row &- 1
            var out = [Float](repeating: 0, count: FAXFrame.halfWidth)

            let p = Double(frame.origin) + Double(frame.horizontalOffset) * Double(decimationRatio) + 0.5
            var p0 = p + Double(row) * Double(inputImageWidth)
            var p1 = p + Double(previousRow) * Double(inputImageWidth)

            var idx = 0
            var i = 0
            while i < 1808 {
                if i == 0 || i == 1806 {
                    //  nearest neighbor average for first and last sample of scanline
                    var avg = Int(backingByte(dInt(p0))) + Int(backingByte(dInt(p1)))
                    p0 += Double(decimationRatio); p1 += Double(decimationRatio)
                    avg += Int(backingByte(dInt(p0))) + Int(backingByte(dInt(p1)))
                    out[idx] = Float(intensityByte(avg / 4)) / 255.0
                } else {
                    //  Hamming window the fast scan direction
                    var sum = Double(backingByte(dInt(p0))) + Double(backingByte(dInt(p1)))
                    p0 += Double(decimationRatio); p1 += Double(decimationRatio)
                    sum += (Double(backingByte(dInt(p0))) + Double(backingByte(dInt(p1)))) * 2.348
                    p0 += Double(decimationRatio); p1 += Double(decimationRatio)
                    sum += Double(backingByte(dInt(p0))) + Double(backingByte(dInt(p1)))
                    let avg = dInt((sum + 0.5) / 8.696)
                    out[idx] = Float(intensityByte(avg)) / 255.0
                }
                idx += 1
                i += 2
            }
            return out
        } else {
            var out = [Float](repeating: 0, count: FAXFrame.fullWidth)
            var p0 = Double(frame.origin) + Double(frame.horizontalOffset) * Double(decimationRatio) + Double(row) * Double(inputImageWidth) + 0.5

            for idx in 0..<FAXFrame.fullWidth {
                let avg = Int(backingByte(dInt(p0)))
                p0 += Double(decimationRatio)
                out[idx] = Float(intensityByte(avg)) / 255.0
            }
            return out
        }
    }
}
