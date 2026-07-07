//
//  CMPSKMatchedFilter.swift
//  CoreDSP
//
//  PSK matched filter / DPSK bit estimator. Produces BPSK / QPSK bit
//  decisions from Fs/16 analytic pairs fed in through bpsk(_:imag:bitPhase:)
//  / qpsk(_:imag:bitPhase:) (the PSK demodulator drives these directly).
//
//  The DSP-critical arithmetic (ring buffers, raised-cosine kernels, the
//  convolutional QPSK decode table) is preserved verbatim from the original
//  port. The delegate, originally Objective-C duck-typing (responds(to:) +
//  unsafeBitCast), is a plain Swift protocol here.
//

import Foundation

let RING: Int32 = 0x1f

private let piConst = 3.141592653589793
private let twopi = 3.1415926535 * 2

//  QPSK31 decode table (was "static char QPSKTable[1024]").
let QPSKTable: [Int8] = [
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]

public protocol CMPSKMatchedFilterDelegate: AnyObject {
    func matchedFilterUpdateVCOPhase(_ ang: Float)
    func matchedFilterReceivedBit(_ bit: Int32)
}

public final class CMPSKMatchedFilter {

    internal var iMatched: Float = 0, qMatched: Float = 0
    internal var iPulse: Float = 0, qPulse: Float = 0
    internal var iMid: Float = 0, qMid: Float = 0
    internal var bitPhase: Int32 = 0, midBit: Int32 = 0
    internal var delta: Float = 0          // most recent phase deviation

    internal var matchedI = [Float](repeating: 0, count: Int(RING) + 1)
    internal var matchedQ = [Float](repeating: 0, count: Int(RING) + 1)
    internal var pulseI = [Float](repeating: 0, count: Int(RING) + 1)
    internal var pulseQ = [Float](repeating: 0, count: Int(RING) + 1)
    internal var midI = [Float](repeating: 0, count: Int(RING) + 1)
    internal var midQ = [Float](repeating: 0, count: Int(RING) + 1)
    internal var phase = [Float](repeating: 0, count: 2)
    internal var kernel = [Float](repeating: 0, count: 64)
    internal var pulse = [Float](repeating: 0, count: 64)
    internal var ring: Int32 = 0

    internal var iLast: Float = 0, qLast: Float = 0
    internal var convolutionRegister: Int32 = 0
    internal var qpskTable = [Int8](repeating: 0, count: 1024)

    public weak var delegate: CMPSKMatchedFilterDelegate?

    public init() {
        //  raised cosine kernel
        let period = 11025.0 / 16.0 / 31.25
        midBit = Int32(period / 2)
        for i in 0..<64 {
            kernel[i] = 0
            let p = Double(i) / period
            if p < 1.0 { kernel[i] = Float((1.0 - cos(p * 2 * 3.1415926)) * 0.5) }
        }
        var sum: Float = 0
        for i in 0..<64 { sum += kernel[i] }
        for i in 0..<64 { kernel[i] /= sum }

        //  narrow raised cosine kernel (60% the width of a bit period)
        for i in 0..<64 {
            pulse[i] = 0
            let p = Double(i) / period
            if p > 0.2 && p < 0.8 { pulse[i] = Float((1.0 - cos((p - 0.2) * 2 * 3.1415926535 / 0.6)) * 0.5) }
        }
        sum = 0
        for i in 0..<64 { sum += pulse[i] }
        for i in 0..<64 { pulse[i] /= sum }

        iLast = 1.0; qLast = 1.0
        qpskTable = QPSKTable
    }

    private func bpskEstimate(_ bufI: inout [Float], imag bufQ: inout [Float]) -> Float {
        let p0 = Int(ring)
        let p1 = Int((ring &+ RING) & RING)         //  p0-1
        let p2 = Int((ring &+ RING &- 1) & RING)    //  p0-2
        //  establish reference vector from three vectors
        let pI = bufI[p2]
        let pQ = bufQ[p2]
        var refI = pI
        var refQ = pQ
        var g: Float = ((pI * bufI[p1] + pQ * bufQ[p1]) < 0) ? -1 : 1
        refI += bufI[p1] * g
        refQ += bufQ[p1] * g
        g = ((pI * bufI[p0] + pQ * bufQ[p0]) < 0) ? -1 : 1
        refI += bufI[p0] * g
        refQ += bufQ[p0] * g

        let dot = refI * bufI[p1] + refQ * bufQ[p1]
        return dot
    }

