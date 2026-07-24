//
//  ParametricEqualizer.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/21/07.
//  Swift port of ParametricEqualizer.m.
//

import Foundation
import Accelerate

//  C struct kept identical (float low/high/value).  AMDemodulator.swift builds
//  an array of these and passes a pointer into init(_:ranges:order:).
struct ParametricRange {
    var low: Float
    var high: Float
    var value: Float
}

@objc(ParametricEqualizer)
class ParametricEqualizer: NSObject {

    //  This is DSP code: floats are truncated toward zero to int the way C does
    //  (never trapping), so guard the conversion the way DisplayColor.cInt does.
    @inline(__always)
    private static func cInt(_ x: Float) -> Int {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int(Int32.max) }
        if t <= -2147483648.0 { return Int(Int32.min) }
        return Int(t)
    }

    private var fir: UnsafeMutablePointer<CMFIR>?
    private var range = [ParametricRange](repeating: ParametricRange(low: 0, high: 0, value: 0), count: 64)
    private var ranges: Int32 = 0
    private var taps: Int32 = 0
    private var window: UnsafeMutablePointer<Float>?

    //  Parametric Equalizer -- max of 64 ranges
    init?(_ rangeArray: UnsafeMutablePointer<ParametricRange>?, ranges n: Int32, order: Int32) {
        super.init()
        var count = n
        if count > 64 { count = 64 }
        ranges = count
        taps = order
        if let rangeArray = rangeArray {
            for i in 0..<Int(count) { range[i] = rangeArray[i] }
        }
        window = CMMakeBlackmanWindow(order)
        fir = CMFIRLowpassFilter(100 /* not important */, Float(CMFs), order)
        designEqualizer()
    }

    deinit {
        //  window is a malloc'd buffer owned by this object (ARC won't free it).
        //  filter is intentionally not freed here: filter() hands the CMFIR* to
        //  the caller (AMDemodulator), which keeps using it, and CoreFilter has
        //  no public deleter -- so this mirrors the original (leaked) lifetime.
        if let window = window { free(window) }
    }

    private func designEqualizer() {
        guard let filter = fir, let window = window else { return }

        //  symmetric spectrum, OK to use forward transform
        let fft = FFTForward(9, false)

        var inBufI = [Float](repeating: 0, count: 512)
        var inBufQ = [Float](repeating: 0, count: 512)
        var outBufI = [Float](repeating: 0, count: 512)
        var outBufQ = [Float](repeating: 0, count: 512)

        let scale: Float = 256 / (11025 / 2.0)

        var gain: Float = 0
        for i in 0..<Int(ranges) {
            let low = ParametricEqualizer.cInt(range[i].low * scale)
            let high = ParametricEqualizer.cInt(range[i].high * scale)
            let value = fabsf(range[i].value)

            var adjustedGain = value
            if range[i].low > 500 { adjustedGain *= 0.5 }
            if range[i].low > 1000 { adjustedGain *= 0.5 }
            if adjustedGain > gain { gain = adjustedGain }

            var j = low
            while j < high {
                if j >= 0 && j < 512 { inBufI[j] = value }
                if j != 0 && (512 - j) >= 0 && (512 - j) < 512 { inBufI[512 - j] = value }
                j += 1
            }
        }

        inBufI.withUnsafeMutableBufferPointer { pInI in
            inBufQ.withUnsafeMutableBufferPointer { pInQ in
                outBufI.withUnsafeMutableBufferPointer { pOutI in
                    outBufQ.withUnsafeMutableBufferPointer { pOutQ in
                        var cin = DSPSplitComplex(realp: pInI.baseAddress!, imagp: pInQ.baseAddress!)
                        var cout = DSPSplitComplex(realp: pOutI.baseAddress!, imagp: pOutQ.baseAddress!)
                        CMPerformComplexFFT(fft, &cin, &cout)
                    }
                }
            }
        }

        gain = 1.1 / (gain * 256.0)

        let mid = Int(filter.pointee.activeTaps) / 2
        let active = Int(filter.pointee.activeTaps)
        //  NOTE: the original assigns kernel[mid] then immediately zeroes the whole
        //  kernel (so that first assignment is overwritten).  Preserved verbatim.
        filter.pointee.kernel[mid] = outBufI[0]
        for i in 0..<active { filter.pointee.kernel[i] = 0 }
        for i in 1..<mid {
            let v = outBufI[i] * gain
            filter.pointee.kernel[mid + i] = v
            filter.pointee.kernel[mid - i] = v
        }
        filter.pointee.kernel[0] = 0
        for i in 0..<active { filter.pointee.kernel[i] *= window[i] }
    }

    @objc(setRange:to:)
    func setRange(_ index: Int32, to value: Float) {
        range[Int(index)].value = value
        designEqualizer()
    }

    func filter() -> UnsafeMutablePointer<CMFIR>? {
        return fir
    }
}
