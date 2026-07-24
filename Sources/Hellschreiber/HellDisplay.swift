//
//  HellDisplay.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/26/06.
//  Swift port of HellDisplay.m.
//

import Cocoa

//  receiveView of Hellschreiber.  The image is 900 pixels wide and 512 high
//  inside a scrollview that is 288 pixels high.
//
//  This is a raw bitmap-rendering view.  The C original relies on unchecked
//  float->int truncation to index the intensity/echo colour tables and on
//  direct pointer writes into the NSBitmapImageRep backing store.  Swift traps
//  on out-of-range Array indexing and on Int(x) of a NaN/out-of-range float, so
//  this port clamps the colour-table index (grayIndex) and keeps every pixel-
//  buffer write on a raw UnsafeMutablePointer (which, like C, is not bounds
//  checked) using wrapping (&) index arithmetic.  It also keeps using the
//  already-Swift DisplayColor for the colour packing.

@objc(HellDisplay)
class HellDisplay: NSImageView {

    private var displayImage: NSImage!
    private var bitmap: NSBitmapImageRep!

    private var width = 0, height = 0, size = 0, depth = 0
    private var rowBytes = 0, lsize = 0

    private var pixel: UnsafeMutablePointer<UInt32>?
    private var intensity = [UInt32](repeating: 0, count: 300)   // saturates at 255
    private var echo = [UInt32](repeating: 0, count: 300)        // saturates at 255

    private var currentRect = NSRect.zero
    private var row = 0, column = 0                               // 16 pixel groups

    private var foreground: NSColor!
    private var background: NSColor!
    private var txColor: NSColor!

    //  v1.03 -- NSBitmapImageRep buffer (4 planes; only plane 0 is malloc'd)
    private let bitmaps: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?> = {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>.allocate(capacity: 4)
        p.initialize(repeating: nil, count: 4)
        return p
    }()

    //  C truncates columnData*255.4 to (signed) int and indexes the 300-entry
    //  colour table.  Guard the conversion (NaN / out of range) and clamp to
    //  the valid table range so Swift's Array index does not trap.
    @inline(__always)
    private func grayIndex(_ x: Float) -> Int {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t <= 0 { return 0 }
        if t >= 299 { return 299 }
        return Int(t)
    }

    private func setGrayscale(_ back: NSColor, to fore: NSColor, index: Int) {
        var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, alpha: CGFloat = 0
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0
        back.getRed(&r0, green: &g0, blue: &b0, alpha: &alpha)
        fore.getRed(&r1, green: &g1, blue: &b1, alpha: &alpha)

        for i in 0..<300 {
            var t = Float(i) / 255.0
            if t > 1.0 { t = 1.0 }
            let u = 1.0 - t

            let r = u * Float(r0) + t * Float(r1)
            let g = u * Float(g0) + t * Float(g1)
            let b = u * Float(b0) + t * Float(b1)

            let gray: UInt32
            if depth >= 24 {
                gray = DisplayColor.millionsOfColors(fromRed: r, green: g, blue: b)
            } else {
                gray = DisplayColor.thousandsOfColors(fromRed: r, green: g, blue: b)
            }
            if index == 0 { intensity[i] = gray } else { echo[i] = gray }
        }
    }

    private func createNewImageRep(_ initialize: Bool) {
        let bg: UInt32

        if depth >= 24 {
            bg = intensity[0]
            //  32 bit/pixel for millions of colors; all components in one int write.
            rowBytes = width * 4
            size = rowBytes * height / 4
            lsize = size
            bitmap = NSBitmapImageRep(bitmapDataPlanes: bitmaps,
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
            bitmap = NSBitmapImageRep(bitmapDataPlanes: bitmaps,
                        pixelsWide: width, pixelsHigh: height,
                        bitsPerSample: 4, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: rowBytes, bitsPerPixel: 16)
        }
        if let bitmap = bitmap, initialize {
            let p = UnsafeMutableRawPointer(bitmap.bitmapData!).assumingMemoryBound(to: UInt32.self)
            pixel = p
            for i in 0..<lsize { p[i] = bg }
            displayImage = NSImage()
            displayImage.addRepresentation(bitmap)
            self.imageScaling = .scaleNone
            self.image = displayImage
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)

        row = 512 - 36
        column = 0

        background = NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0)
        foreground = NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0)
        txColor = NSColor(calibratedRed: 0.0, green: 1.0, blue: 1.0, alpha: 0)

        //  check window depth (m = 24, t = 12, 256 = 8)
        depth = NSWindow.defaultDepthLimit.bitsPerPixel
        if depth < 24 {
            Messages.alert(withMessageText: NSLocalizedString("Use Millions of Colors", comment: ""),
                           informativeText: NSLocalizedString("Use Display Preferences", comment: ""))
            exit(0)
        }
        let bsize = self.bounds.size
        width = Int(bsize.width)
        height = Int(bsize.height)

