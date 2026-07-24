//
//  MFSKIndicator.swift
//  cocoaModem
//
//  Created by Kok Chen on Jan 30 2007.
//  Swift port of MFSKIndicator.m.
//
//  This is a bitmap rendering view.  As in DisplayColor / Waterfall, the C
//  original relies on silent integer wraparound when packing colour words and on
//  unchecked float->int truncation of the plotted magnitudes.  Swift traps on
//  both, so this port uses the wrapping operators (&<<, |) for the colour packing
//  and a guarded truncation (cTruncInt) for the float->int conversion.

import Cocoa

@objc(MFSKIndicator)
class MFSKIndicator: NSImageView {

    //  ( the C ivar "image" is renamed here because NSImageView already has an
    //    -image property; it is never referenced outside this class )
    private var indicatorImage: NSImage!
    private var bitmap: NSBitmapImageRep!
    private var width = 0, height = 0, size = 0, depth = 0, rowBytes = 0
    private var saved = [Float](repeating: 0, count: 512)
    private var thread: Thread!
    private var intensity = [UInt32](repeating: 0, count: 20000)
    private var pixel: UnsafeMutablePointer<UInt32>?
    private var scale: Float = 0.0, exponent: Float = 0.0
    private var cycle = 0

    //  C truncates a float to (signed 32-bit) int toward zero.  Swift's Int(x)
    //  traps on NaN and out-of-range, so mirror C with a guarded truncation.
    @inline(__always)
    private static func cTruncInt(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int(Int32.max) }
        if t <= -2147483648.0 { return Int(Int32.min) }
        return Int(t)
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        //  check window depth
        depth = NSWindow.defaultDepthLimit.bitsPerPixel      // m = 24, t = 12, 256 = 8

        cycle = 0

        let bsize = self.bounds.size
        width = Int(bsize.width)
        height = Int(bsize.height)
        if width > 512 { width = 512 }                       // array limit

        thread = Thread.current
        setScale(24.0)

