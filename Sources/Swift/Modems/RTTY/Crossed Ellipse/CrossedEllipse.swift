//
//  CrossedEllipse.swift
//  cocoaModem
//
//  Created by Kok Chen on Fri May 14 2004.
//  Swift port of CrossedEllipse.m.
//
//  This is a bitmap RTTY crossed-ellipse ("scope") view.  The C original packs
//  colour words with silent 32-bit integer wraparound and relies on unchecked
//  float->int truncation of the IIR filter outputs.  Swift traps on both, so
//  this port uses the wrapping operators (&<<, &+) for the colour packing and a
//  guarded truncation (ceTruncInt) plus the C's own index clamps for the
//  float->int / pixel-offset conversions.
//
//  Endianness: the C uses `#if __BIG_ENDIAN__` to select the component shift
//  values.  Apple Silicon and Intel are little-endian, so this port hard-codes
//  the little-endian (`#else`) shifts (24-bit: r=0,g=8,b=16,a=24 ;
//  16-bit: r=4,g=0,b=12,a=8).
//

import Cocoa

private let FADE = 1024

//  C truncates a float to (signed 32-bit) int toward zero.  Swift's Int32(x)
//  traps on NaN and out-of-range, so mirror C with a guarded truncation.
@inline(__always)
fileprivate func ceTruncInt(_ x: Float) -> Int32 {
    if x.isNaN { return 0 }
    let t = x.rounded(.towardZero)
    if t >= 2147483647.0 { return Int32.max }
    if t <= -2147483648.0 { return Int32.min }
    return Int32(t)
}

@objc(CrossedEllipse)
class CrossedEllipse: NSImageView {

    //  bitmap image
    private var ellipseImage: NSImage!               // C ivar: image
    private var bitmap: NSBitmapImageRep!
    internal var pixel: UnsafeMutablePointer<UInt32>?
    internal var width: Int32 = 0, height: Int32 = 0
    private var size: Int = 0
    internal var depth: Int32 = 0
    private var plotRGB: UInt32 = 0
    internal var plotBackground: UInt32 = 0
    private var bg32: UInt32 = 0
    private var grayScale = [UInt32](repeating: 0, count: 512)
    internal var scaleColor: NSColor?
    internal var axis: NSBezierPath?

    internal var scale: Float = 0.0
    private var fatness: Float = 1.0
    internal var modem: Modem?
    private var mark = [Float](repeating: 0, count: 4)
    private var space = [Float](repeating: 0, count: 4)
    private var markFrequency: Float = 0.0, spaceFrequency: Float = 0.0
    //  FIR filters
    private var bpf: UnsafeMutablePointer<CMFIR>?
    private var bpfData = [Float](repeating: 0, count: 512)
    //  IIR filters
    private var dj0ot: Bool = false
    private var mGain: Float = 0.0, sGain: Float = 0.0
    private var mPole = [Double](repeating: 0, count: 5)
    private var sPole = [Double](repeating: 0, count: 5)
    private var mZero = [Double](repeating: 0, count: 5)
    private var sZero = [Double](repeating: 0, count: 5)
    internal var lock: NSLock!

    private var offsetToPhosphorDisplay = [Int](repeating: 0, count: FADE)
    private var currentOffset: Int = 0
    private var agc: Float = 1.0
    private var agcCurve = [Float](repeating: 0, count: 1024)
    internal var displayMux: Int32 = 0

    private var overrun: NSLock!

    //  v1.03 -- NSBitmapImageRep buffer (4 planes; only plane 0 is malloc'd)
    private let bitmaps: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>.allocate(capacity: 4)
        p.initialize(repeating: nil, count: 4)
        return p
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    //  matches the C -initWithFrame:
    private func commonInit() {
        modem = nil
        overrun = NSLock()
        fatness = 1.0

        //  phosphor decay is modeled with a ring buffer of FADE entries
        for i in 0..<FADE { offsetToPhosphorDisplay[i] = 0 }
        currentOffset = 0

        for i in 0..<4 { mark[i] = 0.0; space[i] = 0.0 }
        agc = 1.0
        displayMux = 0
        for i in 0..<1024 {
            var x = Float(i) / 1024.0
            if x < 0.1 { x = 0.1 }
            agcCurve[i] = x * 1.1
        }
    }

