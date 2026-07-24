//
//  Spectrum.swift
//  cocoaModem
//
//  Created by Kok Chen on Thu Feb 3 2005.
//  Swift port of Spectrum.m.
//

import Cocoa

@objc(Spectrum)
class Spectrum: NSView {

    //  cached geometry (the ObjC ivar was named `bounds`, which would shadow
    //  NSView.bounds in Swift; use self.bounds directly instead)
    var width: Int32 = 0
    var height: Int32 = 0
    var mux: Int32 = 0
    var plotWidth: Float = 0
    //  C had inline arrays; keep them as explicit heap buffers (ARC does NOT
    //  free C memory, so they are released in deinit).
    let timeStorage = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    let spectrumStorage = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    let smoothedSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    var ySat: Float = 0
    var scale: Float = 0
    var pixPerdB: Float = 0
    var alpha: Float = 0
    var dynamicRangeScale: Float = 0
    var dynamicRangeOffset: Float = 0

    var scaleColor: NSColor!
    var spectrumColor: NSColor!
    var backgroundColor: NSColor!
    var markSpaceColor: NSColor!
    var path: NSBezierPath?
    var background: NSBezierPath!
    var spectrumScale: NSBezierPath!
    var markSpace: NSBezierPath!

    var busy: Bool = false
    var spectrum: UnsafeMutablePointer<CMFFT>!

    var thread: Thread!

    //  ---- helpers ---------------------------------------------------------

    @inline(__always)
    func P(_ x: Float, _ y: Float) -> NSPoint {
        return NSPoint(x: CGFloat(x), y: CGFloat(y))
    }

    //  C truncates a (finite) double toward zero when casting to int.  Guard
    //  NaN/inf so a bad tone-pair value can never trap.
    @inline(__always)
    func iFromD(_ d: Double) -> Int32 {
        if !d.isFinite { return 0 }
        if d >= 2147483647.0 { return Int32.max }
        if d <= -2147483648.0 { return Int32.min }
        return Int32(d)
    }

    //  ---- init ------------------------------------------------------------

    //  spectrum view is 818 wide x 96 tall
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    //  Modern keyed nibs instantiate NSView subclasses through initWithCoder:.
    //  The ObjC original only overrode initWithFrame:, so run the identical
    //  setup here too, keeping the view functional regardless of nib format.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func commonInit() {
        let b = self.bounds
        width = Int32(b.size.width)
        height = Int32(b.size.height)
        plotWidth = 818
        scale = plotWidth / 408
        pixPerdB = 1.25
        mux = 0

        alpha = 1.0
        dynamicRangeScale = 10.0
        dynamicRangeOffset = 56

        for i in 0..<512 { smoothedSpectrum[i] = 0 }

        path = nil
        background = NSBezierPath(rect: b)
        backgroundColor = NSColor(deviceRed: 0, green: 0.1, blue: 0, alpha: 1)

