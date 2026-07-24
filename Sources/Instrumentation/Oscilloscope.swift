//
//  Oscilloscope.swift
//  cocoaModem
//
//  Created by Kok Chen on Fri May 21 2004.
//  Swift port of Oscilloscope.m.
//

import Cocoa

@objc(Oscilloscope)
class Oscilloscope: NSView {

    private static let pixPerdB: Int32 = 3
    private static let timeConstants: [Float] = [0.0, 0.2, 0.5, 1.5, 4.0]

    @objc var averageButton: NSButton!
    @objc var averagePopupMenu: NSPopUpButton!
    @objc var baselineButton: NSButton!

    var width: Int32 = 0
    var height: Int32 = 0
    var style: Int32 = 0
    var mux: Int32 = 0
    var plotWidth: Int32 = 0
    var plotOffset: Int32 = 0
    //  C inline arrays kept as explicit heap buffers (freed in deinit).
    let scopeFilter = UnsafeMutablePointer<Float>.allocate(capacity: 192)
    let timeStorage = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let spectrumStorage = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let spectrumAverage = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    var ySat: Float = 0
    var baseline: Float = 1.0        //  for average spectrum baseline equalization
    var timebase: Int32 = 0
    var alpha: Float = 1.0
    var doBaseline: Bool = false

    var plotColor: NSColor!
    var scaleColor: NSColor!
    var waveformColor: NSColor!
    var spectrumColor: NSColor!
    var backgroundColor: NSColor!
    var markSpaceColor: NSColor!
    var path: NSBezierPath?
    var path2: NSBezierPath?
    var scale: NSBezierPath!
    var background: NSBezierPath!
    var waveformScale: NSBezierPath!
    var spectrumScale: NSBezierPath!
    var markSpace: NSBezierPath!
    var baudot: NSBezierPath!
    var pathLock: NSLock!
    var drawLock: NSLock!

    var busy: Bool = false
    var enableMarkSpace: Bool = false
    var enableBaudot: Bool = false

