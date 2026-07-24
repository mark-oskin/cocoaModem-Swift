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
//  vcoChangedTo: is delivered to a duck-typed delegate (an id in the original).
//  The argument is a float, which cannot be passed through -perform:withObject:,
//  so the selector is invoked through its IMP with an exact @convention(c)
//  signature -- this mirrors the Objective-C respondsToSelector: guard exactly.
//

import Foundation

@objc(CMPCO)
class CMPCO: CMNCO {

    var carrier: Double = 0
    var frequency: Float = 0
    weak var delegateRef: AnyObject?

    override init() {
        super.init()
        carrier = 1000.0 * kPeriod / kCMFs
        frequency = 1000
        scale = 1.0
        delegateRef = nil
    }

    @objc(setCarrier:)
    func setCarrier(_ freq: Float) {
        carrier = Double(freq) * kPeriod / kCMFs
        frequency = freq
    }

    @objc(frequency)
    func frequencyValue() -> Float {
        return Float(carrier * kCMFs / kPeriod)
    }

    @objc(tune:)
    func tune(_ freq: Float) {
        carrier += Double(freq) * kPeriod / kCMFs
        vcoChanged(to: Float(carrier * kCMFs / kPeriod))
    }

    @objc(tune:phase:)
    func tune(_ freq: Float, phase angle: Float) {
        carrier += Double(freq) * kPeriod / kCMFs
        theta += Double(angle) * kPeriod / 360.0
        if theta >= kPeriod { theta -= kPeriod }
    }

    @objc(adjustPhase:)
    func adjustPhase(_ angle: Float) {
        theta += Double(angle) * kPeriod / 360.0
        if theta >= kPeriod { theta -= kPeriod }
    }

    @objc(nextVCOPair)
    func nextVCOPair() -> CMAnalyticPair {
        var re: Double = 0
        var im: Double = 0
        sin(&re, cos: &im, delta: carrier)
        return CMAnalyticPair(re: Float(re), im: Float(im))
    }

    @objc(nextVCOMixedPair:)
    func nextVCOMixedPair(_ v: Float) -> CMAnalyticPair {
        var re: Double = 0
        var im: Double = 0
        sin(&re, cos: &im, delta: carrier)
        return CMAnalyticPair(re: Float(re * Double(v)), im: Float(im * Double(v)))
    }

    @objc(nextSample)
    func nextSample() -> Double {
        var i: Double = 0
        var q: Double = 0
        sin(&q, cos: &i, delta: carrier)
        return q
    }

    //  delegates
    @objc(setDelegate:)
    func setDelegate(_ inDelegate: AnyObject?) {
        delegateRef = inDelegate
    }

    @objc(delegate)
    func delegate() -> AnyObject? {
        return delegateRef
    }

    @objc(vcoChangedTo:)
    func vcoChanged(to vcoFreq: Float) {
        guard let d = delegateRef as? NSObject else { return }
        let sel = NSSelectorFromString("vcoChangedTo:")
        if d.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, Float) -> Void
            let imp = d.method(for: sel)
            let fn = unsafeBitCast(imp, to: Fn.self)
            fn(d, sel, vcoFreq)
        }
    }
}