    deinit {
        //  These are C buffers; ARC does not free them.
        free(bitmaps[0])
        bitmaps.deallocate()
        if let ellipseImage = ellipseImage, let bitmap = bitmap {
            ellipseImage.removeRepresentation(bitmap)
        }
    }

    override var isOpaque: Bool {
        return true
    }

    @objc(setFatness:)
    func setFatness(_ value: Float) {
        fatness = value
    }

    //  create IIR filters for mark and space frequencies
    @objc(setTonePair:)
    func setTonePair(_ tonepair: UnsafePointer<CMTonePair>) {
        var mf = Float(tonepair.pointee.mark)
        var sf = Float(tonepair.pointee.space)

        if mf > sf {
            let bw = sf
            sf = mf
            mf = bw
        }
        markFrequency = mf
        spaceFrequency = sf

        lock.lock()
        if !dj0ot {
            //  scale filter bandwidth by the shift
            //  nominally set a 170 Hz shift to a filter bandwidth of 210 Hz
            var bw = abs(mf - sf) * 210.0 * fatness / 170.0
            if bw > 300 { bw = 300 }

            bpf = CMFIRBandpassFilter(mf - 150, sf + 150, Float(CMFs), 128)
            mGain = 1.5 * butterworthDesign(4, BP, bw, mf, &mPole, &mZero)
            sGain = 1.5 * butterworthDesign(4, BP, bw, sf, &sPole, &sZero)
        } else {
            //  notch filters not working yet...
            mGain = 100 * notchDesign(2.0, sf, &mPole, &mZero)
            sGain = 100 * notchDesign(2.0, mf, &sPole, &sZero)
        }
        lock.unlock()
    }

    /* local */
    private func alp(_ low: Int32, _ high: Int32, _ value: Int32, _ shift: Int32) -> Int32 {
        var v = value
        if v > 255 { v = 255 }
        let mapped = Float((Double(v) / 255.0).squareRoot())
        let p = ceTruncInt(Float(low) * (1 - mapped) + Float(high) * mapped)
        return p &<< shift
    }

    @objc func preSetup() {
        scaleColor = NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
    }

    @objc(postSetup:r:g:b:a:)
    func postSetup(_ mask: Int32, r rshift: Int32, g gshift: Int32, b bshift: Int32, a ashift: Int32) {
    }

    private func createNewImageRep(_ initialize: Bool) {
        let rowBytes: Int
        let lsize: Int

        if depth >= 24 {
            //  32 bit/pixel for millions of colors; all components in one int write.
            rowBytes = Int(width) * 4
            size = rowBytes * Int(height) / 4
            lsize = size
            bitmap = NSBitmapImageRep(bitmapDataPlanes: bitmaps,
                        pixelsWide: Int(width), pixelsHigh: Int(height),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 32)
        } else {
            //  16 bit/pixel for thousands of colors; all components in one short write.
            rowBytes = ((Int(width) * 2 + 3) / 4) * 4
            size = rowBytes * Int(height) / 2
            lsize = size / 2
            bitmap = NSBitmapImageRep(bitmapDataPlanes: bitmaps,
                        pixelsWide: Int(width), pixelsHigh: Int(height),
                        bitsPerSample: 4, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 16)
        }
        if let bitmap = bitmap, initialize {
            let p = UnsafeMutableRawPointer(bitmap.bitmapData!).assumingMemoryBound(to: UInt32.self)
            pixel = p
            for i in 0..<lsize { p[i] = bg32 }
            ellipseImage = NSImage()
            ellipseImage.addRepresentation(bitmap)
            self.imageScaling = .scaleNone
            self.image = ellipseImage
        }
    }