    //  CMFIR / CMFFT buffers are owned by CoreFilter; the ObjC original never
    //  freed them (no dealloc), so neither do we — they live for the app.
    var interpolateBy8 = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 2)
    var interpolateBy2 = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 2)

    var spectrum: UnsafeMutablePointer<CMFFT>!

    var thread: Thread!

    //  ---- helpers ---------------------------------------------------------

    @inline(__always)
    private func P(_ x: Float, _ y: Float) -> NSPoint {
        return NSPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private func setInterface(_ object: NSControl, to selector: Selector) {
        object.action = selector
        object.target = self
    }

    //  ---- init ------------------------------------------------------------

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
        plotWidth = 512
        plotOffset = 4
        mux = 0
        doBaseline = false
        baseline = 1.0
        alpha = 1.0

        path = nil
        path2 = nil
        markSpace = nil
        pathLock = NSLock()
        drawLock = NSLock()
        background = NSBezierPath(rect: b)
        backgroundColor = NSColor(deviceRed: 0, green: 0.1, blue: 0, alpha: 1)

        let h = Float(height)

        //  set up spectrum scale
        spectrumColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0, alpha: 1)
        spectrumScale = NSBezierPath()
        spectrumScale.setLineDash([1.0, 2.0], count: 2, phase: 0)
        var i: Int32 = 5
        while i < 106 {
            let y = h - Float(i * Oscilloscope.pixPerdB) + 0.5
            if y <= 0 { break }
            spectrumScale.move(to: P(Float(plotOffset), y))
            spectrumScale.line(to: P(Float(plotWidth + plotOffset), y))
            i += 20
        }
        i = 500
        while i < 3000 {
            let x = 4.5 + Float(Int32(Double(i) * 512.0 / 2756.25))
            spectrumScale.move(to: P(x, 0))
            spectrumScale.line(to: P(x, h))
            i += 500
        }

        //  set up waveform scale
        waveformColor = NSColor(calibratedRed: 0, green: 1, blue: 0.1, alpha: 1)
        waveformScale = NSBezierPath()
        waveformScale.setLineDash([1.0, 1.0], count: 2, phase: 0)
        var y = Float(height / 2) + 0.5
        waveformScale.move(to: P(Float(plotOffset), y))
        waveformScale.line(to: P(Float(plotWidth + plotOffset), y))
        y = Float(Int32(h * 0.125)) + 0.5
        waveformScale.move(to: P(Float(plotOffset), y))
        waveformScale.line(to: P(Float(plotWidth + plotOffset), y))
        y = Float(Int32(h * 0.875)) + 0.5
        waveformScale.move(to: P(Float(plotOffset), y))
        waveformScale.line(to: P(Float(plotWidth + plotOffset), y))

        //  set up mark/space scales
        markSpaceColor = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        markSpace = NSBezierPath()
        markSpace.setLineDash([1.0, 1.0], count: 2, phase: 0)
        var x: Float = 200.5
        markSpace.move(to: P(x, 10))
        markSpace.line(to: P(x, h - 10))
        x = 300.5
        markSpace.move(to: P(x, 10))
        markSpace.line(to: P(x, h - 10))
        enableMarkSpace = false

        baudot = NSBezierPath()
        for k in 1..<8 {
            let bx = Float(plotOffset) + Float(Int32(Double(k) * 30.32 * 2)) + 0.5
            baudot.move(to: P(bx, 10))
            baudot.line(to: P(bx, h - 10))
        }
        enableBaudot = false

        //  initial display style (spectrum)
        setDisplayStyle(0, plotColor: nil)

        //  initialize interpolation filters
        var s: Float = 0.0
        for k in 0..<192 {
            let hh = Float(CMSinc(Int32(k), 192, 16 /*12*/) * CMBlackmanWindow(Int32(k), 192))
            scopeFilter[k] = hh
            s += hh
        }
        s = 1.0 / s
        for k in 0..<192 { scopeFilter[k] *= s }

        for k in 0..<2 {
            //  filters for one of each of 2 channels
            interpolateBy8[k] = CMFIRInterpolate(8, scopeFilter, 192 / 8)
            interpolateBy2[k] = CMFIRInterpolate(2, scopeFilter, 192 / 2)
        }

        for k in 0..<2048 { spectrumAverage[k] = 0.0 }
        //  initialize spectrum fft (use vDSP)
        spectrum = FFTSpectrum(11, true)
        busy = false

        thread = Thread.current
    }

    deinit {
        scopeFilter.deallocate()
        timeStorage.deallocate()
        spectrumStorage.deallocate()
        spectrumAverage.deallocate()
    }

    override func awakeFromNib() {
        if let b = averageButton { setInterface(b, to: #selector(averageButtonChanged)) }
        if let m = averagePopupMenu { setInterface(m, to: #selector(averageMenuChanged)) }
        if let bl = baselineButton {
            setInterface(bl, to: #selector(baselineButtonChanged))
            bl.isEnabled = false
        }
    }

    @objc func averageButtonChanged() {
        if let b = averageButton, b.state == .on {
            alpha = 0.186 / 0.5
            baselineButton?.isEnabled = true
            return
        }
        alpha = 1.0
        baselineButton?.isEnabled = false
    }

    //  v0.64c allows Lite window to change the time constant
    @objc(selectTimeConstant:)
    func selectTimeConstant(_ n: Int32) {
        let tc = Oscilloscope.timeConstants[Int(n)]
        alpha = (tc > 0) ? 0.186 / tc : 1.0
    }

    @objc func averageMenuChanged() {
        if let m = averagePopupMenu {
            let t = Int32(m.indexOfSelectedItem)
            let tc = Oscilloscope.timeConstants[Int(t)]     //  v0.65 bug fix (copied, not moved)
            alpha = (tc > 0) ? 0.186 / tc : 1.0             //  v0.65 bug fix
            baselineButton?.isEnabled = (t > 0)
        }
    }

    @objc func baselineButtonChanged() {
        doBaseline = (baselineButton?.state == .on)
    }

    override var isOpaque: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        if pathLock.try() {
            //  clear background
            backgroundColor.set()
            background.fill()
            //  insert scale
            scaleColor.set()
            scale.stroke()
            //  mark/space scale
            if style == 0 && enableMarkSpace {
                markSpaceColor.set()
                markSpace.stroke()
            }
            //  baudot bit markers (30.32*2 pixels apart)
            if style == 1 && enableBaudot {
                markSpaceColor.set()
                baudot.stroke()
            }
            //  insert graph
            if let path = path {
                plotColor.set()
                path.stroke()
            }
            if let path2 = path2 {
                plotColor.set()
                path2.stroke()
            }
            pathLock.unlock()
        }
    }

    //  local
    @objc func displayInMainThread() {
        needsDisplay = true
    }

    /* local */
    func newWaveform(_ stream: UnsafeMutablePointer<CMDataStream>) {
        guard let inArray = stream.pointee.array else { return }

        let channels = stream.pointee.channels
        let channelOffset = Int(stream.pointee.samples)
        var plotSamples = plotWidth
        var xgain: Float = 1.0

        let output1 = UnsafeMutablePointer<Float>.allocate(capacity: 512 * 8)
        let output2 = UnsafeMutablePointer<Float>.allocate(capacity: 512 * 8)
        defer { output1.deallocate(); output2.deallocate() }

        var syncd: UnsafeMutablePointer<Float>
        var synce: UnsafeMutablePointer<Float>

        if timebase <= 1 {
            //  interpolate
            CMPerformFIR(interpolateBy8[0], inArray, plotWidth, output1)
            if channels > 1 { CMPerformFIR(interpolateBy8[1], inArray + channelOffset, plotWidth, output2) }

            //  for timebase == 1, display once each 4 frames
            let count = mux
            mux += 1
            if count < 3 { return }

            mux = 0
            //  find the best zero crossing to use as start of a waveform
            var w: Float = 1.0
            var synci = 16
            var u = output1[synci]
            var i = synci
            while i < 1000 {
                let v = output1[i]
                if u < 0 && v >= 0 && v < w {
                    w = v
                    synci = i
                }
                u = v
                i += 1
            }
            syncd = output1 + synci
            synce = output2 + synci
        } else {
            if timebase <= 4 {
                CMPerformFIR(interpolateBy2[0], inArray, stream.pointee.samples, output1)
                if channels > 1 { CMPerformFIR(interpolateBy2[1], inArray + channelOffset, stream.pointee.samples, output2) }
                syncd = output1
                synce = output2
            } else {
                //  no filtering if timebase >= 8, stretch plot to cover x scale
                plotSamples = stream.pointee.samples
                if plotSamples > plotWidth { plotSamples = plotWidth }
                xgain = Float(plotWidth) / Float(plotSamples)
                syncd = inArray
                synce = inArray + 512
            }
        }
        //  create new plot
        let yoffset = Float(height / 2)
        let ygain = -yoffset * 0.75
        let h = Float(height)

        let newPath = NSBezierPath()
        for i in 0..<Int(plotSamples) {
            let x = Float(plotOffset) + Float(i) * xgain
            var y = yoffset - syncd[i] * ygain
            if !y.isFinite { y = yoffset }
            if y >= h { y = h - 1 } else if y < 0 { y = 0 }
            if i == 0 { newPath.move(to: P(x, y)) } else { newPath.line(to: P(x, y)) }
        }
        path = newPath

        path2 = nil
        if channels > 1 {
            let p2 = NSBezierPath()
            for i in 0..<Int(plotSamples) {
                let x = Float(plotOffset) + Float(i) * xgain
                var y = yoffset - synce[i] * ygain
                if !y.isFinite { y = yoffset }
                if y >= h { y = h - 1 } else if y < 0 { y = 0 }
                if i == 0 { p2.move(to: P(x, y)) } else { p2.line(to: P(x, y)) }
            }
            path2 = p2
        }
        perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
    }

    /* local */
    func newSpectrum(_ stream: UnsafeMutablePointer<CMDataStream>) {
        guard let inArray = stream.pointee.array else {
            NSLog("Oscilloscope - no spectral data?\n")
            return
        }

        //  collect 4096 samples at 11025 s/s before processing spectrum
        for i in 0..<Int(plotWidth) { timeStorage[Int(mux) + i] = inArray[i] }
        mux += stream.pointee.samples
        if mux >= 4096 {
            mux = 0

            //  take average of 2 power spectra
            CMPerformFFT(spectrum, timeStorage, spectrumStorage)
            CMPerformFFT(spectrum, timeStorage + 2048, spectrumStorage + 2048)

            path2 = nil
            let newPath = NSBezierPath()
            newPath.lineWidth = 0.75
            path = newPath

            let h = Float(height)
            var pen = false
            let beta = 1.0 - alpha
            let base: Float = doBaseline ? baseline : 1.414 * 10

            for i in 0..<Int(plotWidth) {
                var sum = spectrumStorage[i] + spectrumStorage[i + 2048]
                spectrumAverage[i] = spectrumAverage[i] * beta + sum * alpha
                sum = spectrumAverage[i] * base

                //  scale to 0dB = approx full scale, 1 unit per dB.  sum can be
                //  0 (log10 -> -inf) or 0*inf (NaN) via the baseline term; the
                //  pen logic never feeds a non-finite value to NSBezierPath.
                let db = Float(10.0 * log10(Double(sum)) - 64.237)
                let x = Float(i) + Float(plotOffset) + 0.5
                let y = h + db * Float(Oscilloscope.pixPerdB)
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
            if doBaseline {
                var avg: Float = 0.0
                for i in 30..<Int(plotWidth) { avg += spectrumAverage[i] }
                var threshold = avg / Float(plotWidth) * 6
                avg = 0.0
                var count: Int32 = 1
                for i in 0..<Int(plotWidth) {
                    let sv = spectrumAverage[i]
                    if sv < threshold { avg += sv; count += 1 }
                }
                threshold = avg / Float(count) * 6
                avg = 0.0
                count = 1
                for i in 0..<Int(plotWidth) {
                    let sv = spectrumAverage[i]
                    if sv < threshold { avg += sv; count += 1 }
                }
                baseline = 0.01 / (avg / Float(count))
            }
            perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
        }
    }

    //  set Mark frequency to zero to disable
    @objc(setTonePairMarker:)
    func setTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>?) {
        pathLock.lock()
        guard let tp = tonepair, tp.pointee.mark >= 0.1, tp.pointee.space >= 0.1 else {
            enableMarkSpace = false
            pathLock.unlock()
            return
        }
        let m = iFromD(tp.pointee.mark / 2756.25 * Double(plotWidth) + 0.5)
        let s = iFromD(tp.pointee.space / 2756.25 * Double(plotWidth) + 0.5)

        //  replace old BezierPath for mark/space markers
        markSpace = NSBezierPath()
        markSpace.lineWidth = 0.5
        var x = Float(plotOffset) + Float(m) + 0.5
        markSpace.move(to: P(x, 10))
        markSpace.line(to: P(x, Float(height) - 10))
        if s > 0 {
            x = Float(plotOffset) + Float(s) + 0.5
            markSpace.move(to: P(x, 10))
            markSpace.line(to: P(x, Float(height) - 10))
        }
        enableMarkSpace = true
        pathLock.unlock()
    }

    @objc(addData:isBaudot:timebase:)
    func addData(_ stream: UnsafeMutablePointer<CMDataStream>, isBaudot inBaudot: Bool, timebase inTimebase: Int32) {
        if busy { return }

        if drawLock.try() {
            enableBaudot = inBaudot
            timebase = inTimebase
            busy = true
            if style == 1 { newWaveform(stream) } else { newSpectrum(stream) }
            busy = false
            drawLock.unlock()
        }
    }

    @objc(setDisplayStyle:plotColor:)
    func setDisplayStyle(_ inStyle: Int32, plotColor newWaveformColor: NSColor?) {
        if let c = newWaveformColor {
            //  replace waveform color with requested color
            waveformColor = c
        }
        style = inStyle

        if style == 1 {
            plotColor = waveformColor
            scaleColor = spectrumColor
            scale = waveformScale
        } else {
            plotColor = spectrumColor
            scaleColor = waveformColor
            scale = spectrumScale
        }
        mux = 0
    }

    //  C truncates a (finite) double toward zero when casting to int; guard
    //  NaN/inf so a bad tone-pair value can never trap.
    @inline(__always)
    private func iFromD(_ d: Double) -> Int32 {
        if !d.isFinite { return 0 }
        if d >= 2147483647.0 { return Int32.max }
        if d <= -2147483648.0 { return Int32.min }
        return Int32(d)
    }
}
