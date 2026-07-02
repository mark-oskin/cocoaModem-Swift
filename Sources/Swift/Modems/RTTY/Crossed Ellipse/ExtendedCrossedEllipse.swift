//
//  ExtendedCrossedEllipse.swift
//  cocoaModem
//
//  Created by Kok Chen on 8/20/05.
//  Swift port of ExtendedCrossedEllipse.m.
//
//  This extends the CrossedEllipse indicator to include an FSK "spectra tune".
//  As in the base class, colour words are packed with wrapping integer ops
//  (&<<, &+) and float->int conversions are guarded (ceTruncInt) then clamped
//  into the intensity table bounds, matching the C's `if(offset>255)` clamp.
//

import Cocoa

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

@objc(ExtendedCrossedEllipse)
class ExtendedCrossedEllipse: CrossedEllipse {

    private var spectrumFFT: UnsafeMutablePointer<CMFFT>?    // C ivar: spectrum
    private var fskColor: NSColor?
    private var fsk: NSBezierPath?

    private var freq = [Float](repeating: 0, count: 2048)
    private var avgfreq = [Float](repeating: 0, count: 128)
    private var intensity = [UInt32](repeating: 0, count: 256)
    private var intensityFade = [UInt32](repeating: 0, count: 256)

    override func preSetup() {
        super.preSetup()
        fsk = nil
        fskColor = NSColor(calibratedRed: 0.95, green: 0, blue: 0, alpha: 1.0)

        for i in 0..<128 { avgfreq[i] = 0 }
        spectrumFFT = FFTSpectrum(9, true)
    }

    @objc(postSetup:r:g:b:a:)
    override func postSetup(_ maskIn: Int32, r rshift: Int32, g gshift: Int32, b bshift: Int32, a ashift: Int32) {
        //  make intensity map for FSK spectrum
        var mask = UInt32(bitPattern: maskIn)
        let r0 = (plotBackground >> UInt32(rshift)) & mask
        let g0 = (plotBackground >> UInt32(gshift)) & mask
        let b0 = (plotBackground >> UInt32(bshift)) & mask

        mask = mask &<< UInt32(ashift)
        let a = mask
        if depth >= 24 {
            for i in 0..<256 {
                var r = UInt32(i) &+ r0;     if r > 255 { r = 255 }; r = r &<< UInt32(rshift)
                var g = UInt32(i) &+ g0;     if g > 255 { g = 255 }; g = g &<< UInt32(gshift)
                var b = UInt32(i / 2) &+ b0; if b > 255 { b = 255 }; b = b &<< UInt32(bshift)
                intensity[i] = r &+ g &+ b &+ a
            }
            for i in 0..<256 {
                var r = UInt32(i / 2) &+ r0; if r > 255 { r = 255 }; r = r &<< UInt32(rshift)
                var g = UInt32(i / 2) &+ g0; if g > 255 { g = 255 }; g = g &<< UInt32(gshift)
                var b = UInt32(i / 4) &+ b0; if b > 255 { b = 255 }; b = b &<< UInt32(bshift)
                intensityFade[i] = r &+ g &+ b &+ a
            }
        } else {
            for i in 0..<256 {
                var r = UInt32(i / 16) &+ r0; if r > 15 { r = 15 }; r = r &<< UInt32(rshift)
                var g = UInt32(i / 16) &+ g0; if g > 15 { g = 15 }; g = g &<< UInt32(gshift)
                var b = UInt32(i / 32) &+ b0; if b > 15 { b = 15 }; b = b &<< UInt32(bshift)
                intensity[i] = r &+ g &+ b &+ a
            }
            for i in 0..<256 {
                var r = UInt32(i / 32) &+ r0; if r > 15 { r = 15 }; r = r &<< UInt32(rshift)
                var g = UInt32(i / 32) &+ g0; if g > 15 { g = 15 }; g = g &<< UInt32(gshift)
                var b = UInt32(i / 64) &+ b0; if b > 15 { b = 15 }; b = b &<< UInt32(bshift)
                intensityFade[i] = r &+ g &+ b &+ a
            }
        }
    }

