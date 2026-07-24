//
//  LitePSKMatchedFilter.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/19/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//  Swift port of LitePSKMatchedFilter.m.
//
//  Lightweight BPSK matched filter (2-chip Okunev only, no FEC / QPSK).
//  Subclass of PSKMatchedFilter; reports bits to a LitePSKDemodulator (Swift).
//
//  The C indexed kernel[bitPhase] without masking; Swift masks the index
//  (& 0x3f) so an out-of-range bitPhase can never trap -- identical for the
//  valid 0..63 range that the bit-sync keeps it in.
//

import Cocoa

private let piBy2 = 3.1415926535 / 2
private let pi = 3.141592653589793

private func sq1(_ p: Float) -> Float {
    return p * p
}

@objc(LitePSKMatchedFilter)
class LitePSKMatchedFilter: PSKMatchedFilter {

    internal weak var demodulator: LitePSKDemodulator?
    internal var printEnable: Bool = false

    @objc(initWithClient:)
    init(client: LitePSKDemodulator?) {
        super.init()
        demodulator = client
        printEnable = false
    }

    @objc(setPrintEnable:)
    func setPrintEnable(_ state: Bool) {
        printEnable = state
    }

    //  Use the Okunev 2-chip DPSK demodulator only.
    override func bpskEstimate(_ bufI: UnsafeMutablePointer<Float>, imag bufQ: UnsafeMutablePointer<Float>) -> Float {
        var matchedPair = [MatchedPair](repeating: MatchedPair(), count: 4)

        let p0 = Int(ring)
        let ai = bufI[p0]; matchedPair[0].i = ai
        let aq = bufQ[p0]; matchedPair[0].q = aq

        let p1 = Int((ring &+ RING) & RING)         //  p0-1
        let bi = bufI[p1]; matchedPair[1].i = bi
        let bq = bufQ[p1]; matchedPair[1].q = bq

        let q1 = bpskEstimate2(&matchedPair)

        let dot = ai * bi + aq * bq
        let q = sqrt(dot * dot / ((ai * ai + aq * aq) * (bi * bi + bq * bq) + 0.0000001))
        if q < quality { quality = q }

        //  use only a simple DPSK demodulator
        return q1
    }

    override func processBpskVector() -> Int32 {
        var result: Int32 = 0

        if printEnable {
            //  update the matched filter sequence
            matchedI[Int(ring)] = iMatched
            matchedQ[Int(ring)] = qMatched
            let matchedBit = bpskEstimate(&matchedI, imag: &matchedQ)

            result = (matchedBit > 0.0) ? 1 : 0
            demodulator?.receivedBit(result, quality: quality)
        }
        quality = 1.0
        //  update ring buffer index
        ring = (ring &+ 1) & RING
        return result
    }

    //  new analytic pair at 1000 s/s (32 samples per bit)
    @objc(bpsk:imag:bitSync:)
    override func bpsk(_ real: Float, imag: Float, bitSync: Bool) -> Int32 {
        //  Matched filter input I/Q pair
        let h = kernel[Int(bitPhase) & 0x3f]
        iMatched += h * real
        qMatched += h * imag

        bitPhase += 1

        //  if bitSync is passed in from the client, we are ready to process this DPSK chip
        if !bitSync { return 0 }

        let result = processBpskVector()

        //  compute phase error for AFC (bring phases into (-90,+90) degrees
        let t = atan2f(qMatched, iMatched)
        phaseErrorValue = prevPhase - t
        prevPhase = t

        if Double(phaseErrorValue) > piBy2 { phaseErrorValue = Float(Double(phaseErrorValue) - pi) }
        else if Double(phaseErrorValue) < -piBy2 { phaseErrorValue = Float(Double(phaseErrorValue) + pi) }
        if Double(phaseErrorValue) > piBy2 { phaseErrorValue = Float(Double(phaseErrorValue) - pi) }
        else if Double(phaseErrorValue) < -piBy2 { phaseErrorValue = Float(Double(phaseErrorValue) + pi) }

        // dump Matched Filter
        iMatched = 0; qMatched = 0
        bitPhase = 0
        return result
    }

    //	do nothing for QPSK
    @objc(qpsk:imag:bitSync:)
    override func qpsk(_ real: Float, imag: Float, bitSync start: Bool) -> Int32 {
        return 0
    }
}
