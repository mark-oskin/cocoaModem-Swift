//
//  PSKMatchedFilter.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 9/25/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//  Swift port of PSKMatchedFilter.m.
//
//  PSK31 matched filter with the Okunev DPSK demodulators and a k=5 convolution
//  (Viterbi) code for QPSK.  Subclass of CMPSKMatchedFilter.
//
//  Port notes:
//   * MatchedPair (a C {float i;float q;} in PSKMatchedFilter.h) becomes a Swift
//     struct (used only by this class tree).
//   * The `phaseError` ivar collides with the -phaseError accessor selector, so
//     the stored property is `phaseErrorValue` and the accessor keeps the
//     selector.  (LitePSKMatchedFilter, a subclass, uses `phaseErrorValue`.)
//   * `pi` is the Carbon fp.h const (M_PI); piBy2/twopi are the C's literals.
//     Phase-wrap comparisons are done in Double then stored to Float.
//   * OKUNEV is defined (as in the shipped build) so QPSK uses
//     processOkunevQpskVector.
//

import Foundation

//  C {float i; float q;} in PSKMatchedFilter.h
struct MatchedPair {
    var i: Float = 0
    var q: Float = 0
}

private let piBy2 = 3.1415926535 / 2
private let twopi = 3.1415926535 * 2
private let pi = 3.141592653589793

//	v0.96b
private func hann(_ t: Float, _ n: Int32, _ baudrate: Double) -> Float {
    let x = 2 * t / Float(n)
    return Float(0.5 - 0.5 * cos(Double(x) * 3.1415926))
}

private func sign(_ a: Float) -> Int32 {
    if a >= 0 { return 1 }
    return 0
}

private func sq1(_ p: Float) -> Float {
    return p * p
}

@objc(PSKMatchedFilter)
class PSKMatchedFilter: CMPSKMatchedFilter {

    internal var fec: ConvolutionCode?
    internal var quality: Float = 0, cosTheta: Float = 0
    internal var prevPhase: Float = 0, phaseErrorValue: Float = 0, averagePhaseError: Float = 0
    internal var phaseReportCycle: Int32 = 0

    override init() {
        super.init()
        quality = 1.0
        prevPhase = 0; phaseErrorValue = 0; averagePhaseError = 0
        phaseReportCycle = 0
        //  replace kernel
        //  sine kernel
        let period: Float = 32
        midBit = Int32(period / 2)

        //	half sine matched filter to PSK31 bit, Hann windowed
        //	(transmitter uses a sine window)
        for i in 0..<64 { kernel[i] = 0 }
        for i in 0..<32 {
            kernel[i] = Float(Double(hann(Float(i), 32, 3.1415926 / 32)) * pow(sin(Double(i) * 3.1415926 / 32.0), 0.25))
        }

        var sum: Float = 0.0
        for i in 0..<64 { sum += kernel[i] }
        for i in 0..<64 { kernel[i] /= sum }

        fec = ConvolutionCode(constraintLength: 5, generator: 0x19, generatorB: 0x17)
        fec?.setTrellisDepth(17)
        fec?.resetTrellis()
    }

    func processOkunevQpskVector() -> Int32 {
        //  estmate from matched filter
        matchedI[Int(ring)] = iMatched
        matchedQ[Int(ring)] = qMatched

        let p0 = Int(ring)
        var m0 = MatchedPair(); m0.i = matchedI[p0]; m0.q = matchedQ[p0]

        let p1 = Int((ring &+ RING) & RING)         //  p0-1
        var m1 = MatchedPair(); m1.i = matchedI[p1]; m1.q = matchedQ[p1]

        let p2 = Int((ring &+ RING &- 1) & RING)    //  p0-2
        var m2 = MatchedPair(); m2.i = matchedI[p2]; m2.q = matchedQ[p2]
        _ = m2

        let j1 = sign(m1.i * m0.q - m0.i * m1.q + m0.i * m1.i + m0.q * m1.q)
        let j2 = sign(m1.i * m0.i + m1.q * m0.q - m1.i * m0.q + m0.i * m1.q)
        let jx = j2 * 2 + j1        //  jx = 0 (180), j=1 (+90), j=2 (-90), j = 3 (0)

        //  hard decode
        var msb: Float = 0
        var lsb: Float = 0
        switch jx {
        case 0:
            // 180 degrees
            msb = 1; lsb = 0
        case 1:
            // +90 degrees
            msb = 0; lsb = 1
        case 2:
            // -90 degrees
            msb = 1; lsb = 1
        case 3:
            //  0 degrees
            msb = 0; lsb = 0
        default:
            break
        }

        let decodedBit = Float(1 - (fec?.decodeMSB(msb, lsb: lsb) ?? 0))
        let result: Int32 = (decodedBit > 0.5) ? 1 : 0
        receivedBit(result)

        //  update ring buffer indices
        ring = (ring &+ 1) & RING
        return result
    }

