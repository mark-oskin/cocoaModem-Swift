//
//  Waterfall.swift
//  cocoaModem
//
//  Created by Kok Chen on Thu Aug 05 2004.
//  Swift port of Waterfall.m.
//

import Cocoa

//  Assuming an Fs of 11025 Hz and a buffer of 4096 real samples, this produces an
//  FFT of 2048 samples representing 5512.5 Hz (2.69 Hz/bin)
//  i.e., a 743 bins of FFT represents a 2000 Hz span.
//
//  This is a bitmap rendering view.  The C original relies on silent integer
//  wraparound when packing colour words and on unchecked float->int truncation
//  of the FFT magnitudes.  Swift traps on both, so this port uses the wrapping
//  operators (&<<, |) for the colour packing and a guarded truncation
//  (cTruncInt / the clamp in plotIntensity) for the float->int conversions.

@objc(Waterfall)
class Waterfall: NSImageView {

    //  nib outlets (KVC)
    @objc var waterfallLabel: NSMatrix!
    @objc var waterfallTicks: NSView!
    @objc var waterfallRange: NSControl!
    @objc var waterfallClip: NSControl!
    @objc var noiseReductionButton: NSButton!
    @objc var timeAverageButton: NSButton!
    @objc var waterfallWidthButton: NSButton!

    private var waterfallImage: NSImage!
    private var bitmap: NSBitmapImageRep!
    var modem: Modem?
    var mux = 0
    var width = 0, height = 0, size = 0, depth = 0
    var cycle = 0
    var startingBin = 0
    var notch = 0
    var click: Float = -1.0, optionClick: Float = -1.0
    var offset: Float = 0.0, optionOffset: Float = 0.0
    var scrollWheelRate: Float = 1.0
    var firstBinFreq: Float = 0.0
    var hzPerPixel: Float = 0.0
    var waterfallID = 0
    var red: NSColor!, magenta: NSColor!, green: NSColor!, black: NSColor!

    var useControlKeyInsteadOfOptionKey = false
    var noiseReduction = false
    var doTimeAverage = false
    var optionMask: NSEvent.ModifierFlags = .option

    let drawLock = NSLock()
    var thread: Thread!
    var intensity = [UInt32](repeating: 0, count: 20000)
    var pixel: UnsafeMutablePointer<UInt32>?
    var rowBytes = 0
    var sideband = 1                 // 0 = LSB, 1 = USB
    var vfoOffset: Float = 0.0
    var range: Float = 0.0
    var exponent: Float = 0.25

