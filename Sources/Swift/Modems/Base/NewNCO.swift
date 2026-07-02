//
//  NewNCO.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 7/20/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of NewNCO.m.
//
//  v0.73 Subclassed CMNCO to allow start of transmission to be at 0 phase.
//  Unlike CMNCO, the sine is computed from the current phase *before* the phase
//  is incremented.
//

import Foundation

@objc(NewNCO)
class NewNCO: CMNCO {

    @objc(sin:)
    override func sin(_ delta: Double) -> Float {
        var t = cmPhaseTrunc(theta)
        if Double(t) > kPeriod { t -= Int32(kPeriod) }

        let mst = cmTableIndex(t >> kBits)
        let lst = cmTableIndex(t & kMask)
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        let s = mssin[mst] * lscos[lst] + mscos[mst] * lssin[lst]
        let p = Float(Double(s) * scale)

        //  increment after computing sine
        theta += delta
        let th = theta
        if th > kPeriod { theta = th - kPeriod }
        return p
    }

    @objc(cos:)
    override func cos(_ delta: Double) -> Float {
        var t = cmPhaseTrunc(theta)
        if Double(t) > kPeriod { t -= Int32(kPeriod) }

        let mst = cmTableIndex(t >> kBits)
        let lst = cmTableIndex(t & kMask)
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        let s = mscos[mst] * lscos[lst] - mssin[mst] * lssin[lst]
        let p = Float(Double(s) * scale)

        theta += delta
        let th = theta
        if th > kPeriod { theta = th - kPeriod }
        return p
    }

    @objc(resetPhase)
    func resetPhase() {
        theta = 0
    }
}