        //  set up spectrum scale
        spectrumColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0, alpha: 1)
        spectrumScale = NSBezierPath()
        spectrumScale.setLineDash([1.0, 2.0], count: 2, phase: 0)
        var i: Int32 = 5
        while i < 80 {
            let y = Float(Int32(Float(height) - Float(i) * pixPerdB)) + 0.5
            if y <= 0 { break }
            spectrumScale.move(to: P(0, y))
            spectrumScale.line(to: P(plotWidth, y))
            i += 30
        }
        i = 500
        while i < 3000 {
            let x = Float(iFromD(Double(i - 400) * Double(plotWidth) / 2200.0)) + 0.5
            spectrumScale.move(to: P(x, 0))
            spectrumScale.line(to: P(x, Float(height)))
            i += 500
        }
        //  set up scale color
        scaleColor = NSColor(calibratedRed: 0, green: 1, blue: 0.1, alpha: 1)

        //  set up mark/space scales
        markSpaceColor = NSColor(calibratedRed: 0.88, green: 0.15, blue: 0, alpha: 1)
        markSpace = NSBezierPath()
        var x = Float(iFromD(Double(2125 - 400) * Double(plotWidth) / 2200.0)) + 0.5
        markSpace.move(to: P(x, 8))
        markSpace.line(to: P(x, Float(height) - 10))
        x = Float(iFromD(Double(2295 - 400) * Double(plotWidth) / 2200.0)) + 0.5
        markSpace.move(to: P(x, 8))
        markSpace.line(to: P(x, Float(height) - 10))

        //  initialize spectrum fft (use vDSP)
        spectrum = FFTSpectrum(11, true)
        busy = false

        thread = Thread.current
    }

    deinit {
        timeStorage.deallocate()
        spectrumStorage.deallocate()
        smoothedSpectrum.deallocate()
    }

    override var isOpaque: Bool { return true }

    @objc(setTimeConstant:dynamicRange:)
    func setTimeConstant(_ t: Float, dynamicRange dr: Float) {
        alpha = (t > 0) ? 0.186 / t : 1.0
        dynamicRangeScale = 10.0 * 60.0 / dr
        dynamicRangeOffset = 56 + (60 - dr) * dr / 60.0
    }

    //  local
    @objc func displayInMainThread() {
        needsDisplay = true
    }

    @objc func clearPlot() {
        path = nil
        perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        if thread === Thread.current && lockFocusIfCanDraw() {
            //  clear background
            backgroundColor.set()
            background.fill()
            //  insert scale
            scaleColor.set()
            spectrumScale.stroke()
            //  mark/space scale
            markSpaceColor.set()
            markSpace.stroke()
            //  insert graph
            if let path = path {
                spectrumColor.set()
                path.stroke()
            }
            unlockFocus()
        }
    }

    /* local */
    func newSpectrum(_ stream: UnsafeMutablePointer<CMDataStream>) {
        guard let inArray = stream.pointee.array else { return }

        //  collect 4096 samples at 11025 s/s before processing spectrum
        for i in 0..<512 { timeStorage[Int(mux) + i] = inArray[i] }
        mux += stream.pointee.samples
        if mux >= 2048 {
            mux = 0

            CMPerformFFT(spectrum, timeStorage, spectrumStorage)

            //  left side of plot is 400 Hz, right side is 2600 Hz
            for i in 0..<408 {
                smoothedSpectrum[i] = smoothedSpectrum[i] * (1 - alpha) + spectrumStorage[i + 74] * alpha
            }

            let newPath = NSBezierPath()
            newPath.lineWidth = 0.75

            let h = Float(height)
            var pen = false
            for i in 0..<408 {
                //  smoothedSpectrum[i] is a power (>= 0); log10(0) is -inf, which
                //  yields a non-finite y.  The pen logic below never feeds a
                //  non-finite value to NSBezierPath.
                let db = Float(Double(dynamicRangeScale) * (log10(Double(smoothedSpectrum[i])) - 5.8))
                let x = Float(i) * scale
                let y = h + db * pixPerdB
                if pen {
                    //  pen in down state
                    if y >= 0 && y < h {
                        newPath.line(to: P(x, y))
                    } else {
                        if y < 0 {
                            newPath.line(to: P(x, 0.0))
                            ySat = 0.0
                        } else {
                            newPath.line(to: P(x, h - 1))
                            ySat = h - 1
                        }
                        pen = false
                    }
                } else {
                    //  pen was in up state
                    if y >= 0 && y < h {
                        if i == 0 {
                            newPath.move(to: P(x, y))
                        } else {
                            newPath.move(to: P(x - 1, ySat))
                            newPath.line(to: P(x, y))
                        }
                        pen = true
                    } else {
                        ySat = (y < 0) ? 0.0 : h - 1
                    }
                }
            }
            path = newPath
            perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
        }
    }

    //  set Mark to zero to disable
    @objc(setTonePairMarker:)
    func setTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>) {
        //  left side of plot is 400 Hz
        let m = iFromD((tonepair.pointee.mark - 400) / 2200.0 * Double(plotWidth) + 0.5)
        let s = iFromD((tonepair.pointee.space - 400) / 2200.0 * Double(plotWidth) + 0.5)

        markSpace = NSBezierPath()
        markSpace.lineWidth = 0.5
        var x = Float(m) + 0.5
        markSpace.move(to: P(x, 10))
        markSpace.line(to: P(x, Float(height) - 10))
        x = Float(s) + 0.5
        markSpace.move(to: P(x, 10))
        markSpace.line(to: P(x, Float(height) - 10))

        perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
    }

    @objc(addData:)
    func addData(_ stream: UnsafeMutablePointer<CMDataStream>) {
        if busy { return }

        busy = true
        newSpectrum(stream)
        busy = false
    }
}