    //   note: CrossedEllipse is also an AudioDest
    override func awakeFromNib() {
        var mask: Int32 = 0, rshift: Int32 = 0, gshift: Int32 = 0, bshift: Int32 = 0, ashift: Int32 = 0
        var tonepair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)

        lock = NSLock()

        depth = Int32(NSWindow.defaultDepthLimit.bitsPerPixel)   // m = 24, t = 12, 256 = 8
        if depth < 12 {
            _ = Messages.alert(withMessageText: NSLocalizedString("Use thousands or millions of colors", comment: ""),
                               informativeText: NSLocalizedString("Use Display Preferences", comment: ""))
            exit(0)
        }
        if depth < 24 {
            _ = Messages.alert(withMessageText: NSLocalizedString("Use Millions of Colors", comment: ""),
                               informativeText: NSLocalizedString("Need more colors", comment: ""))
        }

        preSetup()
        let bsize = self.bounds.size
        width = Int32(bsize.width)
        height = Int32(bsize.height)
        scale = Float(ceTruncInt(Float(0.4286 * Double(width))))   // 60 pixels for a 140x140 view

        if depth >= 24 {
            //  little-endian shift values (see file header note)
            rshift = 0
            gshift = 8
            bshift = 16
            ashift = 24

            for i in 0..<512 {
                let packed = alp(0, 0, Int32(i), rshift) &+ alp(16, 255, Int32(i), gshift)
                           &+ alp(0, 0, Int32(i), bshift) &+ (Int32(0xff) &<< ashift)
                grayScale[i] = UInt32(bitPattern: packed)
            }
            plotRGB = grayScale[255]
            plotBackground = grayScale[0]
            bg32 = grayScale[0]
            size = Int(width) * Int(height)
            mask = 0xff
        } else {
            //  little-endian shift values (see file header note)
            rshift = 4
            gshift = 0
            bshift = 12
            ashift = 8

            for i in 0..<256 {
                let packed = alp(0, 0, Int32(i), rshift) &+ alp(1, 15, Int32(i), gshift)
                           &+ alp(0, 0, Int32(i), bshift) &+ (Int32(0xf) &<< ashift)
                grayScale[i] = UInt32(bitPattern: packed)
            }
            plotRGB = grayScale[255]
            plotBackground = grayScale[0]
            bg32 = (plotBackground &<< 16) | plotBackground   // two repeated pixels
            size = Int(width) * Int(height) / 2
            mask = 0xf
        }

        //  v1.03 handles the OS X 10.8 case (bitmapData changing)
        bitmap = nil
        bitmaps[0] = malloc(MemoryLayout<UInt32>.size * (Int(width) + 2) * Int(height))?
                        .assumingMemoryBound(to: UInt8.self)
        bitmaps[1] = nil
        bitmaps[2] = nil
        bitmaps[3] = nil
        createNewImageRep(true)

        //  axes
        let half = Float(Int(width) / 2) + 0.5
        axis = NSBezierPath()
        axis?.move(to: NSPoint(x: CGFloat(half), y: CGFloat(half - scale)))
        axis?.line(to: NSPoint(x: CGFloat(half), y: CGFloat(half + scale)))
        axis?.move(to: NSPoint(x: CGFloat(half - scale), y: CGFloat(half)))
        axis?.line(to: NSPoint(x: CGFloat(half + scale), y: CGFloat(half)))

        postSetup(mask, r: rshift, g: gshift, b: bshift, a: ashift)