        let bg: UInt32
        let lsize: Int
        if depth >= 24 {
            bg = intensity[0]
            //  32 bit/pixel for millions of colors; all components in one int write.
            rowBytes = width * 4
            size = rowBytes * height / 4
            lsize = size
            bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: width, pixelsHigh: height,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 32)
        } else {
            //  the C packs two 16-bit words; the shift can set the high bit, so wrap.
            bg = (intensity[0] &<< 16) | intensity[0]
            rowBytes = ((width * 2 + 3) / 4) * 4
            size = rowBytes * height / 2
            lsize = size / 2
            //  16 bit/pixel for thousands of colors; all components in one short write.
            bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: width, pixelsHigh: height,
                        bitsPerSample: 4, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 16)
        }

        if let bitmap = bitmap {
            let p = UnsafeMutableRawPointer(bitmap.bitmapData!).assumingMemoryBound(to: UInt32.self)
            pixel = p
            for i in 0..<lsize { p[i] = bg }
            indicatorImage = NSImage()
            indicatorImage.addRepresentation(bitmap)
            self.imageScaling = .scaleNone
            self.image = indicatorImage
        }
    }

    override var isOpaque: Bool {
        return true
    }

    @objc(setScale:)
    func setScale(_ f: Float) {
        exponent = 0.25
        scale = f
        let p = f
        //  create color scale, defined by 4 colors
        let a = NSColor(calibratedRed: 0.0, green: 0, blue: 0.2, alpha: 0)
        let b = NSColor(calibratedRed: 0, green: 0.0, blue: 0.8, alpha: 0)
        let c = NSColor(calibratedRed: 0.0, green: 0.5, blue: 0.5, alpha: 0)
        let d = NSColor(calibratedRed: 0.8, green: 0.7, blue: 0, alpha: 0)

        var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0

        for i in 0..<20000 {
            var map = Float(pow(Double(i) / 20000.0, Double(p))) * 4
            if map > 1 { map = 1 }
            let inten: Float = 1.0
            let v: Float
            if map < 0.3 {
                v = map / 0.3
                a.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
                b.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            } else if map < 0.97 {
                v = (map - 0.3) / 0.67
                b.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
                c.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            } else {
                v = (map - 0.97) / 0.03
                c.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
                d.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            }
            let fr = inten * ((1.0 - v) * Float(r0) + v * Float(r1))
            let fg = inten * ((1.0 - v) * Float(g0) + v * Float(g1))
            let fb = inten * ((1.0 - v) * Float(b0) + v * Float(b1))

            if depth >= 24 {
                intensity[i] = DisplayColor.millionsOfColors(fromRed: fr, green: fg, blue: fb)
            } else {
                intensity[i] = DisplayColor.thousandsOfColors(fromRed: fr, green: fg, blue: fb)
            }
        }
    }

    //  C: pow( sample, exponent ) * 20000.0  (unchecked float->int truncation)
    private func plotValue(_ sample: Float) -> Int {
        let d = pow(Double(sample), Double(exponent)) * 20000.0
        return MFSKIndicator.cTruncInt(d)
    }

    private func newSpectrum(_ spec: UnsafeMutablePointer<Float>, width slotsIn: Int) {
        var slots = slotsIn
        if slots >= width - 2 { slots = width - 2 }

        //  make copy of input spectrum
        //  if the input spectrum is shorter than width, zero fill the remainder
        var g = [Float](repeating: 0, count: 512)
        g[0] = 0; g[1] = 0
        var i = 2
        while i < slots { g[i] = spec[i]; i += 1 }
        while i < width { g[i] = 0; i += 1 }

        var minv = g[0], maxv = g[0]
        for i in 1..<width {
            if g[i] > maxv { maxv = g[i] } else if g[i] < minv { minv = g[i] }
        }
        let norm = 1.0 / (maxv - minv + 0.001)
        for i in 0..<width { g[i] = (g[i] - minv) * norm }

        if cycle == 0 {
            //  init accumulator
            cycle = 1
            for i in 0..<width { saved[i] = g[i] }
            return
        }
        if cycle < 5 {
            //  accumulate
            for i in 0..<width {
                if saved[i] < g[i] { saved[i] = g[i] }
            }
            cycle += 1
            return
        } else {
            for i in 0..<width {
                if saved[i] > g[i] { g[i] = saved[i] }
            }
            cycle = 0
        }

        guard let pixel = pixel else { return }
        let base = UnsafeMutableRawPointer(pixel)
        //  scroll up: copy rows [1..height) over rows [0..height-1)
        memcpy(base, base + rowBytes, rowBytes * (height - 1))
        let insert = base + rowBytes * (height - 1)

        if depth >= 24 {
            let line = insert.assumingMemoryBound(to: UInt32.self)
            for i in 0..<width {
                var index = plotValue(g[i])
                if index > 19999 { index = 19999 }
                if index < 0 { index = 0 }              // Swift array bound guard
                line[i] = intensity[index]
            }
        } else {
            let sline = insert.assumingMemoryBound(to: UInt16.self)
            for i in 0..<width {
                var index = plotValue(g[i])
                if index > 19999 { index = 19999 }
                if index < 0 { index = 0 }              // Swift array bound guard
                sline[i] = UInt16(truncatingIfNeeded: intensity[index])
            }
        }
        //  v0.73 -- was displayInMainThread
        self.performSelector(onMainThread: #selector((NSView.display as (NSView) -> () -> Void)), with: nil, waitUntilDone: false)
    }

    // accept a 384 point power spectrum and display it
    @objc(newSpectrum:)
    func newSpectrum(_ spec: UnsafeMutablePointer<Float>) {
        newSpectrum(spec, width: 384)
    }

    // accept a 512 point power spectrum and display it
    @objc(newWideSpectrum:)
    func newWideSpectrum(_ spec: UnsafeMutablePointer<Float>) {
        newSpectrum(spec, width: 448)
    }

    @objc func clear() {
        guard let pixel = pixel else { return }
        let value = intensity[0]
        if depth >= 24 {
            for i in 0..<width { pixel[i] = value }
        } else {
            let sline = UnsafeMutableRawPointer(pixel).assumingMemoryBound(to: UInt16.self)
            for i in 0..<width { sline[i] = UInt16(truncatingIfNeeded: value) }
        }

        let base = UnsafeMutableRawPointer(pixel)
        var s = base + rowBytes
        for _ in 1..<height {
            memcpy(s, base, rowBytes)
            s += rowBytes
        }
        self.performSelector(onMainThread: #selector((NSView.display as (NSView) -> () -> Void)), with: nil, waitUntilDone: false)
    }
}
