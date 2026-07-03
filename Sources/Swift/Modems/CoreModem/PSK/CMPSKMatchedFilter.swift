//
//  CMPSKMatchedFilter.swift
//  CoreModem
//
//  Created by Kok Chen on 11/02/05
//	Based on cococaModem, original file dated Wed Aug 11 2004.
//  Swift port of CMPSKMatchedFilter.m.
//
//  PSK matched filter / DPSK bit estimator.  Subclass of CMTappedPipe.  Produces
//  BPSK / QPSK bit decisions from Fs/16 analytic pairs fed in through
//  -bpsk:imag:bitPhase: / -qpsk:imag:bitPhase: (the PSK receiver drives these
//  directly; -importData: is unused).
//
//  Port notes:
//   * Fixed C arrays that must expose a stable pointer (demodulated, mfStream)
//     are heap UnsafeMutablePointers freed in deinit (the C had no -dealloc; this
//     mirrors the inline object storage).  Ring buffers (matchedI/Q, pulseI/Q,
//     midI/Q, kernel, pulse, phase) are Swift [Float] passed to the estimators
//     via &array; qpskTable is [CChar].
//   * The convolution register / ring index shifts and masks use the wrapping
//     operators (&<<, &+) and mask before subscripting, as in the C.
//   * `pi` is the Carbon fp.h const (M_PI); twopi is the C's own 3.1415926535*2
//     literal (NOT 2*M_PI) -- preserved exactly.  Phase wrap math is done in
//     Double then stored to the Float `delta`, mirroring C promotion.
//   * The dead MAKEQPSKTABLE generator branch (hammingWeight/generateQPSKTable)
//     is not ported; only the static QPSKTable is used (as in the shipped build).
//   * `delegate` collides with the -delegate accessor selector, so the property
//     keeps the name and the accessor is delegateObject() (@objc(delegate)).
//

import Foundation

let RING: Int32 = 0x1f

private let pi = 3.141592653589793
private let twopi = 3.1415926535 * 2

//  QPSK31 decode table (was "static char QPSKTable[1024]").
let QPSKTable: [CChar] = [
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

@objc(CMPSKMatchedFilter)
class CMPSKMatchedFilter: CMTappedPipe {

    internal let demodulated: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        p.initialize(repeating: 0, count: 512)
        return p
    }()
    internal let mfStream: UnsafeMutablePointer<CMDataStream> = {
        let p = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        p.initialize(to: CMDataStream())
        return p
    }()

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
    internal var qpskTable = [CChar](repeating: 0, count: 1024)

    weak var delegate: AnyObject?

    override init() {
        super.init()
        delegate = nil

        //  set up DataStream
        data = mfStream
        mfStream.pointee.array = demodulated
        mfStream.pointee.samplingRate = Float(11025.0 / 16)
        mfStream.pointee.samples = 256
        mfStream.pointee.components = 1
        mfStream.pointee.channels = 2

        iMatched = 0; qMatched = 0
        bitPhase = 0
        //  ring buffer
        ring = 0
        for i in 0..<(Int(RING) + 1) { matchedI[i] = matchedQ[i] }
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

        delta = 0

        iLast = 1.0; qLast = 1.0
        convolutionRegister = 0
        qpskTable = QPSKTable
    }

    deinit {
        demodulated.deallocate()
        mfStream.deallocate()
    }

    func bpskEstimate(_ bufI: UnsafeMutablePointer<Float>, imag bufQ: UnsafeMutablePointer<Float>) -> Float {
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

    /* local */
    //  estimate the phase angle from a combination of matched filter, narrow matched filter and a single mid bit sample
    func processBpskVector() -> Int32 {
        //  estmate from matched filter
        matchedI[Int(ring)] = iMatched
        matchedQ[Int(ring)] = qMatched
        var matchedBit: Float = 0.5 * bpskEstimate(&matchedI, imag: &matchedQ)

        //  estmate from narrow raised cosine
        pulseI[Int(ring)] = iPulse
        pulseQ[Int(ring)] = qPulse
        matchedBit += 1.0 * bpskEstimate(&pulseI, imag: &pulseQ)

        //  estimate from mid bit sample
        midI[Int(ring)] = iMid
        midQ[Int(ring)] = qMid
        matchedBit += 0.1 * bpskEstimate(&midI, imag: &midQ)

        let result: Int32 = (matchedBit > 0.0) ? 1 : 0
        receivedBit(result)

        //  update ring buffer indeces
        ring = (ring &+ 1) & RING
        return result
    }

    /* local */
    //  estimate the phase angle from a narrow matched filter
    func processQpskVector() -> Int32 {
        //  estmate delta from narrow raised cosine kernel
        let iLastRotated = -qLast
        let qLastRotated = iLast

        let dot = iLast * iPulse + qLast * qPulse
        let dotRotated = iLastRotated * iPulse + qLastRotated * qPulse

        let symbol: Int32
        if abs(dot) > abs(dotRotated) {
            //  0 or 180 degrees
            symbol = (dot > 0) ? 0 : 2
        } else {
            //  plus or minus 90 degrees
            symbol = (dotRotated > 0) ? 1 : 3
        }
        //  shift bits into shift register
        convolutionRegister = ((convolutionRegister &<< 2) | symbol) & 0x3ff
        let result = Int32(qpskTable[Int(convolutionRegister)])
        receivedBit(result)

        //  save vector for next bit
        iLast = iPulse
        qLast = qPulse
        //  update ring buffer indeces
        ring = (ring &+ 1) & RING
        return result
    }

    @objc(phaseError)
    func phaseError() -> Float {
        if delta > 0 { return delta - 3.1415926 }
        return delta + 3.1415926
    }

    //  send current phase to delegate
    @objc(updateVCOPhase:)
    func updateVCOPhase(_ ang: Float) {
        guard let d = delegate as? NSObject else { return }
        let sel = NSSelectorFromString("updateVCOPhase:")
        if d.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, Float) -> Void
            let fn = unsafeBitCast(d.method(for: sel), to: Fn.self)
            fn(d, sel, ang)
        }
    }

    //  send current phase to delegate
    @objc(receivedBit:)
    func receivedBit(_ bit: Int32) {
        guard let d = delegate as? NSObject else { return }
        let sel = NSSelectorFromString("receivedBit:")
        if d.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Void
            let fn = unsafeBitCast(d.method(for: sel), to: Fn.self)
            fn(d, sel, bit)
        }
    }

    //  new analytic pair at Fs/16
    //  start is a flag that indicates the estimated boundary between data bits
    @objc(bpsk:imag:bitPhase:)
    func bpsk(_ real: Float, imag: Float, bitPhase start: Bool) -> Int32 {
        //  integrate
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
            // dump
            iMatched = 0; qMatched = 0; iPulse = 0; qPulse = 0
            bitPhase = 0
        }
        //  no need to update phase if there is no delegate
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

    //  new analytic pair at Fs/16
    @objc(qpsk:imag:bitPhase:)
    func qpsk(_ real: Float, imag: Float, bitPhase start: Bool) -> Int32 {
        let h = pulse[Int(bitPhase & 0x3f)]
        iPulse += real * h
        qPulse += imag * h

        bitPhase += 1
        var result: Int32 = 0

        if start {
            result = processQpskVector()
            // dump
            iPulse = 0; qPulse = 0
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

    //  import data pipe is not used.  The PSK receiver calls -inPhase:quadrature:size:
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
    }

    @objc(delegate)
    func delegateObject() -> AnyObject? {
        return delegate
    }

    @objc(setDelegate:)
    func setDelegate(_ inDelegate: AnyObject?) {
        delegate = inDelegate
    }
}
