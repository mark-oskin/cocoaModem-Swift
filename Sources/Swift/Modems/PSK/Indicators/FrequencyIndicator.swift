//
//  FrequencyIndicator.swift
//  cocoaModem
//
//  Created by Kok Chen on Thu Sep 02 2004.
//  Swift port of FrequencyIndicator.m.
//

import Cocoa
import Accelerate                       //  DSPSplitComplex

@objc(FrequencyIndicator)
class FrequencyIndicator: NSImageView {

    private var image_: NSImage!
    private var bitmap: NSBitmapImageRep!
    //  All of these were C ints; kept as Int for pointer/byte arithmetic.
    private var width: Int = 0
    private var height: Int = 0
    private var size: Int = 0
    private var depth: Int = 0
    private var rowBytes: Int = 0
    private var thread: Thread!
    //  UInt32 intensity[20000] colour table -> explicit heap buffer (freed in deinit).
    private let intensity = UnsafeMutablePointer<UInt32>.allocate(capacity: 20000)
    //  Points into the bitmap's pixel storage (owned by `bitmap`, not freed here).
    private var bitmapBase: UnsafeMutableRawPointer?
    private var range: Float = 0
    private var exponent: Float = 0
    private var sideband: Bool = false          //  NO = LSB

    deinit {
        intensity.deallocate()
    }