    //  fft
    var spectrum: UnsafeMutablePointer<CMFFT>!
    let timeSample: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        p.initialize(repeating: 0, count: 4096)
        return p
    }()
    let freqBin: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        p.initialize(repeating: 0, count: 4096)
        return p
    }()
    private var fftDelegate: AnyObject?

    let noiseMask: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        p.initialize(repeating: 0, count: 1024)
        return p
    }()
    let denoiseBuffer: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        p.initialize(repeating: 0, count: 4096)
        return p
    }()
    var denoiseIndex = 0

    let timeAverage: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        p.initialize(repeating: 0, count: 1024)
        return p
    }()
    var refreshRate: Float = 1.0
    var refreshCycle: Float = 0.0

    var wideWaterfall = false
    var mostRecentTone: [Float] = [-1, -1]

    //  v0.75 currently only used in MFSKWaterfall
    var spread: Float = 15 * 15.625 / 2.69

    //  v1.03 -- NSBitmapImageRep buffer (4 planes; only plane 0 is malloc'd)
    let bitmapsPlanes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>.allocate(capacity: 4)
        p.initialize(repeating: nil, count: 4)
        return p
    }()

    //  C truncates a float to (signed 32-bit) int toward zero.  Swift's Int(x)
    //  traps on NaN and out-of-range, so mirror C with a guarded truncation.
    @inline(__always)
    static func cTruncInt(_ x: Float) -> Int {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int(Int32.max) }
        if t <= -2147483648.0 { return Int(Int32.min) }
        return Int(t)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        //  defaults matching the C -initWithFrame:
        setSpread(15 * 15.625)          // start with MFSK16 spread
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        //  These are C buffers; ARC does not free them.
        free(bitmapsPlanes[0])
        bitmapsPlanes.deallocate()
        timeSample.deallocate()
        freqBin.deallocate()
        noiseMask.deallocate()
        denoiseBuffer.deallocate()
        timeAverage.deallocate()
    }

    override var isOpaque: Bool {
        return true
    }

    private func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    private func createNewImageRep(_ initialize: Bool) {
        let background: UInt32
        var lsize: Int

        if depth >= 24 {
            background = intensity[0]
            //  32 bit/pixel for millions of colors; all components in one int write.
            rowBytes = width * 4
            size = rowBytes * height / 4
            lsize = size
            bitmap = NSBitmapImageRep(bitmapDataPlanes: bitmapsPlanes,
                        pixelsWide: width, pixelsHigh: height,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 32)
        } else {
            //  the C packs two 16-bit words; the shift can set the high bit, so wrap.
            background = (intensity[0] &<< 16) | intensity[0]
            rowBytes = ((width * 2 + 3) / 4) * 4
            size = rowBytes * height / 2
            lsize = size / 2
            //  16 bit/pixel for thousands of colors; all components in one short write.
            bitmap = NSBitmapImageRep(bitmapDataPlanes: bitmapsPlanes,
                        pixelsWide: width, pixelsHigh: height,
                        bitsPerSample: 4, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 16)
        }
        if let bitmap = bitmap, initialize {
            let p = UnsafeMutableRawPointer(bitmap.bitmapData!).assumingMemoryBound(to: UInt32.self)
            pixel = p
            for i in 0..<lsize { p[i] = background }
            waterfallImage = NSImage()
            waterfallImage.addRepresentation(bitmap)
            self.imageScaling = .scaleNone
            self.image = waterfallImage
        }
    }

    //  Waterfall is also an AudioDest
    @objc func awakeFromModem() {
        fftDelegate = nil                       // 0.82a

        useControlButton(false)

        //  create notification client for arrow keys
        NotificationCenter.default.addObserver(self, selector: #selector(arrowKeyTune(_:)),
                                               name: NSNotification.Name("ArrowKey"), object: nil)

        if waterfallRange != nil { setInterface(waterfallRange, to: #selector(waterfallRangeChanged)) }
        if waterfallClip != nil { setInterface(waterfallClip, to: #selector(waterfallRangeChanged)) }
        if noiseReductionButton != nil { setInterface(noiseReductionButton, to: #selector(noiseReductionChanged)) }
        noiseReductionChanged()
        if timeAverageButton != nil { setInterface(timeAverageButton, to: #selector(timeAverageChanged)) }
        timeAverageChanged()
        if waterfallWidthButton != nil { setInterface(waterfallWidthButton, to: #selector(waterfallWidthChanged)) }

        for i in 0..<1024 { noiseMask[i] = 0.0 }
        for i in 0..<4096 { denoiseBuffer[i] = 0.0 }
        denoiseIndex = 0

        //  check window depth
        depth = NSWindow.defaultDepthLimit.bitsPerPixel    // m = 24, t = 12, 256 = 8
        if depth < 12 {
            Messages.alert(withMessageText: NSLocalizedString("Use thousands or millions of colors", comment: ""),
                           informativeText: NSLocalizedString("Use Display Preferences", comment: ""))
            exit(0)
        }
        if depth < 24 {
            Messages.alert(withMessageText: NSLocalizedString("Use Millions of Colors", comment: ""),
                           informativeText: NSLocalizedString("Need more colors", comment: ""))
        }
        let bsize = self.bounds.size
        width = Int(bsize.width)
        height = Int(bsize.height)

        let transformSize: Float = 2048
        startingBin = 143
        firstBinFreq = Float(startingBin) * 11025.0 / 2 / transformSize
        hzPerPixel = 11025.0 / 2 / transformSize
        offset = 1000.0
        optionOffset = 2000.0
        click = -1.0
        optionClick = -1.0
        notch = 0
        cycle = 0
        waterfallID = 0
        vfoOffset = 0.0

        black = NSColor.black
        red = NSColor.green
        magenta = NSColor.magenta
        green = NSColor.green

        thread = Thread.current
        setDynamicRange(60.0)

        //  v1.03 handles the OS X 10.8 case (bitmapData changing)
        bitmap = nil
        bitmapsPlanes[0] = malloc(MemoryLayout<UInt32>.size * (width + 2) * height)?
                            .assumingMemoryBound(to: UInt8.self)
        bitmapsPlanes[1] = nil
        bitmapsPlanes[2] = nil
        bitmapsPlanes[3] = nil
        createNewImageRep(true)

        spectrum = FFTSpectrum(12, true)
    }

    @objc func useControlButton(_ state: Bool) {
        useControlKeyInsteadOfOptionKey = state
        optionMask = useControlKeyInsteadOfOptionKey ? .control : .option
    }

    //  set dynamic range
    @objc(setDynamicRange:clip:)
    func setDynamicRange(_ value: Float, clip: Float) {
        exponent = 0.25
        range = value + clip * 2

        let p: Double
        if range > 89 { p = 1 / 1.19 }                  // 90
        else if range > 79 { p = 1.00 }                 // 80
        else if range > 69 { p = 1.19 }                 // 70
        else if range > 59 { p = 1.414 }                // 60
        else if range > 49 { p = 1.68 }                 // 50
        else { p = 2.0 }                                // 40

        //  create color scale, defined by 5 colors
        let a = NSColor(calibratedRed: 0.0, green: 0, blue: 0.3, alpha: 0)
        let b = NSColor(calibratedRed: 0, green: 0.1, blue: 0.8, alpha: 0)
        let c = NSColor(calibratedRed: 0.0, green: 0.5, blue: 0.5, alpha: 0)
        let d = NSColor(calibratedRed: 0.7, green: 0.7, blue: 0, alpha: 0)
        let e = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0, alpha: 0)

        var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0

        for i in 0..<20000 {
            var q = (Double(i) * p) / 20000.0           // v0.73
            q *= p.squareRoot()
            if q > 1.0 { q = 1.0 }

            var map = pow(q, p) * 2
            if map > 0.65 { map = 0.65 }
            let inten = 1.0
            let v: Double
            if map < 0.01 {
                v = map / 0.01
                a.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
                b.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            } else if map < 0.05 {
                v = (map - 0.01) / 0.04
                b.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
                c.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            } else if map < 0.1 {
                v = (map - 0.05) / 0.05
                c.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
                d.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            } else {
                v = (map - 0.1) / 0.9
                d.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
                e.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            }
            let fr = Float(inten * ((1.0 - v) * Double(r0) + v * Double(r1)))
            let fg = Float(inten * ((1.0 - v) * Double(g0) + v * Double(g1)))
            let fb = Float(inten * ((1.0 - v) * Double(b0) + v * Double(b1)))

            if depth >= 24 {
                intensity[i] = DisplayColor.millionsOfColors(fromRed: fr, green: fg, blue: fb)
            } else {
                intensity[i] = DisplayColor.thousandsOfColors(fromRed: fr, green: fg, blue: fb)
            }
        }
    }

    @objc(setDynamicRange:)
    func setDynamicRange(_ value: Float) {
        setDynamicRange(value, clip: 0.0)
    }

    @objc(setSideband:)
    func setSideband(_ which: Int32) {
        sideband = Int(which)
    }

    //  v0.75 -- moved here from MFSKWaterfall (bug in Snow Leopard?)
    @objc(setSpread:)
    func setSpread(_ hertz: Float) {
        spread = hertz / 2.69
    }

    @objc(drawMarker:width:color:)
    func drawMarker(_ p: Float, width lineWidth: Float, color: NSColor) {
        //  never feed NaN/inf coordinates to NSBezierPath
        guard p.isFinite else { return }
        let line = NSBezierPath()
        line.lineWidth = CGFloat(lineWidth)
        line.move(to: NSPoint(x: CGFloat(p), y: 0))
        line.line(to: NSPoint(x: CGFloat(p), y: CGFloat(height)))
        color.set()
        line.stroke()
    }

    @objc func drawMarkers() {
        //  additional drawing here
        if click > 0 {
            let p = click + 0.5
            drawMarker(p, width: 2, color: black)
            drawMarker(p, width: 1.25, color: green)
        }
        if optionClick > 0 {
            let p = optionClick + 0.5
            drawMarker(p, width: 2, color: black)
            drawMarker(p, width: 1.25, color: magenta)
        }
    }

    @objc func updateInterface() {
        self.needsDisplay = true
        waterfallLabel?.needsDisplay = true
        waterfallTicks?.needsDisplay = true
        waterfallRange?.needsDisplay = true
        noiseReductionButton?.needsDisplay = true
        if timeAverageButton != nil { timeAverageButton.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMarkers()
    }

    //  send nil to disable
    @objc(enableIndicator:)
    func enableIndicator(_ who: Modem?) {
        modem = who
    }

    @objc(plotIntensity:)
    func plotIntensity(_ sample: Float) -> UInt32 {
        //  C: value = pow( sample/(4096.*4096), exponent ) * 20000.0
        //  guard the float->int conversion (NaN / out of range) and clamp the index.
        let d = pow(Double(sample) / (4096.0 * 4096.0), Double(exponent)) * 20000.0
        let value: Int
        if d.isNaN { value = 0 }
        else if d >= 19999.0 { value = 19999 }
        else if d <= 0.0 { value = 0 }
        else { value = Int(d) }
        return intensity[value]
    }

    private func setNotch(_ event: NSEvent) {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift)

        if shift {
            notch = 0
            return
        }
        let location = self.convert(event.locationInWindow, from: nil)
        let f = firstBinFreq + ((sideband == 1) ? hzPerPixel * Float(location.x)
                                                : hzPerPixel * (Float(width) - Float(location.x) - 1))
        notch = Waterfall.cTruncInt(f / hzPerPixel)
        if notch < 0 { notch = 0 }

        setDynamicRange((waterfallRange?.floatValue ?? 0) - 20)
    }

    @objc(eitherMouseDown:secondRx:)
    func eitherMouseDown(_ event: NSEvent, secondRx option: Bool) {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift)

        if shift {
            drawLock.lock()
            if !option { click = 0 } else { optionClick = 0 }
            drawLock.unlock()
            offset = 0
            if let modem = modem { modem.turnOffReceiver(Int32(waterfallID), option: option) }
            return
        }
        let location = self.convert(event.locationInWindow, from: nil)

        let f: Float
        if wideWaterfall {
            f = firstBinFreq + ((sideband == 1) ? 2 * hzPerPixel * Float(location.x)
                                                : 2 * hzPerPixel * (Float(width) - Float(location.x) - 1))
        } else {
            f = firstBinFreq + ((sideband == 1) ? hzPerPixel * Float(location.x)
                                                : hzPerPixel * (Float(width) - Float(location.x) - 1))
        }
        let g = Float(location.y) * (4096.0 / Float(CMFs))     // 4096 samples per scanline
        drawLock.lock()
        if !option {
            click = Float(location.x)
            offset = f
        } else {
            optionClick = Float(location.x)
            optionOffset = f
        }
        drawLock.unlock()

        if let modem = modem {
            modem.clicked(f, secondsAgo: g, option: option, fromWaterfall: true, waterfallID: Int32(waterfallID))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags

        if flags.contains(.command) {
            setNotch(event)
            return
        }

        let option = flags.contains(optionMask)
        eitherMouseDown(event, secondRx: option)
    }

    override func rightMouseDown(with event: NSEvent) {
        if useControlKeyInsteadOfOptionKey { eitherMouseDown(event, secondRx: true) }
    }

    @objc(setScrollWheelRate:)
    func setScrollWheelRate(_ speed: Float) {
        scrollWheelRate = speed
    }

    override func scrollWheel(with event: NSEvent) {
        if let modem = modem, modem.isActiveTab() {
            let df = ((event.deltaY > 0) ? Float(-0.5) : Float(0.5)) * scrollWheelRate
            let flags = event.modifierFlags
            let option = flags.contains(optionMask)
            if option {
                optionOffset += (sideband != 0) ? (df) : (-df)
                let dv = (optionOffset - firstBinFreq) / hzPerPixel
                drawLock.lock()
                optionClick = (sideband != 0) ? dv : Float(width) - dv - 1
                drawLock.unlock()
                modem.clicked(optionOffset, secondsAgo: 0, option: true, fromWaterfall: false, waterfallID: 0)
            } else {
                offset += (sideband != 0) ? (df) : (-df)
                let dv = (offset - firstBinFreq) / hzPerPixel
                drawLock.lock()
                click = (sideband != 0) ? dv : Float(width) - dv - 1
                drawLock.unlock()
                modem.clicked(offset, secondsAgo: 0, option: false, fromWaterfall: false, waterfallID: 0)
            }
        }
    }

    //  v0.73
    @objc func clearMarkers() {
        drawLock.lock()
        click = 0
        optionClick = 0
        drawLock.unlock()
    }

    @objc(moveToneTo:receiver:)
    func moveToneTo(_ tone: Float, receiver uniqueID: Int32) {
        let bin: Float

        mostRecentTone[Int(uniqueID)] = tone

        if sideband == 1 {
            if wideWaterfall {                          // v0.47
                bin = (tone - firstBinFreq) / (2 * hzPerPixel) + 3.5
            } else {
                bin = (tone - firstBinFreq) / hzPerPixel
            }
        } else {
            if wideWaterfall {
                bin = Float(width) - (tone - firstBinFreq) / (2 * hzPerPixel) - 4.5
            } else {
                bin = Float(width) - (tone - firstBinFreq) / hzPerPixel - 1
            }
        }
        drawLock.lock()
        switch uniqueID {
        case 0:
            if click > 0 {
                click = bin
                offset = tone
            }
        case 1:
            if optionClick > 0 {
                optionClick = bin
                optionOffset = tone
            }
        default:
            break
        }
        drawLock.unlock()
    }

    //  turn on the frequency indicator and calculate position for drawing
    @objc(forceToneTo:receiver:)
    func forceToneTo(_ tone: Float, receiver uniqueID: Int32) {
        drawLock.lock()
        if uniqueID == 1 { optionClick = 1 } else { click = 1 }
        drawLock.unlock()
        moveToneTo(tone, receiver: uniqueID)
    }

    @objc func arrowKeyTune(_ notify: Notification) {
        guard let modem = modem, modem.isActiveTab() else { return }
        //  PSK panel currently open
        guard let event = notify.object as? NSEvent else { return }
        guard let chars = event.characters, let first = chars.utf16.first else { return }
        let ch = Int(first)
        let df: Float
        switch ch {
        case NSUpArrowFunctionKey: df = 1.0
        case NSDownArrowFunctionKey: df = -1.0
        case NSLeftArrowFunctionKey: df = -0.1
        case NSRightArrowFunctionKey: df = 0.1
        default: return
        }
        let flags = event.modifierFlags
        let option = flags.contains(optionMask)
        if option {
            optionOffset += (sideband != 0) ? (df) : (-df)
            let dv = (optionOffset - firstBinFreq) / hzPerPixel
            drawLock.lock()
            optionClick = (sideband != 0) ? dv : Float(width) - dv - 1
            drawLock.unlock()
            modem.clicked(optionOffset, secondsAgo: 0, option: true, fromWaterfall: false, waterfallID: 0)
        } else {
            if flags.intersection([.option, .control]).isEmpty {
                offset += (sideband != 0) ? (df) : (-df)
            }
            let dv = (offset - firstBinFreq) / hzPerPixel
            drawLock.lock()
            click = (sideband != 0) ? dv : Float(width) - dv - 1
            drawLock.unlock()
            modem.clicked(offset, secondsAgo: 0, option: false, fromWaterfall: false, waterfallID: 0)
        }
    }

    @objc(setWaterfallID:)
    func setWaterfallID(_ index: Int32) {
        waterfallID = Int(index)
    }

    @objc func displayInMainThread() {
        self.display()                      // v0.73
    }

    //  set callback (client should implement -newFFTBuffer)
    //  set to nil to turn callback off
    @objc(setFFTDelegate:)
    func setFFTDelegate(_ delegate: Any?) {
        fftDelegate = delegate as AnyObject?
    }

    //  callback prototype
    @objc(newFFTBuffer:)
    func newFFTBuffer(_ buffer: UnsafeMutablePointer<Float>) {
    }

    @objc(processBufferAndDisplayInMainThread:)
    func processBufferAndDisplayInMainThread(_ samples: UnsafeMutablePointer<Float>) {
        CMPerformFFT(spectrum, samples, freqBin)

        if let fftDelegate = fftDelegate {
            fftDelegate.newFFTBuffer?(freqBin)          // v0.57b
        }

        let actualStartingBin = wideWaterfall ? (startingBin - 7) : startingBin

        let startBin = freqBin + actualStartingBin
        var output: UnsafeMutablePointer<Float> = startBin

        //  decimate by 2:1 using rectangular window if wide waterfall
        if wideWaterfall {
            var i = startingBin
            while i < actualStartingBin + width {
                let j = i * 2 - actualStartingBin
                freqBin[i] = (freqBin[j] + freqBin[j + 1]) * 0.5
                i += 1
            }
        }

        var averagedStore = [Float](repeating: 0, count: 1024)

        averagedStore.withUnsafeMutableBufferPointer { averagedBuf in
            let averaged = averagedBuf.baseAddress!

            if noiseReduction || doTimeAverage {
                //  apply noise reduction
                assert(width <= 1024)

                let p0 = denoiseBuffer + denoiseIndex
                let p1 = denoiseBuffer + ((denoiseIndex + 3072) % 4096)
                let p2 = denoiseBuffer + ((denoiseIndex + 2048) % 4096)
                for i in 0..<width { p0[i] = startBin[i] }

                denoiseIndex = (denoiseIndex + 1024) % 4096

                var peak: Float = 0.0001
                var norm: Float = 0.0001
                for i in 0..<width {
                    let v = p0[i] + p1[i] + p2[i]
                    let u = v.squareRoot()
                    if v > peak { peak = v }
                    if u > norm { norm = u }
                    averaged[i] = u
                }
                //  normalize smoothed average sqrt spectra and find normalized min (noise)
                norm = 1.0 / norm
                var minv: Float = 1.0e12
                for i in 0..<width {
                    let v = averaged[i] * norm
                    if v < minv { minv = v }
                    noiseMask[i] = v * 0.2 + noiseMask[i] * 0.8
                }
                let noise = minv * 2.0                  // 6 dB above min
                var agcCompensation = 0.03 / minv.squareRoot()
                if agcCompensation > 1.4 { agcCompensation = 1.4 }
                else if agcCompensation < 0.3 { agcCompensation = 0.3 }

                var sum: Float = 0.0
                for i in 0..<width {
                    var v = noiseMask[i] + noise
                    if v < 0.001 { v = 0.001 } else if v > 1.0 { v = 1.0 }
                    var u = noiseMask[i] - noise
                    if u < 0.0001 { u = 0.0001 }
                    let wiener = u / v * agcCompensation
                    averaged[i] = startBin[i] * wiener
                    sum += averaged[i]
                }
                sum /= Float(width * 10)
                for i in 0..<width {
                    var u = averaged[i]
                    if u < sum { u = sum / 10 }
                    averaged[i] = u
                }
                //  use un-denoised data for waterfall display
                output = averaged
            }

            //  v0.73
            if doTimeAverage {
                var lastv: Float = 0
                for i in 0..<width {
                    let v = (output[i] * output[i]) * 0.01
                    let u = v + lastv
                    lastv = v
                    if u < timeAverage[i] {
                        timeAverage[i] = timeAverage[i] * 0.8
                    } else {
                        timeAverage[i] = timeAverage[i] * 0.5 + u * 0.5
                    }
                }
                output = timeAverage
            }

            //  scroll waterfall up
            //  v1.03 -- allocate new BitmapImageRep for Mountain Lion
            waterfallImage.removeRepresentation(bitmap)
            createNewImageRep(false)        // create new NSBitmapImageRep with the local buffers
            waterfallImage.addRepresentation(bitmap)
            pixel = UnsafeMutableRawPointer(bitmap.bitmapData!).assumingMemoryBound(to: UInt32.self)

            let base = UnsafeMutableRawPointer(pixel!)
            memcpy(base, base + rowBytes, rowBytes * (height - 1))

            if depth >= 24 {
                let line = (base + rowBytes * (height - 1)).assumingMemoryBound(to: UInt32.self)
                if sideband != 0 {
                    for i in 0..<width { line[i] = plotIntensity(output[i]) }
                } else {
                    for i in 0..<width { line[width - i - 1] = plotIntensity(output[i]) }
                }
            } else {
                let sline = (base + rowBytes * (height - 1)).assumingMemoryBound(to: UInt16.self)
                if sideband != 0 {
                    for i in 0..<width { sline[i] = UInt16(truncatingIfNeeded: plotIntensity(output[i])) }
                } else {
                    for i in 0..<width { sline[width - i - 1] = UInt16(truncatingIfNeeded: plotIntensity(output[i])) }
                }
            }
        }
        self.performSelector(onMainThread: #selector(displayInMainThread), with: nil, waitUntilDone: false)
    }

    @objc(importAndDisplayData:)
    func importAndDisplayData(_ pipe: CMPipe) {
        //  ignore data overruns
        if drawLock.try() {
            let stream = pipe.stream()!
            let data = stream.pointee.array
            let samples = Int(stream.pointee.samples)

            //  copy new buffer (512) into fft buffer (4096)
            let limit = 4096 - samples
            if mux > limit { mux = limit }
            memcpy(timeSample + mux, data, samples * MemoryLayout<Float>.size)
            mux += samples

            if mux >= 4096 {
                mux = 0
                processBufferAndDisplayInMainThread(timeSample)
            }
            drawLock.unlock()
        } else {
            print("waterfall overrun")
        }
    }

    @objc(importData:)
    func importData(_ pipe: CMPipe) {
        if modem == nil { return }

        refreshCycle += refreshRate
        if refreshCycle < 0.99 { return }
        refreshCycle = 0
        importAndDisplayData(pipe)
    }

    @objc(setRefreshRate:)
    func setRefreshRate(_ rate: Float) {
        refreshRate = rate
    }

    @objc func waterfallRangeChanged() {
        let clip = (waterfallClip != nil) ? waterfallClip.floatValue : 0.0
        setDynamicRange(waterfallRange.floatValue, clip: clip)
    }

    @objc func noiseReductionChanged() {
        if noiseReductionButton == nil {
            noiseReduction = true
            return
        }
        noiseReduction = (noiseReductionButton.state == .on)
    }

    //  v0.73  support plist for NR button
    @objc func noiseReductionState() -> Bool {
        return (noiseReductionButton?.state == .on)
    }

    //  v0.73  support plist for NR button
    @objc(setNoiseReductionState:)
    func setNoiseReductionState(_ state: Bool) {
        if noiseReductionButton != nil {
            noiseReductionButton.state = state ? .on : .off
            noiseReductionChanged()
        }
    }

    @objc func timeAverageChanged() {
        if timeAverageButton == nil {
            doTimeAverage = false
            return
        }
        doTimeAverage = (timeAverageButton.state == .on)
        for i in 0..<1024 { timeAverage[i] = 0 }
    }

    @objc func waterfallWidthChanged() {
        if waterfallWidthButton == nil {
            wideWaterfall = false
            return
        }
        wideWaterfall = (waterfallWidthButton.state == .on)
        waterfallWidthButton.title = wideWaterfall ? "4 kHz" : "2 kHz"

        setOffset(vfoOffset, sideband: Int32(sideband))
        for i in 0..<2 {
            if mostRecentTone[i] > 100 { moveToneTo(mostRecentTone[i], receiver: Int32(i)) }
        }
    }

    //  set VFO offset
    @objc(setOffset:sideband:)
    func setOffset(_ freq: Float, sideband inSideband: Int32) {
        vfoOffset = freq
        var nearest = (Waterfall.cTruncInt(freq) / 100) * 100
        if (freq - Float(nearest)) > 50.0 { nearest += 100 }

        let pixelOffset: Float
        //  sideband: LSB = 0, USB = 1, 2.69179 Hz/pixel
        if inSideband == 1 {
            //  USB
            pixelOffset = (freq - Float(nearest)) / hzPerPixel

            if wideWaterfall {
                var fstart: Int32 = 400
                for i in 0..<22 {
                    let label = waterfallLabel.cell(atRow: 0, column: i)
                    let actual = fstart - Int32(nearest)
                    if actual % 600 == 0 { label?.intValue = actual } else { label?.stringValue = "" }
                    fstart += 200
                }
            } else {
                var fstart: Int32 = 400
                for i in 0..<21 {
                    let label = waterfallLabel.cell(atRow: 0, column: i)
                    let actual = fstart - Int32(nearest)
                    if actual % 500 == 0 { label?.intValue = actual } else { label?.stringValue = "" }
                    fstart += 100
                }
            }
        } else {
            // LSB
            pixelOffset = -(freq - Float(nearest)) / hzPerPixel - 1 + 26 /* 778-752 */

            if wideWaterfall {
                var fstart: Int32 = 4400
                for i in 0..<21 {
                    let label = waterfallLabel.cell(atRow: 0, column: i)
                    let actual = fstart - Int32(nearest)
                    if actual % 600 == 0 { label?.intValue = -actual } else { label?.stringValue = "" }
                    fstart -= 200
                }
            } else {
                var fstart: Int32 = 2400
                for i in 0..<21 {
                    let label = waterfallLabel.cell(atRow: 0, column: i)
                    let actual = fstart - Int32(nearest)
                    if actual % 500 == 0 { label?.intValue = -actual } else { label?.stringValue = "" }
                    fstart -= 100
                }
            }
        }
        var frame = waterfallLabel.frame
        frame.origin.x = CGFloat(pixelOffset - 15)
        waterfallLabel.frame = frame
        waterfallLabel.display()

        //  fine tune tick marks
        frame = waterfallTicks.frame
        frame.origin.x = CGFloat(pixelOffset - 37)
        if wideWaterfall {
            if sideband == 0 { frame.origin.x -= 1.0 } else { frame.origin.x += 3.0 }
        } else {
            if sideband == 1 { frame.origin.x += 2.5 }
        }

        waterfallTicks.frame = frame
        waterfallTicks.display()
    }
}
