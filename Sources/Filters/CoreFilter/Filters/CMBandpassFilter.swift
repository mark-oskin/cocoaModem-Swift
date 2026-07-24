//
//  CMBandpassFilter.swift
//  Filter (CoreModem)
//
//  Created by Kok Chen on 10/24/05
//	(ported from cocoaModem, original file dated Thu Jun 10 2004)
//  Swift port of CMBandpassFilter.{h,m}.  Windowed-sinc bandpass FIR.
//

import Foundation

@objc(CMBandpassFilter)
class CMBandpassFilter: CMFilter {

    internal var lowCutoff: Float
    internal var highCutoff: Float

    override init() {
        lowCutoff = 0.0
        highCutoff = 0.0
        super.init()
        lowCutoff = 0.0
        highCutoff = 0.0
        fir = nil
        filter = nil
        setLowCutoff(1960.0, highCutoff: 2460.0, length: 128)
    }

    @objc(initLowCutoff:highCutoff:length:)
    init(lowCutoff low: Float, highCutoff high: Float, length len: Int32) {
        lowCutoff = 0.0
        highCutoff = 0.0
        super.init()
        fir = nil
        filter = nil
        setLowCutoff(low, highCutoff: high, length: len)
    }

    @objc(updateLowCutoff:highCutoff:)
    func updateLowCutoff(_ low: Float, highCutoff high: Float) {
        setLowCutoff(low, highCutoff: high, length: n)
    }

    @objc(setLowCutoff:highCutoff:length:)
    func setLowCutoff(_ low: Float, highCutoff high: Float, length len: Int32) {
        var low = low
        var high = high

        if high < low {
            //  sanity check
            let temp = high
            high = low
            low = temp
        }
        if low < 1.0 || (low == lowCutoff && high == highCutoff) { return }

        let oldlen = n
        n = len
        lowCutoff = low
        highCutoff = high
        let center: Float = (low + high) * 0.5
        let f: Float = Float(0.5 * Double(center) * Double(n) / CMFs)
        let w: Float = Float(0.5 * Double(high - low) * Double(n) / CMFs)   //  bandwidth of sinc

        if oldlen != n {
            if let fir = fir { free(fir) }
            fir = malloc(Int(n) * MemoryLayout<Float>.stride)?.assumingMemoryBound(to: Float.self)
        }
        guard let fir = fir else { return }

        var sum: Float = 0
        for i in 0..<Int(n) {
            let t: Float = Float(n / 2)
            let x: Float = Float((Double(i) + 0.5 - Double(t)) / Double(t))
            let baseband: Float = Float(CMModifiedBlackmanWindow(Int32(i), n) * CMSinc(Int32(i), n, Double(w)))
            sum += baseband
            fir[i] = Float(Double(baseband) * sin(2.0 * CMPi * Double(f) * Double(x)))
        }
        let scale: Float = 2 / sum
        for i in 0..<Int(n) { fir[i] *= scale }

        if filter == nil {
            filter = CMFIRFilter(fir, n)
        } else {
            CMUpdateFIRFilter(filter, fir, n)
        }
    }
}