    //  new analytic pair at Fs/16
    @objc(qpsk:imag:bitSync:)
    func qpsk(_ real: Float, imag: Float, bitSync start: Bool) -> Int32 {
        var h = kernel[Int(bitPhase & 0x3f)]
        iMatched += real * h
        qMatched += imag * h

        h = pulse[Int(bitPhase & 0x3f)]
        iPulse += real * h
        qPulse += imag * h

        bitPhase += 1
        var result: Int32 = 0

        if start {
            result = processOkunevQpskVector()
            // dump
            iPulse = 0; qPulse = 0
            iMatched = 0; qMatched = 0
            bitPhase = 0
        }
        if delegate != nil && bitPhase == midBit {
            iMid = real
            qMid = imag
            //  compute absolute phase angle
            phase[0] = atan2f(imag, real)
            //  compute relative phase angle
            delta = phase[0] - phase[1]
            if Double(delta) > pi { delta = Float(twopi - Double(delta)) }
            else if Double(delta) < -pi { delta = Float(twopi + Double(delta)) }
            updateVCOPhase(delta)
            phase[1] = phase[0]
        }
        return result
    }

    //  The DPSK demodulators are taken from Y. Okunev, "Phase and Phase-difference Modulation in Digital Communications" Artech House, 1997.

    //  v0.57  2-chip decoder
    func bpskEstimate2(_ matchedPair: UnsafeMutablePointer<MatchedPair>) -> Float {
        let m0 = matchedPair[0]
        let m1 = matchedPair[1]
        let u = sq1(m1.i + m0.i) + sq1(m1.q + m0.q)
        let v = sq1(m1.i - m0.i) + sq1(m1.q - m0.q)
        if v > u { return -v }
        return u
    }

    //  v0.57  Okunev 3-chip decoder
    func bpskEstimate3(_ matchedPair: UnsafeMutablePointer<MatchedPair>) -> Float {
        let m0 = matchedPair[0]
        let m1 = matchedPair[1]
        let m2 = matchedPair[2]
        var v = sq1(m2.i + m1.i + m0.i) + sq1(m2.q + m1.q + m0.q)
        var u = sq1(m2.i - m1.i - m0.i) + sq1(m2.q - m1.q - m0.q)
        if u > v { v = u }

        u = sq1(m2.i - m1.i + m0.i) + sq1(m2.q - m1.q + m0.q)
        if u > v { return -u }
        u = sq1(m2.i + m1.i - m0.i) + sq1(m2.q + m1.q - m0.q)
        if u > v { return -u }

        return v
    }

    //  v0.57  4-chip Okunev
    func bpskEstimate4(_ matchedPair: UnsafeMutablePointer<MatchedPair>) -> Float {
        let m0 = matchedPair[0]
        let m1 = matchedPair[1]
        let m2 = matchedPair[2]
        let m3 = matchedPair[3]

        var v = sq1(m3.i + m2.i + m1.i + m0.i) + sq1(m3.q + m2.q + m1.q + m0.q)
        var u = sq1(m3.i - m2.i + m1.i + m0.i) + sq1(m3.q - m2.q + m1.q + m0.q)
        if u > v { v = u }

        u = sq1(m3.i + m2.i - m1.i - m0.i) + sq1(m3.q + m2.q - m1.q - m0.q)
        if u > v { v = u }

        u = sq1(m3.i - m2.i - m1.i - m0.i) + sq1(m3.q - m2.q - m1.q - m0.q)
        if u > v { v = u }

        u = sq1(m3.i + m2.i + m1.i - m0.i) + sq1(m3.q + m2.q + m1.q - m0.q)
        if u > v { return -u }
        u = sq1(m3.i + m2.i - m1.i + m0.i) + sq1(m3.q + m2.q - m1.q + m0.q)
        if u > v { return -u }
        u = sq1(m3.i - m2.i + m1.i - m0.i) + sq1(m3.q - m2.q + m1.q - m0.q)
        if u > v { return -u }
        u = sq1(m3.i - m2.i - m1.i + m0.i) + sq1(m3.q - m2.q - m1.q + m0.q)
        if u > v { return -u }

        return v
    }