    //  estimate the phase angle from a combination of matched filter, narrow matched filter and a single mid bit sample
    private func processBpskVector() -> Int32 {
        matchedI[Int(ring)] = iMatched
        matchedQ[Int(ring)] = qMatched
        var matchedBit: Float = 0.5 * bpskEstimate(&matchedI, imag: &matchedQ)

        pulseI[Int(ring)] = iPulse
        pulseQ[Int(ring)] = qPulse
        matchedBit += 1.0 * bpskEstimate(&pulseI, imag: &pulseQ)

        midI[Int(ring)] = iMid
        midQ[Int(ring)] = qMid
        matchedBit += 0.1 * bpskEstimate(&midI, imag: &midQ)

        let result: Int32 = (matchedBit > 0.0) ? 1 : 0
        receivedBit(result)

        ring = (ring &+ 1) & RING
        return result
    }

    //  estimate the phase angle from a narrow matched filter
    private func processQpskVector() -> Int32 {
        let iLastRotated = -qLast
        let qLastRotated = iLast

        let dot = iLast * iPulse + qLast * qPulse
        let dotRotated = iLastRotated * iPulse + qLastRotated * qPulse

        let symbol: Int32
        if abs(dot) > abs(dotRotated) {
            symbol = (dot > 0) ? 0 : 2
        } else {
            symbol = (dotRotated > 0) ? 1 : 3
        }
        convolutionRegister = ((convolutionRegister &<< 2) | symbol) & 0x3ff
        let result = Int32(qpskTable[Int(convolutionRegister)])
        receivedBit(result)

        iLast = iPulse
        qLast = qPulse
        ring = (ring &+ 1) & RING
        return result
    }

    public func phaseError() -> Float {
        if delta > 0 { return delta - 3.1415926 }
        return delta + 3.1415926
    }

    private func updateVCOPhase(_ ang: Float) {
        delegate?.matchedFilterUpdateVCOPhase(ang)
    }

    private func receivedBit(_ bit: Int32) {
        delegate?.matchedFilterReceivedBit(bit)
    }

    //  new analytic pair at Fs/16; `start` flags the estimated boundary between data bits
    public func bpsk(_ real: Float, imag: Float, bitPhase start: Bool) -> Int32 {
        var h = kernel[Int(bitPhase & 0x3f)]
        iMatched += real * h
        qMatched += imag * h

        h = pulse[Int(bitPhase & 0x3f)]
        iPulse += real * h
        qPulse += imag * h

        bitPhase += 1
        var result: Int32 = 0

        if start {
            result = processBpskVector()
            iMatched = 0; qMatched = 0; iPulse = 0; qPulse = 0
            bitPhase = 0
        }
        if delegate != nil && bitPhase == midBit {
            iMid = real
            qMid = imag
            phase[0] = atan2f(imag, real)
            delta = phase[0] - phase[1]
            if Double(delta) > piConst { delta = Float(twopi - Double(delta)) }
            else if Double(delta) < -piConst { delta = Float(twopi + Double(delta)) }
            updateVCOPhase(delta)
            phase[1] = phase[0]
        }
        return result
    }

    public func qpsk(_ real: Float, imag: Float, bitPhase start: Bool) -> Int32 {
        let h = pulse[Int(bitPhase & 0x3f)]
        iPulse += real * h
        qPulse += imag * h

        bitPhase += 1
        var result: Int32 = 0

        if start {
            result = processQpskVector()
            iPulse = 0; qPulse = 0
            bitPhase = 0
        }
        if delegate != nil && bitPhase == midBit {
            iMid = real
            qMid = imag
            phase[0] = atan2f(imag, real)
            delta = phase[0] - phase[1]
            if Double(delta) > piConst { delta = Float(twopi - Double(delta)) }
            else if Double(delta) < -piConst { delta = Float(twopi + Double(delta)) }
            updateVCOPhase(delta)
            phase[1] = phase[0]
        }
        return result
    }
}