        //  create default mark and space filters
        dj0ot = false
        setTonePair(&tonepair)
    }

    //  send nil to disable
    @objc(enableIndicator:)
    func enableIndicator(_ who: Modem?) {
        modem = who
    }

    //  use IIR Mark and Space filters
    @objc(importDataIIR:)
    func importDataIIR(_ pipe: CMTappedPipe) {
        guard let stream = pipe.stream() else { return }
        guard let data = stream.pointee.array else { return }
        let samples = Int(stream.pointee.samples)

        let widePixel = (depth >= 24)
        guard let px = pixel else { return }
        let spix = UnsafeMutableRawPointer(px).assumingMemoryBound(to: UInt16.self)

        let xp = Int(width) / 2
        let yp = Int(height) / 2
        let max = Int(width) * Int(height) - 1
        let gain = scale / mGain

        //  moderately BPF around the signal to remove noise
        guard let bpf = bpf else { return }
        CMPerformFIR(bpf, data, Int32(samples), &bpfData)

        //  remove [samples] of oldest phosphor values to make sure they are erased
        assert(samples < FADE)
        var io = currentOffset
        if widePixel {
            for _ in 0..<samples {
                let offset = offsetToPhosphorDisplay[io]
                px[offset] = plotBackground
                io += 1
                if io >= FADE { io = 0 }
            }
        } else {
            for _ in 0..<samples {
                let offset = offsetToPhosphorDisplay[io]
                spix[offset] = UInt16(truncatingIfNeeded: plotBackground)
                io += 1
                if io >= FADE { io = 0 }
            }
        }

        let mZero1 = Float(mZero[1])
        let mPole1 = Float(mPole[1]), mPole2 = Float(mPole[2]), mPole3 = Float(mPole[3]), mPole4 = Float(mPole[4])
        let sZero1 = Float(sZero[1])
        let sPole1 = Float(sPole[1]), sPole2 = Float(sPole[2]), sPole3 = Float(sPole[3]), sPole4 = Float(sPole[4])

        for i in 0..<samples {
            let s = bpfData[i]
            agc = 0.98 * agc + 0.02 * abs(s)
            if agc > 1 { agc = 1 }

            let x: Float
            let y: Float
            if !dj0ot {
                //  mark filter 4th order IIR BPF (x axis)
                let wm = s - mPole1 * mark[0] - mPole2 * mark[1] - mPole3 * mark[2] - mPole4 * mark[3]
                x = (wm - 2 * mark[1] + mark[3])
                mark[3] = mark[2]; mark[2] = mark[1]; mark[1] = mark[0]; mark[0] = wm
                //  space filter 4th order IIR (y axis)
                let ws = s - sPole1 * space[0] - sPole2 * space[1] - sPole3 * space[2] - sPole4 * space[3]
                y = (ws - 2 * space[1] + space[3])
                space[3] = space[2]; space[2] = space[1]; space[1] = space[0]; space[0] = ws
            } else {
                //  mark filter 2nd order IIR Notch (x axis)
                let wm = s - mPole1 * mark[0] - mPole2 * mark[1]
                x = (wm + mZero1 * mark[0] + mark[1])
                mark[1] = mark[0]; mark[0] = wm
                //  space filter 2nd order IIR Notch (y axis)
                let ws = s - sPole1 * space[0] - sPole2 * space[1]
                y = (ws + sZero1 * space[0] + space[1])
                space[1] = space[0]; space[0] = ws
            }

            var aidx = Int(ceTruncInt(agc * 1023))
            if aidx < 0 { aidx = 0 } else if aidx > 1023 { aidx = 1023 }
            let agcGain = gain / agcCurve[aidx]

            //  x tilt: 2295=0.19
            let ox = Int(ceTruncInt((x + 0.19 * y) * agcGain))
            //  y tilt: 2125=0.19
            let oy = Int(ceTruncInt(-(y + 0.19 * x) * agcGain))

            var dy = Int(ceTruncInt(Float(oy) + Float(yp) - 1.0))
            var dx = ox + xp
            if dy > Int(height) - 1 { dy = Int(height) - 1 } else if dy < 0 { dy = 0 }
            if dx > Int(width) - 1 { dx = Int(width) - 1 } else if dx < 0 { dx = 0 }
            var offset = dy * Int(width) + dx
            if offset > max { offset = max } else if offset < 0 { offset = 0 }
            //  add the new point, update phosphor
            offsetToPhosphorDisplay[currentOffset] = offset
            //  go to the next displayable point
            currentOffset += 1
            if currentOffset >= FADE { currentOffset = 0 }
        }

        //  recompute phosphor decays and write to pixel memory
        var rho: Float = 500.1
        io = currentOffset - 1
        if widePixel {
            for _ in 0..<FADE {
                if io < 0 { io = FADE - 1 }
                let offset = offsetToPhosphorDisplay[io]
                var gray = Int(ceTruncInt(rho))
                if gray < 0 { gray = 0 } else if gray > 511 { gray = 511 }
                px[offset] = grayScale[gray]
                rho *= 0.998
                io -= 1
            }
        } else {
            for _ in 0..<FADE {
                if io < 0 { io = FADE - 1 }
                let offset = offsetToPhosphorDisplay[io]
                var gray = Int(ceTruncInt(rho))
                if gray < 0 { gray = 0 } else if gray > 511 { gray = 511 }
                spix[offset] = UInt16(truncatingIfNeeded: grayScale[gray])
                rho *= 0.998
                io -= 1
            }
        }
    }

    //  assume data is 11025, 1 channel, 512 samples
    @objc(importDataInMainThread:)
    func importDataInMainThread(_ pipe: CMPipe) {
        if modem == nil { return }

        //  update data to mark and space filters
        if lock.try() {
            importDataIIR(unsafeDowncast(pipe, to: CMTappedPipe.self))

            //  v1.03 -- allocate new BitmapImageRep for Mountain Lion
            if let ellipseImage = ellipseImage, let bitmap = bitmap {
                ellipseImage.removeRepresentation(bitmap)
            }
            createNewImageRep(false)            // create new NSBitmapImageRep with the local buffers
            ellipseImage?.addRepresentation(bitmap)

            displayMux += 1
            if (displayMux & 0x3) == 0 {
                //  use a smaller rect to keep refresh time down
                if displayMux > 16 {
                    //  once in a while, update the entire display to clean any crud
                    displayMux = 0
                    self.needsDisplay = true
                } else {
                    let currentRect = NSRect(x: 10, y: 10, width: 120, height: 120)
                    self.setNeedsDisplay(currentRect)
                }
            }
            lock.unlock()
        }
    }

    @objc(importData:)
    func importData(_ pipe: CMPipe) {
        if modem == nil { return }

        self.performSelector(onMainThread: #selector(importDataInMainThread(_:)), with: pipe, waitUntilDone: false)
    }

    @objc func drawObjects() {
        scaleColor?.set()
        if let axis = axis, !axis.isEmpty { axis.stroke() }
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        drawObjects()
    }

    @objc func displayInMainThread() {
        self.needsDisplay = true
    }

    @objc func clearIndicator() {
        if let px = pixel {
            for i in 0..<size { px[i] = bg32 }
        }
        self.performSelector(onMainThread: #selector(displayInMainThread), with: nil, waitUntilDone: false)
    }

    @objc(setPlotColor:)
    func setPlotColor(_ color: NSColor) {
        var p: UInt32

        if depth >= 24 {
            p = 0xff // alpha
            p |= UInt32(bitPattern: ceTruncInt(Float(color.redComponent) * 255.5) &<< 24)
            p |= UInt32(bitPattern: ceTruncInt(Float(color.greenComponent) * 255.5) &<< 16)
            p |= UInt32(bitPattern: ceTruncInt(Float(color.blueComponent) * 255.5) &<< 8)
        } else {
            p = 0xf // alpha
            p |= UInt32(bitPattern: ceTruncInt(Float(color.redComponent) * 15.5) &<< 12)
            p |= UInt32(bitPattern: ceTruncInt(Float(color.greenComponent) * 15.5) &<< 8)
            p |= UInt32(bitPattern: ceTruncInt(Float(color.blueComponent) * 15.5) &<< 4)
        }
        plotRGB = p
    }

    @objc func recacheImage() {
        let im = self.image
        self.image = nil
        self.image = im
    }
}