    //  Use a blend of the Okunev 2-chip, 3-chip and 4-chip DPSK demodulators.
    override func bpskEstimate(_ bufI: UnsafeMutablePointer<Float>, imag bufQ: UnsafeMutablePointer<Float>) -> Float {
        var matchedPair = [MatchedPair](repeating: MatchedPair(), count: 4)

        let p0 = Int(ring)
        let ai = bufI[p0]; matchedPair[0].i = ai
        let aq = bufQ[p0]; matchedPair[0].q = aq

        let p1 = Int((ring &+ RING) & RING)         //  p0-1
        let bi = bufI[p1]; matchedPair[1].i = bi
        let bq = bufQ[p1]; matchedPair[1].q = bq

        let p2 = Int((ring &+ RING &- 1) & RING)    //  p0-2
        matchedPair[2].i = bufI[p2]
        matchedPair[2].q = bufQ[p2]

        let p3 = Int((ring &+ RING &- 2) & RING)    //  p0-3
        matchedPair[3].i = bufI[p3]
        matchedPair[3].q = bufQ[p3]

        let q1 = bpskEstimate2(&matchedPair)
        let q2 = bpskEstimate3(&matchedPair)
        let q3 = bpskEstimate4(&matchedPair)

        let dot = ai * bi + aq * bq
        let q = sqrt(dot * dot / ((ai * ai + aq * aq) * (bi * bi + bq * bq) + 0.0000001))
        if q < quality { quality = q }

        //  return weighted sum of the three demodulators
        return (0.5 * q1 + 0.3 * q2 + 0.7 * q3)
    }

    /* local v0.57 */
    override func processBpskVector() -> Int32 {
        //  update the matched filter sequence
        matchedI[Int(ring)] = iMatched
        matchedQ[Int(ring)] = qMatched

        let matchedBit = bpskEstimate(&matchedI, imag: &matchedQ)

        let result: Int32 = (matchedBit > 0.0) ? 1 : 0

        receivedBit(result)

        //  update ring buffer index
        ring = (ring &+ 1) & RING
        return result
    }

    //  v0.57  new analytic pair at 1000 s/s (32 samples per bit)
    @objc(bpsk:imag:bitSync:)
    func bpsk(_ real: Float, imag: Float, bitSync: Bool) -> Int32 {
        var result: Int32 = 0

        //  Matched filter input I/Q pair
        let h = kernel[Int(bitPhase & 0x3f)]        //  v0.88 sanity check
        iMatched += h * real
        qMatched += h * imag

        bitPhase += 1

        //  if bitSync is passed in from the client, we are ready to process this DPSK chip
        if bitSync {
            result = processBpskVector()
            // dump Matched Filter
            iMatched = 0; qMatched = 0
            bitPhase = 0
        }
        //  update phase information if the delegate accepts it (for phase indicator)
        if delegate != nil && bitPhase == 30 {
            let t = atan2f(imag, real)
            phaseErrorValue = prevPhase - t
            prevPhase = t

            if Double(phaseErrorValue) > piBy2 { phaseErrorValue = Float(Double(phaseErrorValue) - pi) }
            else if Double(phaseErrorValue) < -piBy2 { phaseErrorValue = Float(Double(phaseErrorValue) + pi) }
            if Double(phaseErrorValue) > piBy2 { phaseErrorValue = Float(Double(phaseErrorValue) - pi) }
            else if Double(phaseErrorValue) < -piBy2 { phaseErrorValue = Float(Double(phaseErrorValue) + pi) }
            averagePhaseError = averagePhaseError * 0.9 + phaseErrorValue * 0.1

            if phaseReportCycle == 1 { updateVCOPhase(averagePhaseError) }
            phaseReportCycle = (phaseReportCycle + 1) % 8
        }

        return result
    }

    @objc(phaseError)
    override func phaseError() -> Float {
        return phaseErrorValue
    }

    //  prototype for delegate
    @objc(receivedBit:quality:)
    func receivedBit(_ bit: Int32, quality: Float) {
    }

    //  send current phase to delegate
    @objc(receivedBit:)
    override func receivedBit(_ bit: Int32) {
        if let d = delegate as? NSObject {
            let sel = NSSelectorFromString("receivedBit:quality:")
            if d.responds(to: sel) {
                typealias Fn = @convention(c) (AnyObject, Selector, Int32, Float) -> Void
                let fn = unsafeBitCast(d.method(for: sel), to: Fn.self)
                fn(d, sel, bit, quality)
            }
        }
        //  reset the quality figure for the next character (1.0 = good, 0.0 = bad)
        quality = 1.0
    }
}
