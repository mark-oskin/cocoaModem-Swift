//
//  ConvolutionCode.swift
//  CoreDSP
//
//  Swift port of ConvolutionCode.m (FEC/ConvolutionCode.swift in the old app).
//  Rate 1/2 convolutional (Viterbi) codec used by MFSK16 (and DominoEX, not
//  ported here).  This is heavy bit-shift / XOR / table math where C relies
//  on unsigned wrap-around and logical shifts.  The port mirrors C exactly:
//  unsigned types (UInt32/UInt64) with logical shifts, and the *wrapping*
//  shift operator (&<<) on the 64-bit path register where C silently drops
//  the top bit (Swift's plain << would trap).
//

import Foundation

//  typedef unsigned long long Unsigned64 -- the path in this implementation can
//  only be 64 bits in length.
private struct TrellisState {
    var pathMetric: Float
    var pathBits: UInt64
}

final class ConvolutionCode {

    private var generator = [Int32](repeating: 0, count: 2)
    private var outputDibitTable: UnsafeMutablePointer<CChar>?
    private var stateBits: UInt32 = 0
    private var states: UInt32 = 0
    private var mask: UInt32 = 0
    //  path info for each state
    private var trellisCycle: UInt32 = 0
    private var trellisState0: UnsafeMutablePointer<TrellisState>?
    private var trellisState1: UnsafeMutablePointer<TrellisState>?
    private var lagMask: UInt64 = 1
    private var damping: Float = 0.998

    //  rate 1/2 convolutional encoding
    //  for MFSK16, k = 6 (6 state bits + 1 input bit feeding the generator functions)
    //
    //  Note: the path in this implementation can only be 64 bits (long long) in length.
    init(constraintLength k: Int32, generator a: Int32, generatorB b: Int32) {
        //  only allows max of k=30
        assert(k < 30)
        let order = k - 1
        states = UInt32(1) << UInt32(order)
        mask = states &- 1

        //  generator functions (7 bits for MFSK16: 0x6d and 0x4f) -- should have k+1 bits
        generator[0] = a
        generator[1] = b

        trellisState0 = nil
        trellisState1 = nil
        outputDibitTable = nil
        //  default trellis lag for decoding bit
        setTrellisDepth(45)
        //  damping factor is the factor applied to the past squared error -- this keeps the error from growing indefinitely
        damping = 0.998
        //  output mappings (state bit + input bit)
        let tableCount = Int(states) * 2
        let table = UnsafeMutablePointer<CChar>.allocate(capacity: tableCount)
        let g0 = UInt32(bitPattern: generator[0])
        let g1 = UInt32(bitPattern: generator[1])
        for i in 0..<UInt32(tableCount) {
            let v = (GF2Sum(g0 & i) << 1) &+ GF2Sum(g1 & i)
            table[Int(i)] = CChar(truncatingIfNeeded: v)
        }
        outputDibitTable = table
        trellisState0 = UnsafeMutablePointer<TrellisState>.allocate(capacity: Int(states))
        trellisState1 = UnsafeMutablePointer<TrellisState>.allocate(capacity: Int(states))
        trellisState0?.initialize(repeating: TrellisState(pathMetric: 0.0, pathBits: 0), count: Int(states))
        trellisState1?.initialize(repeating: TrellisState(pathMetric: 0.0, pathBits: 0), count: Int(states))
        resetTrellis()
    }

    deinit {
        //  MRC dealloc -> deinit; ARC does not free malloc'd C buffers.
        if let t = trellisState0 { t.deallocate() }
        if let t = trellisState1 { t.deallocate() }
        if let t = outputDibitTable { t.deallocate() }
    }

    //  Two sets of trellis paths are kept.
    //  Each set has one trellisState for each state of the decoder.
    //  One set is used during even time slots and the other is used during odd time slots (this is to minimize any copying).
    func resetTrellis() {
        guard let t = trellisState0, let u = trellisState1 else { return }
        stateBits = 0
        trellisCycle = 0
        for i in 0..<Int(states) {
            t[i].pathMetric = 0.0
            u[i].pathMetric = 0.0
            t[i].pathBits = 0
            u[i].pathBits = 0
        }
    }

