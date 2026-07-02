//
//  VCO8k.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/13/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//  Swift port of VCO8k.m.
//
//  Phase Controlled Oscillator that runs at an 8000 samples/sec rate instead of
//  the default CMFs (11025).  Overrides the carrier <-> frequency conversions to
//  use the local 8000 Hz rate; everything else is inherited from CMPCO.
//

import Cocoa

private let kVCO8kFs: Double = 8000.0    //  use 8000 samples/sec rate

@objc(VCO8k)
class VCO8k: CMPCO {

    override init() {
        super.init()
        carrier = 1000.0 * kPeriod / kVCO8kFs
        scale = 1.0
        delegateRef = nil
    }

    @objc(setCarrier:)
    override func setCarrier(_ freq: Float) {
        carrier = Double(freq) * kPeriod / kVCO8kFs
    }

    @objc(frequency)
    override func frequencyValue() -> Float {
        return Float(carrier * kVCO8kFs / kPeriod)
    }

    @objc(tune:)
    override func tune(_ freq: Float) {
        carrier += Double(freq) * kPeriod / kVCO8kFs
        vcoChanged(to: Float(carrier * kVCO8kFs / kPeriod))
    }

    @objc(tune:phase:)
    override func tune(_ freq: Float, phase angle: Float) {
        carrier += Double(freq) * kPeriod / kVCO8kFs
        theta += Double(angle) * kPeriod / 360.0
        if theta >= kPeriod { theta -= kPeriod }
    }
}