        setGrayscale(background, to: foreground, index: 0)
        setGrayscale(background, to: txColor, index: 1)

        //  v1.03 handles the OS X 10.8 case (bitmapData changing)
        bitmap = nil
        bitmaps[0] = malloc(MemoryLayout<UInt32>.size * (width + 2) * height)?
                        .assumingMemoryBound(to: UInt8.self)
        bitmaps[1] = nil
        bitmaps[2] = nil
        bitmaps[3] = nil
        createNewImageRep(true)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        //  C buffer; ARC does not free it.  NSImage/NSBitmapImageRep are ARC-managed.
        free(bitmaps[0])
        bitmaps.deallocate()
    }

    override var isOpaque: Bool {
        return true
    }

    @objc(setTextColors:transmit:)
    func setTextColors(_ inColor: NSColor, transmit inTxColor: NSColor) {
        foreground = inColor
        setGrayscale(background, to: foreground, index: 0)

        txColor = inTxColor
        setGrayscale(background, to: txColor, index: 1)
    }

    @objc(setBackgroundColor:)
    func setBackgroundColor(_ inColor: NSColor) {
        background = inColor
        setGrayscale(background, to: foreground, index: 0)
    }

    //  local
    @objc func displayInMainThread() {
        self.needsDisplay = true
    }

    //  local
    @objc func displayInCurrentRect() {
        self.setNeedsDisplay(currentRect)
    }

    //  clear to background colors
    @objc func updateColorsInView() {
        if let p = pixel {
            for i in 0..<lsize { p[i] = intensity[0] }
        }
        self.performSelector(onMainThread: #selector(displayInMainThread), with: nil, waitUntilDone: false)
    }

    //  add a column of 28 half-pixels of data, magnified by 2
    //  (the column is expanded into two pixel columns)
    @objc(addColumn:index:xScale:)
    func addColumn(_ columnData: UnsafeMutablePointer<Float>, index: Int32, xScale scale: Int32) {
        if row >= 512 {
            row = 512 - 1
            return
        }
        let grayIsIntensity = (index == 0)

        //  v1.03 -- allocate new BitmapImageRep for Mountain Lion
        if let img = displayImage, let bmp = bitmap {
            img.removeRepresentation(bmp)
        }
        createNewImageRep(false)            // create new NSBitmapImageRep with the local buffers
        if let img = displayImage, let bmp = bitmap {
            img.addRepresentation(bmp)
        }
        guard let bmp = bitmap, let bd = bmp.bitmapData else { return }
        let pix = UnsafeMutableRawPointer(bd).assumingMemoryBound(to: UInt32.self)
        pixel = pix                          // this should retrieve the local buffer pointer

        if depth >= 24 {
            var refreshAll = false
            let rowIncr = rowBytes / 4
            for _ in 0..<Int(scale) {
                var ptr = pix + ((row &+ 31) &* rowIncr &+ column)
                for j in 0..<28 {
                    let gi = grayIndex(columnData[j] * 255.4)
                    ptr.pointee = grayIsIntensity ? intensity[gi] : echo[gi]
                    ptr = ptr - rowIncr
                }
                column += 1
                let lastColumn = 900
                if column >= lastColumn - 35 {
                    row -= 1
                    //  move data up one pixel row
                    let base = UnsafeMutableRawPointer(pix)
                    memcpy(base, base + rowBytes, rowBytes * (height - 1))
                    //  clear last row
                    var qptr = pix + ((height &- 1) &* rowIncr)
                    let clearIdx = (column == (lastColumn - 35)) ? 64 : 0
                    let clear = grayIsIntensity ? intensity[clearIdx] : echo[clearIdx]
                    for _ in 0..<rowIncr {
                        qptr.pointee = clear
                        qptr = qptr + 1
                    }
                    if column >= lastColumn {
                        column = 0
                        row += 36
                        //  now copy the tail of the old line into the new line
                        for k in 0..<31 {
                            let dst = pix + ((height &- 1 &- k) &* rowIncr)
                            let srcp = pix + ((height &- 37 &- k) &* rowIncr &+ (lastColumn - 20))
                            for j in 0..<20 { dst[j] = srcp[j] }
                        }
                        column += 20
                    }
                    refreshAll = true
                }
            }
            if refreshAll {
                self.performSelector(onMainThread: #selector(displayInMainThread), with: nil, waitUntilDone: false)
            } else {
                //  refresh only newly changed pixels
                var x = Float(column - 4)
                if x < 0 { x = 0 }
                currentRect = NSRect(x: CGFloat(x), y: 0, width: 8, height: 32)
                self.performSelector(onMainThread: #selector(displayInCurrentRect), with: nil, waitUntilDone: false)
            }
        }
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
    }
}