    //  set the lag (number of time periods) to look for the decoded bit
    //  initially set to 48
    func setTrellisDepth(_ lag: Int32) {
        lagMask = 1
        if lag <= 0 { return }
        var l = lag
        if l > 63 { l = 63 }
        lagMask <<= UInt64(l)
    }

    //  Encode one bit into a dibit.  bit can either be {0,1} or {'0','1'}
    //  Returns two bits in the LSB of the integer and update state of encoder.
    //  Update state.
    func encodeIntoDibit(_ bit: Int32) -> Int32 {
        let inputBit: UInt32 = (bit == 1 || bit == Int32(UInt8(ascii: "1"))) ? 1 : 0
        let t = (stateBits &<< 1) | inputBit
        stateBits = t & mask
        return Int32(outputDibitTable![Int(t)])
    }

    //  decode a pair of dibits into a result bit
    //	The two inputs should be "soft" values in the range of { 0.0, 1.0 }.
    //  e.g., 0 indicates a certainty 0 and 1 indicates a certainty 1 and 0.9 indicates an almost certain 1.0 , etc.
    func decodeMSB(_ firstBit: Float, lsb secondBit: Float) -> Int32 {
        guard let table = outputDibitTable,
              let ts0 = trellisState0, let ts1 = trellisState1 else { return 0 }

        let previousState: UnsafeMutablePointer<TrellisState>
        let currentState: UnsafeMutablePointer<TrellisState>

        //  swap between two memory sets
        if trellisCycle == 0 {
            previousState = ts0
            currentState = ts1
            trellisCycle = 1
        } else {
            previousState = ts1
            currentState = ts0
            trellisCycle = 0
        }

        //  Each state can emit four possible hard outputs (00, 01, 10 and 11).  Precompute a table of four squared errors for each of these outputs.
        var error = [Float](repeating: 0.0, count: 4)
        for i in 0..<4 {
            var p = firstBit - Float((i >> 1) & 1)
            let q = p * p
            p = secondBit - Float(i & 1)
            error[i] = q + p * p
        }

        //  Update the Trellis.
        //
        //  Note that each state <abcdef> can come from either <0abcde>+f or <1abcde>+f where f is a new input bit.
        //  For each clock, the outputs of <0abcde> and <1abcde> are tested with input f and the one that, together with the existing state errors,
        //  causes the smaller square error is kept as the path which produces <abcdef>

        var iMin = 0
        var minpathMetric: Float = 0.0
        for state in 0..<states {
            let si = Int(state)
            // The ancestor of the current state <abcdef>  can be either <0abcde> or <1abcde> with input = f
            var t = state & mask
            var u = t &+ states
            let dibit0 = Int(table[Int(t)])   // <0abcdef>
            let dibit1 = Int(table[Int(u)])   // <1abcdef>
            t >>= 1
            u >>= 1
            let pathMetric0 = previousState[Int(t)].pathMetric * damping + error[dibit0]
            let pathMetric1 = previousState[Int(u)].pathMetric * damping + error[dibit1]

            let survivedPathMetric: Float
            if pathMetric0 < pathMetric1 {
                //  path came from <0abcdef>
                survivedPathMetric = pathMetric0
                currentState[si].pathBits = previousState[Int(t)].pathBits &<< 1
            } else {
                //  path came from <1abcdef>
                survivedPathMetric = pathMetric1
                currentState[si].pathBits = (previousState[Int(u)].pathBits &<< 1) &+ 1
            }
            currentState[si].pathMetric = survivedPathMetric
            //  mark the lowest squared error that is encountered
            if state == 0 || survivedPathMetric < minpathMetric {
                minpathMetric = survivedPathMetric
                iMin = si
            }
        }
        //  return the proper bit (lagMask) in the path which has the lowest squared error
        return ((currentState[iMin].pathBits & lagMask) != 0) ? 1 : 0
    }
}

//  GF(2) sum (xor) of the bits in n
private func GF2Sum(_ n: UInt32) -> UInt32 {
    var v = n
    var result: UInt32 = 0
    while v > 0 {
        if v & 1 != 0 { result ^= 1 }
        v >>= 1
    }
    return result
}