    override func awakeFromNib() {
        //  check window depth
        depth = NSWindow.defaultDepthLimit.bitsPerPixel   //  m = 24, t = 12, 256 = 8

        sideband = false

        let bsize = self.bounds.size
        width = Int(bsize.width)
        height = Int(bsize.height)

        thread = Thread.current
        setRange(60.0)

        let bg: UInt32
        if depth >= 24 {
            bg = intensity[0]
            //  Uses 32 bit/pixel for millions of colors mode.
            rowBytes = width * 4
            size = rowBytes * height / 4
            bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 32)
        } else {
            bg = (intensity[0] &<< 16) | intensity[0]
            rowBytes = ((width * 2 + 3) / 4) * 4
            size = rowBytes * height / 2
            //  Uses 16 bit/pixel for thousands of colors mode.
            bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 4, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 16)
        }
        //  lsize is the number of 32-bit words to prefill (whole bitmap in both modes).
        let lsize = (depth >= 24) ? size : size / 2

        if let bitmap = bitmap, let data = bitmap.bitmapData {
            let base = UnsafeMutableRawPointer(data)
            bitmapBase = base
            let pixel = base.assumingMemoryBound(to: UInt32.self)
            for i in 0..<lsize { pixel[i] = bg }
            image_ = NSImage()
            image_.addRepresentation(bitmap)
            self.imageScaling = .scaleNone
            self.image = image_
        }
    }

    override var isOpaque: Bool { return true }

    //  0 = LSB
    @objc(setSideband:)
    func setSideband(_ state: Int32) {
        sideband = (state == 1)
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        let line = NSBezierPath()
        line.lineWidth = 1
        var p = Float(width / 2) - 15.5
        line.move(to: NSMakePoint(CGFloat(p), 0))
        line.line(to: NSMakePoint(CGFloat(p), 4))
        line.move(to: NSMakePoint(CGFloat(p), CGFloat(height)))
        line.line(to: NSMakePoint(CGFloat(p), CGFloat(height - 4)))
        p = Float(width / 2) + 0.5
        line.move(to: NSMakePoint(CGFloat(p), 0))
        line.line(to: NSMakePoint(CGFloat(p), CGFloat(height)))
        p = Float(width / 2) + 16.5
        line.move(to: NSMakePoint(CGFloat(p), 0))
        line.line(to: NSMakePoint(CGFloat(p), 4))
        line.move(to: NSMakePoint(CGFloat(p), CGFloat(height)))
        line.line(to: NSMakePoint(CGFloat(p), CGFloat(height - 4)))
        NSColor.red.set()
        line.stroke()
    }

    @objc(setRange:)
    func setRange(_ value: Float) {
        exponent = 0.25
        range = value
        let p: Float
        if range > 79 { p = 1.0 }
        else if range > 59 { p = 1.414 }
        else if range > 39 { p = 2.0 }
        else { p = 2.818 }

        //  create color scale, defined by 4 colors
        //  use a 20000 element table to achieve 85 dB of dynamic range
        let a = NSColor(calibratedRed: 0.0, green: 0, blue: 0.2, alpha: 0)
        let b = NSColor(calibratedRed: 0, green: 0.0, blue: 0.8, alpha: 0)
        let c = NSColor(calibratedRed: 0.0, green: 0.5, blue: 0.5, alpha: 0)
        let d = NSColor(calibratedRed: 0.7, green: 0.7, blue: 0, alpha: 0)

        for i in 0..<20000 {
            var map = powf(Float(i) / 20000.0, p) * 2
            if map > 1 { map = 1 }
            let inten: Float = 1.0
            let v: Float
            let c0: NSColor
            let c1: NSColor
            if map < 0.3 {
                v = map / 0.3
                c0 = a; c1 = b
            } else if map < 0.95 {
                v = (map - 0.3) / 0.65
                c0 = b; c1 = c
            } else {
                v = (map - 0.95) / 0.05
                c0 = c; c1 = d
            }
            var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            c0.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
            c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)

            let rr = inten * ((1.0 - v) * Float(r0) + v * Float(r1))
            let gg = inten * ((1.0 - v) * Float(g0) + v * Float(g1))
            let bb = inten * ((1.0 - v) * Float(b0) + v * Float(b1))

            if depth >= 24 {
                intensity[i] = DisplayColor.millionsOfColors(fromRed: rr, green: gg, blue: bb)
            } else {
                intensity[i] = DisplayColor.thousandsOfColors(fromRed: rr, green: gg, blue: bb)
            }
        }
    }

    //  C truncated pow()*20000 toward zero; guard NaN/inf and clamp to the
    //  table bounds so a bad sample can never index out of range.
    private func plotValue(_ sample: Float) -> Int {
        let x = powf(sample, exponent) * 20000.0
        if !x.isFinite || x <= 0 { return 0 }
        if x >= 19999 { return 19999 }
        return Int(x)
    }

    @objc func displayInMainThread() {
        //  [ self setNeedsDisplay:YES ] ;
        self.display()                      //  v0.73
    }

    // v0.57 - n changed to 1024 for 1000s/sec sampling rate
    @objc(newSpectrum:size:)
    func newSpectrum(_ spec: UnsafeMutablePointer<DSPSplitComplex>, size n: Int32) {
        guard n == 1024 else { return }
        guard let base = bitmapBase else { return }

        //  needs to be larger than width!
        var g = [Float](repeating: 0, count: 256)
        let re = spec.pointee.realp
        let im = spec.pointee.imagp
        let m = width / 2                       //  0.32 bug fix (was 192)
        for i in 0..<m {
            let p = re[i]
            let q = im[i]
            g[width / 2 + i] = p * p + q * q
        }
        var i = 1
        while i <= m {
            let p = re[1024 - i]
            let q = im[1024 - i]
            g[width / 2 - i] = p * p + q * q
            i += 1
        }
        var minV = g[0]
        var maxV = g[0]
        for i in 1..<width {
            if g[i] > maxV { maxV = g[i] } else if g[i] < minV { minV = g[i] }
        }
        let norm = 1.0 / (maxV - minV + 0.001)
        for i in 0..<width { g[i] = (g[i] - minV) * norm }

        //  scroll the bitmap up one row (memmove: the C original used memcpy on
        //  overlapping regions, which is a forward shift; memmove is safe & equal).
        memmove(base, base + rowBytes, rowBytes * (height - 1))
        let insert = base + rowBytes * (height - 1)

        if sideband {
            if depth >= 24 {
                let line = insert.assumingMemoryBound(to: UInt32.self)
                for i in 0..<width {
                    line[i] = intensity[plotValue(g[i])]
                }
            } else {
                let sline = insert.assumingMemoryBound(to: UInt16.self)
                for i in 0..<width {
                    sline[i] = UInt16(truncatingIfNeeded: intensity[plotValue(g[i])])
                }
            }
        } else {
            if depth >= 24 {
                let line = insert.assumingMemoryBound(to: UInt32.self)
                for i in 0..<width {
                    line[i] = intensity[plotValue(g[width - i - 1])]
                }
            } else {
                let sline = insert.assumingMemoryBound(to: UInt16.self)
                for i in 0..<width {
                    sline[i] = UInt16(truncatingIfNeeded: intensity[plotValue(g[width - i - 1])])
                }
            }
        }
        perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
    }

    @objc func clear() {
        guard let base = bitmapBase else { return }
        let value = intensity[0]
        if depth >= 24 {
            let line = base.assumingMemoryBound(to: UInt32.self)
            for i in 0..<width { line[i] = value }
        } else {
            let sline = base.assumingMemoryBound(to: UInt16.self)
            for i in 0..<width { sline[i] = UInt16(truncatingIfNeeded: value) }
        }
        var s = base + rowBytes
        for _ in 1..<height {
            memcpy(s, base, rowBytes)
            s += rowBytes
        }
        perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
    }
}
