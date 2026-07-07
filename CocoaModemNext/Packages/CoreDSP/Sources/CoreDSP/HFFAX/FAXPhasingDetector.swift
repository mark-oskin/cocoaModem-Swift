//
//  FAXPhasingDetector.swift
//  CoreDSP
//
//  Swift port of the DSP/state-machine half of FAXDisplay.m/.swift (old
//  cocoaModem's HF-FAX receive view). FAXDisplay was an NSImageView subclass
//  mixing real DSP (phasing/sync detection) with a lot of AppKit UI
//  (scroller, NSColor run-light, PDF export, mouse handling). This class
//  keeps only the DSP: it owns a FAXFrame backing store, appends each
//  demodulated sample from FAXReceiver into it, and runs the two
//  correlators the original used to find a picture in the stream:
//
//   1. Coarse "phasing" detection (-findVSync / the vsync state machine):
//      IOC-576 stations send a steady 300 Hz tone before a picture starts and
//      a 450 Hz tone when it ends; -findVSync cross-correlates a shifted copy
//      of the backing store (to confirm a periodic tone at all) and then uses
//      Goertzel power at 300/450 Hz to tell start from stop.
//   2. Horizontal sync (-findHSyncAtRow / -checkSyncBuffer): once phasing
//      says a picture has started, a boxcar-filtered cross-correlation over
//      the first 32 scanlines locks the horizontal (left-edge) offset.
//
//  All AppKit-coupled pieces are gone (NSColor run-light, NSSlider scroller,
//  PDF dump-to-folder, mouse positioning); "Auto Start/Stop" -- a checkbox in
//  the original UI that gated the automatic phasing/hsync state transitions
//  -- is hardcoded permanently on here, since a headless receive engine has
//  no manual "click New to start a picture" affordance and should always try
//  to auto-detect image boundaries.
//
//  Fidelity notes: the vsync state machine's states/transitions, the boxcar
//  sync-buffer correlator (including its wrapping &+/&- arithmetic), and the
//  Goertzel tone detector are all transplanted verbatim. VSYNCCHECK (state 2
//  in the original #defines) was declared but never assigned/read anywhere in
//  -outputLine's switch -- it is dead code in the original and is dropped
//  here rather than carried forward as an unreachable enum case.
//

import Foundation

final class FAXPhasingDetector {

    /// The image being decoded. FAXEngineCore drains completed rows via `completedRows`/`drainRows()`.
    let image = FAXFrame()

    private enum SyncState {
        case wait, starting, endPause, startWait
    }

    private let goertzelWindow: UnsafeMutablePointer<Float>
    private let startTone: Float
    private let stopTone: Float

    private var dev850 = false

    private var running = true
    private var paused = false
    private var state: SyncState = .wait
    private var pauseCount: Int32 = 0
    private var linesFromTop: Int32 = 5000
    private var sync: Float = 0

    //  boxcar/correlator accumulator -- exact int[5512+129] C buffer from the original,
    //  using the same wrapping (&+/&-) Int32 arithmetic so it overflows identically.
    private let syncBuffer: UnsafeMutablePointer<Int32> = {
        let p = UnsafeMutablePointer<Int32>.allocate(capacity: 5512 + 129)
        p.initialize(repeating: 0, count: 5512 + 129)
        return p
    }()

    private var imageParametersChanged = false

    /// Completed, resampled scanlines (brightness 0...1) produced since the last drainRows().
    private(set) var completedRows: [[Float]] = []

    init() {
        goertzelWindow = CMMakeBlackmanWindow(256)
        startTone = Float(cos(2.0 * 3.1415926535 / CMFs * 300.0))
        stopTone = Float(cos(2.0 * 3.1415926535 / CMFs * 450.0))
        start()
    }

    deinit {
        syncBuffer.deallocate()
    }

