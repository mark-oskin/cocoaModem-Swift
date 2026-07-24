//
//  MSKGenerator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 4/21/06.
//  Swift port of MSKGenerator.m.
//
//  Minimum-shift-keying tone generator.  Subclass of CMNCO.  The four MSK phase
//  quadrants are tracked by "cycle"; sinForModulation / cosForModulation return
//  the (unscaled) quarter-rate sine and cosine used by the Hell FM modulator.
//

import Foundation

@objc(MSKGenerator)
class MSKGenerator: CMNCO {

    private var needNewBitFlag: Bool = false
    private var baudRate: Float = 0
    private var baudDelta: Double = 0
    private var cycle: Int32 = 0

    override init() {
        super.init()
        needNewBitFlag = true
        cycle = 0
    }

    @objc(setBaudRate:)
    func setBaudRate(_ rate: Float) {
        baudRate = rate
        baudDelta = Double(baudRate) * kPeriod / kCMFs
        //  v0.33
        cycle = 0
        bitTheta = 0.0
    }

    @objc(needNewBit)
    func needNewBit() -> Bool {
        return needNewBitFlag
    }

    @objc(advanceBitSample)
    func advanceBitSample() -> Bool {
        bitTheta += baudDelta

        needNewBitFlag = (bitTheta >= kPeriod)
        if needNewBitFlag {
            cycle = (cycle + 1) & 0x3
            bitTheta -= kPeriod
            return true
        }
        return false
    }

    @objc(sinForModulation)
    func sinForModulation() -> Float {
        let t = cmPhaseTrunc((bitTheta + Double(cycle) * kPeriod) * 0.25)
        let mst = cmTableIndex((t >> kBits) & kMask)
        let lst = cmTableIndex(t & kMask)
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        return mssin[mst] * lscos[lst] + mscos[mst] * lssin[lst]
    }

    @objc(cosForModulation)
    func cosForModulation() -> Float {
        let t = cmPhaseTrunc((bitTheta + Double(cycle) * kPeriod) * 0.25)
        let mst = cmTableIndex((t >> kBits) & kMask)
        let lst = cmTableIndex(t & kMask)
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        return mscos[mst] * lscos[lst] - mssin[mst] * lssin[lst]
    }
}
