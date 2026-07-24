//
//  CMNCO.swift
//  CoreModem
//
//  Created by Kok Chen on 10/28/05.
//  Swift port of CMNCO.m.
//
//  Numerically controlled oscillator.  This is the root of the oscillator /
//  modulator tree (all 16 classes descend from CMNCO : NSObject).
//
//  The phase accumulators (theta, bitTheta) are C doubles.  The double->int
//  index conversion (C:  int t = th ;) is mirrored with a guarded truncation
//  (cmPhaseTrunc) so a NaN or out-of-range phase can never trap the way Swift's
//  checked Int(x) would.  The sine/cosine table indices are masked before
//  subscripting so a stray phase value can never read outside the 1024-entry
//  mssin/lssin/mscos/lscos tables (which live in CoreModem, still Objective-C,
//  reachable through the bridging header via PSKReceiver.h -> CoreModem.h).
//

import Foundation

//  ---- shared constants (were #defines in CMNCO.h) ----
//  10-bit half resolution tables
let kPeriod: Double = 262144.0
let kMask: Int32 = 0x3ff
let kBits: Int32 = 10

//  sampling rate (CMFs == 11025.0 in CoreFilterTypes.h).  Kept as a file-scope
//  constant to avoid depending on the imported macro.
let kCMFs: Double = 11025.0

//  C truncates a double to (signed) int toward zero.  The NCO phase is expected
//  to be in [0, kPeriod], but guard against NaN / overflow so we never trap.
@inline(__always)
func cmPhaseTrunc(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    let t = x.rounded(.towardZero)
    if t >= 2147483647.0 { return Int32.max }
    if t <= -2147483648.0 { return Int32.min }
    return Int32(t)
}

//  mask a table index into the 1024-entry sin/cos tables
@inline(__always)
func cmTableIndex(_ i: Int32) -> Int {
    return Int(i & 0x3ff)
}

@objc(CMNCO)
class CMNCO: NSObject {

    //  DDAs at the default sampling rate
    var theta: Double = 0
    var bitTheta: Double = 0
    var current: Double = 0
    var scale: Double = 0
    private var duration: Double = 0
    private var modulate: Int32 = 0

    var lock: NSLock!
    var producer: Int32 = 0
    var consumer: Int32 = 0

    override init() {
        super.init()
        theta = 0
        bitTheta = 0
        lock = NSLock()
        scale = 0.1
        producer = 0
        consumer = 0
        modulate = 0
    }

    @objc(setOutputScale:)
    func setOutputScale(_ value: Float) {
        scale = Double(value)
    }

    //  modulation DDA return true if changed
    @objc(modulation:)
    func modulation(_ delta: Double) -> Bool {
        bitTheta += delta
        let th = bitTheta
        if th > kPeriod {
            bitTheta = th - kPeriod
            return true
        }
        return false
    }

    //  use double angle formula to compute sin(t)
    //  NOTE: delta must be less than kPeriod and greater than or equal to 0
    @objc(sin:)
    func sin(_ delta: Double) -> Float {
        theta += delta
        var th = theta
        if th > kPeriod {
            th -= kPeriod
            theta = th
        }
        let t = cmPhaseTrunc(th)
        let mst = cmTableIndex(t >> kBits)
        let lst = cmTableIndex(t & kMask)
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        let s = mssin[mst] * lscos[lst] + mscos[mst] * lssin[lst]
        return Float(Double(s) * scale)
    }

    //  use double angle formula to compute cos(t)
    //  NOTE: delta must be less than kPeriod and greater than or equal to 0
    @objc(cos:)
    func cos(_ delta: Double) -> Float {
        theta += delta
        var th = theta
        if th > kPeriod {
            th -= kPeriod
            theta = th
        }
        let t = cmPhaseTrunc(th)
        let mst = cmTableIndex(t >> kBits)
        let lst = cmTableIndex(t & kMask)
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        let s = mscos[mst] * lscos[lst] - mssin[mst] * lssin[lst]
        return Float(Double(s) * scale)
    }

    @objc(sin:cos:delta:)
    func sin(_ sine: UnsafeMutablePointer<Double>, cos cosine: UnsafeMutablePointer<Double>, delta: Double) {
        theta += delta
        var th = theta
        if th > kPeriod {
            th -= kPeriod
            theta = th
            while th > kPeriod {
                th -= kPeriod
                theta = th
            }
        } else if th < 0 {
            th += kPeriod
            theta = th
            while th < kPeriod {
                th += kPeriod
                theta = th
            }
        }
        let t = cmPhaseTrunc(th)
        let mst = cmTableIndex(t >> kBits)
        let lst = cmTableIndex(t & kMask)

        //  v0.76 performance tune
        let sina = Double(mssin[mst])
        let cosa = Double(mscos[mst])
        let sinb = Double(lssin[lst])
        let cosb = Double(lscos[lst])
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        sine.pointee = (sina * cosb + cosa * sinb) * scale
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        cosine.pointee = (cosa * cosb - sina * sinb) * scale
    }
}