    @inline(__always) private func cTruncInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int32.max }
        if t <= -2147483648.0 { return Int32.min }
        return Int32(t)
    }

    // MARK: - configuration

    /// v0.73 850 Hz deviation (DWD) vs. the default 400 Hz deviation scaling.
    func setDeviation(_ dwd: Bool) {
        dev850 = dwd
    }

    func setHalfSize(_ half: Bool) {
        image.setHalfSize(half)
    }

    func setPPM(_ ppm: Float) {
        image.setPPM(ppm)
        imageParametersChanged = true
    }

    func setGrayscale(from black: Float, to white: Float) {
        image.setGrayscale(from: black, to: white)
    }

    /// Reset and begin looking for a new picture (mirrors FAXDisplay.start()/the "New" button).
    func start() {
        image.startNewImage()
        sync = 0.0
        running = true
        paused = false
        if state == .startWait { state = .wait }
    }

    // MARK: - Goertzel / vsync (ported from FAXDisplay)

    private func goertzel(_ x: [UInt8], tone s: Float) -> Float {
        var d0: Float = 0, d1: Float = 0, d2: Float
        for i in 0..<256 {
            d2 = d1
            d1 = d0
            d0 = 2 * s * d1 - d2 + goertzelWindow[i] * Float(Int(x[i]) - 128)
        }
        return d0 * d0 + d1 * d1 - 2 * s * d0 * d1
    }

    private func findVSync(_ array: [UInt8]) -> Float {
        //  cross correlate with shifted data (for multiple of 75 Hz tones)
        var r: Float = 0
        var d1: Float = 0.1, d2: Float = 0.1
        for i in 0..<256 {
            let x1 = Float(Int(array[i]) - 128)
            let x2 = Float(Int(array[i + 294]) - 128)
            r += x1 * x2
            d1 += x1 * x1
            d2 += x2 * x2
        }
        r = abs(r / (d1 * d2).squareRoot())

        if r < 0.8 { return 0 }

        let startPower = goertzel(array, tone: startTone)
        let stopPower = goertzel(array, tone: stopTone)

        var sum: Float = 0
        for i in 0..<256 {
            let x1 = Float(Int(array[i]) - 128)
            sum += x1 * x1
        }
        sum *= 7

        r = ((stopPower > startPower) ? -stopPower : startPower) / sum
        return r
    }

    private func findHSyncAtRow(_ v: Int32) {
        let offset = Int(image.frame.origin) + Int(image.frameOffsetForSample(0, ofRow: v))
        let window = image.rawWindow(startingAtCircularOffset: offset, count: 5512)
        for i in 0..<5512 {
            syncBuffer[i] = syncBuffer[i] &+ (Int32(window[i]) &- 128)
        }
    }

    private func checkSyncBuffer() {
        //  first extend the buffer to emulate a circular buffer
        for i in 0..<129 { syncBuffer[i + 5512] = syncBuffer[i] }

        //  init boxcar filter
        var sum1: Int32 = 0, sum2: Int32 = 0
        for i in 0..<64 {
            sum1 = sum1 &+ syncBuffer[i]
            sum2 = sum2 &+ syncBuffer[i + 64]
        }
        //  boxcar filter
        var peak = sum2 &- sum1
        for i in 0..<5512 {
            let tap = syncBuffer[i + 64]
            sum1 = sum1 &+ (tap &- syncBuffer[i])
            sum2 = sum2 &+ (syncBuffer[i + 128] &- tap)      //  v0.26 bug fix
            let v = sum1 &- sum2
            if v > peak { peak = v }
        }

        if peak < 2000 { return }       //  probably not a sync pulse

        //  position is where the correlation peaks
        for i in 0..<5512 {
            if syncBuffer[i + 1] < 0 && syncBuffer[i] >= 0 {
                image.setHorizontalOffset(Int32(i))
                return
            }
        }
    }

    //  (stop signal) -> endPause -> wait -> (start signal) -> starting
    //   -> (start signal goes away) -> wait
    private func outputLine() {
        //  new line received: look for sync at different locations on the scanline to avoid
        //  false positives. Each scanline is 0.5 s long and has 11025/2 samples. Uses a slow
        //  attack fast decay decoder.
        if state == .wait || state == .starting || state == .startWait {
            let random = (image.frame.input & 0x7) &* 500
            let syncIndex = (image.frame.origin &+ image.frame.input &- 5000 &+ random) % Int32(kFAXMaxBacking)
            let window = image.rawWindow(startingAtCircularOffset: Int(syncIndex), count: 256 + 294)
            let newsync = findVSync(window)
            sync = (newsync < sync) ? (sync * 0.3 + 0.7 * newsync) : (sync * 0.7 + 0.3 * newsync)
        }

        switch state {
        case .starting:
            if sync < 0.40 {
                linesFromTop = 0
                sync = 0.0
                for i in 0..<5510 { syncBuffer[i] = 0 }
                state = .wait
                start()
            }
        case .endPause:
            //  pause after a STOP signal before waiting for START
            pauseCount &+= 1
            if pauseCount > 10 {
                paused = true
                state = .startWait
                sync = 0.0
            }
        case .startWait:
            if sync > 0.8 { state = .starting }
        case .wait:
            linesFromTop &+= 1
            if linesFromTop > 10 && linesFromTop <= 32 {
                //  look for hsync
                findHSyncAtRow(image.frame.displayRow)
                if linesFromTop == 32 {
                    checkSyncBuffer()
                }
            }
            if sync > 0.8 {
                //  saw individual (not after stop) start signal -- auto mode is always on here
                state = .starting
            } else if sync < -0.8 {
                //  saw stop signal -- auto mode is always on here
                pauseCount = 0
                state = .endPause
                image.markDisplayRow()
            }
        }

        //  update the scanline touched since the last call
        if state == .wait && !paused {
            let row = image.advanceDisplayRow()
            if row >= image.frame.skipRow, let resampled = image.resampledRow(atRow: row) {
                completedRows.append(resampled)
            }
            image.setFrameMark(1)
        }
    }

    //  Data sample received from FAXReceiver. Received values are bi-polar, black about -0.23
    //  and white about +0.23 (-.244 to +.244 for DWD). Stored into the backing buffer as an
    //  8-bit value, with black at level ~16 and white at level ~240 on a 0-255 scale.
    func addPixel(_ value: Float) {
        let f: Float = dev850 ? (value + 0.279) * 459 : (value + 0.263) * 485
        var v = cTruncInt(f)
        if v < 0 { v = 0 } else if v > 255 { v = 255 }

        image.addPixel(v)

        if !running { return }

        if imageParametersChanged {
            image.setSamplingParameters()
            imageParametersChanged = false
        }
        if image.passedMark() {
            outputLine()
        }
    }

    /// Drain rows completed since the last call.
    func drainRows() -> [[Float]] {
        guard !completedRows.isEmpty else { return [] }
        let rows = completedRows
        completedRows.removeAll(keepingCapacity: true)
        return rows
    }
}