    @objc(setTonePair:)
    override func setTonePair(_ tonepair: UnsafePointer<CMTonePair>) {
        super.setTonePair(tonepair)

        let mf = Float(tonepair.pointee.mark)
        let sf = Float(tonepair.pointee.space)

        //  spectrum calibration
        //  128 samples == 2756 Hz, 2210 Hz is at 95.6
        let avg = (mf + sf) * 0.5
        let offset = Float(ceTruncInt((avg - 2210) * 128 / 2756 + 95.6)) + 0.5
        let half = Float(Int(width) / 2) + 0.5

        lock.lock()
        //  never feed NaN/inf coordinates to NSBezierPath
        if offset.isFinite && half.isFinite && scale.isFinite {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: CGFloat(offset), y: CGFloat(half - scale)))
            path.line(to: NSPoint(x: CGFloat(offset), y: CGFloat(half - scale - 8)))
            fsk = path
        }
        lock.unlock()
    }

    override func drawObjects() {
        scaleColor?.set()
        if let axis = axis, !axis.isEmpty { axis.stroke() }
        fskColor?.set()                                     // not in base class
        if let fsk = fsk, !fsk.isEmpty { fsk.stroke() }     // not in base class
    }

    //  Extended Crossed Ellipse FSK spectrum
    //  (renamed from the C `spectrum:` method to avoid colliding with the
    //   `spectrumFFT` stored property; Swift cannot share the name.)
    private func computeSpectrum(_ pipe: CMTappedPipe) {
        guard let stream = pipe.stream() else { return }
        guard let data = stream.pointee.array else { return }
        guard let sp = spectrumFFT else { return }

        CMPerformFFT(sp, data, &freq)

        //  512 point transform, 128 samples == 2756 Hz
        var norm: Float = 0.001
        for i in 0..<128 {
            let sum = freq[i + 14]           // 2210 Hz is at (64+38.64)-14
            freq[i] = sum
            if sum > norm { norm = sum }
        }
        norm = 400.0 / norm

        var spec = [UInt32](repeating: 0, count: 128)
        var specFade = [UInt32](repeating: 0, count: 128)
        for i in 0..<128 {
            avgfreq[i] = avgfreq[i] * 0.8 + freq[i] * 0.2
            var offset = Int(ceTruncInt(avgfreq[i] * norm))
            if offset > 255 { offset = 255 }
            if offset < 0 { offset = 0 }     // guard index (C clamps only the high side)
            spec[i] = intensity[offset]
            specFade[i] = intensityFade[offset]
        }

        //  display spectrum (two scanlines of memory, top line has persistence)
        //  width is 140, so supports a 128 wide spectrum
        let w = Int(width)
        let y = (Int(height) - 8) * w + (w / 2) - 64
        let width2 = 2 * w
        guard let px = pixel else { return }
        if depth >= 24 {
            var pix = px + y
            for i in 0..<128 {
                pix[w] = spec[i]
                pix[0] = specFade[i]
                pix[width2] = specFade[i]
                pix += 1
            }
        } else {
            let base = UnsafeMutableRawPointer(px).assumingMemoryBound(to: UInt16.self)
            var spix = base + y
            for i in 0..<128 {
                spix[w] = UInt16(truncatingIfNeeded: spec[i])
                let f = UInt16(truncatingIfNeeded: specFade[i])
                spix[0] = f
                spix[width2] = f
                spix += 1
            }
        }
    }

    @objc(importDataInMainThread:)
    override func importDataInMainThread(_ pipe: CMPipe) {
        if lock.try() {
            importDataIIR(unsafeDowncast(pipe, to: CMTappedPipe.self))
            displayMux += 1
            if (displayMux & 3) == 0 {
                computeSpectrum(unsafeDowncast(pipe, to: CMTappedPipe.self))   // not in base class
                self.needsDisplay = true
                displayMux = 0
            }
            lock.unlock()
        }
    }

    //  assume data is 11025, 1 channel
    @objc(importData:)
    override func importData(_ pipe: CMPipe) {
        if modem == nil { return }
        self.performSelector(onMainThread: #selector(importDataInMainThread(_:)), with: pipe, waitUntilDone: false)
    }
}
