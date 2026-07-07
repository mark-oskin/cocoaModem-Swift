//
//  CMLowpassFilter.swift
//  Filter (CoreModem)
//
//  Created by Kok Chen on Sun Aug 15 2004.
//  Swift port of CMLowpassFilter.{h,m}.  Windowed-sinc lowpass FIR.
//  (-importData: is inherited unchanged from CMFilter.)
//

import Foundation

class CMLowpassFilter: CMFilter {

    internal var cutoff: Float

    override init() {
        cutoff = 0.0
        super.init()
        cutoff = 0.0
        if let fir = fir { free(fir) }          //  v0.80l was malloced in super class
        fir = nil
        filter = nil
        setCutoff(300.0, length: 64)
    }

    init(cutoff low: Float, length len: Int32) {
        cutoff = 0.0
        super.init()
        cutoff = 0.0
        if let fir = fir { free(fir) }          //  v0.80l was malloced in super class
        fir = nil
        filter = nil
        setCutoff(low, length: len)
    }

    func updateCutoff(_ low: Float) {
        setCutoff(low, length: n)
    }

    func setCutoff(_ low: Float, length len: Int32) {
        var low = low

        if low < 1.0 { low = 1.0 } else if Double(low) > CMFs / 2 { low = Float(CMFs / 2) }
        if low == cutoff { return }

        n = len
        cutoff = low
        let w: Float = Float(0.5 * Double(low) * Double(n) / CMFs)   //  bandwidth of sinc

        if let fir = fir { free(fir) }
        fir = malloc(Int(n) * MemoryLayout<Float>.stride)?.assumingMemoryBound(to: Float.self)
        guard let fir = fir else { return }

        var sum: Float = 0
        for i in 0..<Int(n) {
            let baseband: Float = Float(CMModifiedBlackmanWindow(Int32(i), n) * CMSinc(Int32(i), n, Double(w)))
            sum += baseband
            fir[i] = baseband
        }
        let scale: Float = 1 / sum
        for i in 0..<Int(n) { fir[i] = fir[i] * scale }

        CMDeleteFIR(filter)
        filter = CMFIRFilter(fir, n)
    }
}
