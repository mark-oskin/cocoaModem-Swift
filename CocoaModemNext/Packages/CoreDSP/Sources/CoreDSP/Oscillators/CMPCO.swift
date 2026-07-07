//
//  CMPCO.swift
//  CoreModem
//
//  Created by Kok Chen on 11/02/05.
//  Based on cocoaModem, original file dated Mon Aug 09 2004.
//  Swift port of CMPCO.m.
//
//  Phase Controlled Oscillator.  Subclass of CMNCO.  The carrier is a phase
//  increment (delta) accumulated by the inherited CMNCO sine engine.
//

import Foundation

protocol CMPCODelegate: AnyObject {
    func vcoChanged(to freq: Float)
}

class CMPCO: CMNCO {

    var carrier: Double = 0
    var frequency: Float = 0
    weak var delegateRef: CMPCODelegate?

    override init() {
        super.init()
        carrier = 1000.0 * kPeriod / kCMFs
        frequency = 1000
        scale = 1.0
        delegateRef = nil
    }

    func setCarrier(_ freq: Float) {
        carrier = Double(freq) * kPeriod / kCMFs
        frequency = freq
    }

    func frequencyValue() -> Float {
        return Float(carrier * kCMFs / kPeriod)
    }

    func tune(_ freq: Float) {
        carrier += Double(freq) * kPeriod / kCMFs
        vcoChanged(to: Float(carrier * kCMFs / kPeriod))
    }

    func tune(_ freq: Float, phase angle: Float) {
        carrier += Double(freq) * kPeriod / kCMFs
        theta += Double(angle) * kPeriod / 360.0
        if theta >= kPeriod { theta -= kPeriod }
    }

    func adjustPhase(_ angle: Float) {
        theta += Double(angle) * kPeriod / 360.0
        if theta >= kPeriod { theta -= kPeriod }
    }

    func nextVCOPair() -> CMAnalyticPair {
        var re: Double = 0
        var im: Double = 0
        sin(&re, cos: &im, delta: carrier)
        return CMAnalyticPair(re: Float(re), im: Float(im))
    }

    func nextVCOMixedPair(_ v: Float) -> CMAnalyticPair {
        var re: Double = 0
        var im: Double = 0
        sin(&re, cos: &im, delta: carrier)
        return CMAnalyticPair(re: Float(re * Double(v)), im: Float(im * Double(v)))
    }

    func nextSample() -> Double {
        var i: Double = 0
        var q: Double = 0
        sin(&q, cos: &i, delta: carrier)
        return q
    }

    //  delegates
    func setDelegate(_ inDelegate: CMPCODelegate?) {
        delegateRef = inDelegate
    }

    func delegate() -> CMPCODelegate? {
        return delegateRef
    }

    func vcoChanged(to vcoFreq: Float) {
        delegateRef?.vcoChanged(to: vcoFreq)
    }
}
