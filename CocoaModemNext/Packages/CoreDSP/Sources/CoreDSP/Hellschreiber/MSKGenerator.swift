//
//  MSKGenerator.swift
//  CoreDSP
//
//  Swift port of MSKGenerator.swift (originally MSKGenerator.m), transplanted
//  verbatim from the old cocoaModem 2.0 Swift source. Minimum-shift-keying tone
//  generator, subclass of CMNCO (already ported, module-internal). The four MSK
//  phase quadrants are tracked by "cycle"; sinForModulation / cosForModulation
//  return the (unscaled) quarter-rate sine and cosine used by the Hell FM
//  modulator. kPeriod/kBits/kMask/cmPhaseTrunc/cmTableIndex/mssin/mscos/lssin/
//  lscos all already exist in this module (CMNCO.swift / CoreModem.swift) --
//  reused here, not redeclared.
//
//  Mechanical changes from the original: dropped `@objc(MSKGenerator)` / bare
//  `@objc` (no ObjC runtime in this package); otherwise unchanged.
//

import Foundation

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

    func setBaudRate(_ rate: Float) {
        baudRate = rate
        baudDelta = Double(baudRate) * kPeriod / kCMFs
        //  v0.33
        cycle = 0
        bitTheta = 0.0
    }

    func needNewBit() -> Bool {
        return needNewBitFlag
    }

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

    func sinForModulation() -> Float {
        let t = cmPhaseTrunc((bitTheta + Double(cycle) * kPeriod) * 0.25)
        let mst = cmTableIndex((t >> kBits) & kMask)
        let lst = cmTableIndex(t & kMask)
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        return mssin[mst] * lscos[lst] + mscos[mst] * lssin[lst]
    }

    func cosForModulation() -> Float {
        let t = cmPhaseTrunc((bitTheta + Double(cycle) * kPeriod) * 0.25)
        let mst = cmTableIndex((t >> kBits) & kMask)
        let lst = cmTableIndex(t & kMask)
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        return mscos[mst] * lscos[lst] - mssin[mst] * lssin[lst]
    }
}
