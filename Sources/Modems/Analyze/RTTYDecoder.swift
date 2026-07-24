//
//  RTTYDecoder.swift
//  cocoaModem
//
//  Created by Kok Chen on 3/11/05.
//  Swift port of RTTYDecoder.m.
//
//  The RTTY decoder consists of two RTTYRegisters (one for the mark and one
//  for the space channel).  It is mostly floating-point sync-weight math; all
//  ring-buffer bit indexing lives inside RTTYRegister.  RTTYByte is a C struct
//  (moved to CMATCTypes.h) so both this class and the Obj-C MultiStereoATC can
//  share it.
//

import Cocoa

@objc(RTTYDecoder)
class RTTYDecoder: NSObject {

    private let markRegister: RTTYRegister
    private let spaceRegister: RTTYRegister
    private var block: Bool = false
    private var period: Float = 22.0

    private static let wi: [Float] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]

    override convenience init() {
        self.init(bitPeriod: 22.0)
    }

    @objc(initWithBitPeriod:)
    init(bitPeriod milliseconds: Float) {
        period = milliseconds
        markRegister = RTTYRegister(bitPeriod: milliseconds)
        spaceRegister = RTTYRegister(bitPeriod: milliseconds)
        block = false
        super.init()
    }

    @objc func dumpData() {
        let m: Int32 = 4
        var i: Int32 = -128 * m
        while i < 128 * m {
            var s: Float = 0, u: Float = 0, v: Float = 0
            for k in 0..<m {
                var a = markRegister.sample(0, offset: i + k) - spaceRegister.sample(0, offset: i + k)
                if abs(a) > abs(s) { s = a }
                a = markRegister.agcAtOffset(i + k)
                if a > u { u = a }
                a = spaceRegister.agcAtOffset(i + k)
                if a > v { v = a }
            }
            v = -v
            let t = u + v
            print(String(format: "%8.4f\t%8.4f\t%8.4f\t%8.4f", s, t * 2, u * 2, v * 2))
            i += m
        }
    }

    @objc(addSamples:mark:space:)
    func addSamples(_ size: Int32, mark markArray: UnsafeMutablePointer<Float>, space spaceArray: UnsafeMutablePointer<Float>) {
        assert(size == 256)
        markRegister.addSamples(size, array: markArray)
        spaceRegister.addSamples(size, array: spaceArray)
    }

    @objc func advance() {
        markRegister.advance()
        spaceRegister.advance()
    }

    @objc func mark() -> RTTYRegister {
        return markRegister
    }

    @objc func space() -> RTTYRegister {
        return spaceRegister
    }

    @objc(markAtBit:offset:)
    func markAtBit(_ bit: Int32, offset: Int32) -> Float {
        return markRegister.sample(bit, offset: offset)
    }

    @objc(spaceAtBit:offset:)
    func spaceAtBit(_ bit: Int32, offset: Int32) -> Float {
        return spaceRegister.sample(bit, offset: offset)
    }

    //  mark - space at (bit, word, offset)
    private func sample(_ bit: Int32, word w: Int32, offset: Int32) -> Float {
        return markRegister.sample(bit, word: w, offset: offset) - spaceRegister.sample(bit, word: w, offset: offset)
    }

    private func syncWeight(_ offset: Int32) -> Float {
        var n = 0.0
        var d = 0.000000001
        //  word -3, -2, -1, 0, +1
        for i in 0..<5 {
            let w = Int32(i - 3)
            if w != 7 {
                //  compute for all but current character
                let b = RTTYDecoder.wi[i]
                var a = Double(b * sample(-3, word: w, offset: offset))
                d += a * a; n += a
                a = Double(b * sample(-2, word: w, offset: offset))
                d += a * a; n += a
                a = Double(b * sample(-1, word: w, offset: offset))
                d += a * a; n -= a
                a = Double(b * sample(5, word: w, offset: offset))
                d += a * a; n += a
                a = Double(b * sample(6, word: w, offset: offset))
                d += a * a; n += a
            }
        }
        return Float(n / sqrt(25.0 * d))
    }

    private func newSyncWeight(_ offset: Int32) -> Float {
        var n = 0.0
        var d = 0.000000001
        //  word -3, -2, -1, 0, +1
        for i in -2..<5 {
            let w = Int32(i - 3)
            var a = Double(sample(-3, word: w, offset: offset))
            d += a * a; n += a
            a = Double(sample(-2, word: w, offset: offset))
            d += a * a; n += a
            a = Double(sample(-1, word: w, offset: offset))
            d += a * a; n -= a
        }
        return Float(n / sqrt(21.0 * d))
    }

    //  relative certainty of frame sync for a single character
    //  looks for 2 samples of previous stop bits, start bit and following stop bits
    private func singleSyncWeight(_ offset: Int32) -> Float {
        var n = 0.0
        var d = 0.000000001

        let agc = markRegister.agcForWord(0) - spaceRegister.agcForWord(0)

        var a = Double(sample(-3, word: 0, offset: offset) - agc)
        d += a * a; n += a
        a = Double(sample(-2, word: 0, offset: offset) - agc)
        d += a * a; n += a
        a = Double(sample(-1, word: 0, offset: offset) - agc)
        d += a * a; n -= a
        a = Double(sample(5, word: 0, offset: offset) - agc)
        d += a * a; n += a
        a = Double(sample(6, word: 0, offset: offset) - agc)
        d += a * a; n += a

        return Float(n / sqrt(5.0 * d))
    }

    private func forwardSyncWeight(_ offset: Int32) -> Float {
        var n = 0.0
        var d = 0.000000001

        for i in 0..<3 {
            let w = Int32(i)
            let agc = markRegister.agcForWord(w) - spaceRegister.agcForWord(w)
            if i == 0 {
                //  pre-stop
                let a = Double(sample(-3, word: w, offset: offset) - agc)
                d += a * a; n += a
            }
            // leading stop bit
            var a = Double(sample(-2, word: w, offset: offset) - agc)
            d += a * a; n += a
            // start bit
            a = Double(sample(-1, word: w, offset: offset) - agc)
            d += a * a; n -= a
            //  trailing stop bit
            a = Double(sample(5, word: w, offset: offset) - agc)
            d += a * a; n += a
            if i == 2 {
                //  post-stop
                a = Double(sample(6, word: w, offset: offset) - agc)
                d += a * a; n += a
            }
        }
        return Float(n / sqrt(11.0 * d))
    }

    private func asyncWeight(_ offset: Int32) -> Float {
        let s0 = sample(-2, word: 0, offset: offset)
        if s0 < 0 { return 0.0 }
        let s1 = sample(-1, word: 0, offset: offset)
        if s1 > 0 { return 0.0 }
        let s2 = sample(5, word: 0, offset: offset)
        if s2 < 0 { return 0.0 }

        var n = 2 * (s0 - s1 + s2)
        for i in 0..<5 {
            let a = sample(Int32(i), word: 0, offset: offset)
            n += abs(a)
        }
        return n
    }

    @objc(checkSync:length:)
    func checkSync(_ g: UnsafeMutablePointer<Float>, length n: Int32) {
        for i in 0..<Int(n) { g[i] = syncWeight(Int32(i)) }
    }

    @objc(getBuffer:markOffset:spaceOffset:)
    func getBuffer(_ pair: UnsafeMutablePointer<CMATCPair>, markOffset: Int32, spaceOffset: Int32) {
        //  CMATCPair is { float mark; float space; } so a Float view with stride 2
        //  writes the interleaved mark (base) / space (base+1) fields.
        pair.withMemoryRebound(to: Float.self, capacity: 512) { fp in
            markRegister.getBuffer(fp, offset: markOffset, stride: 2)
            spaceRegister.getBuffer(fp + 1, offset: spaceOffset, stride: 2)
        }
    }

    //  to reduce false positives, look for previous character's stop bit, the
    //  start bit and also the stop bit after the data bits.
    @objc func symbolSync() -> Bool {
        //  previous character's stop bit
        var stop = markRegister.sample(-2) - spaceRegister.sample(-2)
        if stop < 0 { return false }

        let start = markRegister.sample(-1) - spaceRegister.sample(-1)
        if start > 0 { return false }

        stop = markRegister.sample(5) - spaceRegister.sample(5)
        return (stop > 0)
    }

    //  return the index that has the best sync position
    @objc(bestSyncForMarkOffset:spaceOffset:sync:)
    func bestSyncForMarkOffset(_ m: Int32, spaceOffset s: Int32, sync check: UnsafeMutablePointer<RTTYByte>) {
        check.pointee.frameSync = false
        check.pointee.confidence = 0

        //  previous character's stop bit
        var stop = markRegister.sample(-2, offset: m) - spaceRegister.sample(-2, offset: s)
        if stop < 0 { return }

        let start = markRegister.sample(-1, offset: m) - spaceRegister.sample(-1, offset: s)
        if start > 0 { return }

        stop = markRegister.sample(5, offset: m) - spaceRegister.sample(5, offset: s)
        if stop < 0 { return }

        var bestOffset: Int32 = 0
        var qmax = syncWeight(0)
        for i in 0..<30 {
            let q = syncWeight(Int32(i))
            if q > qmax { qmax = q; bestOffset = Int32(i) }
        }
        check.pointee.frameSync = true
        check.pointee.confidence = qmax
        check.pointee.offset = bestOffset
    }

    //  return the index that has the best sync position
    @objc(validateSyncForMarkOffset:spaceOffset:sync:)
    func validateSyncForMarkOffset(_ m: Int32, spaceOffset s: Int32, sync check: UnsafeMutablePointer<RTTYByte>) {
        check.pointee.frameSync = false
        check.pointee.confidence = 0

        let mMax = markRegister.agcAtOffset(m)
        let sMax = spaceRegister.agcAtOffset(s)
        let atc = mMax - sMax

        //  previous character's stop bit
        var stop = markRegister.sample(-2, offset: m) - spaceRegister.sample(-2, offset: s) - atc
        if stop < 0 { return }

        let start = markRegister.sample(-1, offset: m) - spaceRegister.sample(-1, offset: s) - atc
        if start > 0 { return }

        stop = markRegister.sample(5, offset: m) - spaceRegister.sample(5, offset: s) - atc
        if stop < 0 { return }

        var bestOffset: Int32 = 0
        var qmax = syncWeight(0)
        for i in 0..<20 {
            let q = syncWeight(Int32(i))
            if q > qmax { qmax = q; bestOffset = Int32(i) }
        }
        check.pointee.frameSync = true
        check.pointee.confidence = qmax
        check.pointee.offset = bestOffset
    }

    //  check the next 256 samples for a frame sync, by looking only at a single character's frame
    @objc(findFrameSyncForMarkOffset:spaceOffset:sync:)
    func findFrameSyncForMarkOffset(_ m: Int32, spaceOffset s: Int32, sync check: UnsafeMutablePointer<RTTYByte>) {
        check.pointee.frameSync = false
        check.pointee.confidence = 0

        var bestOffset: Int32 = 0
        var qmax = syncWeight(0)
        for i in 0..<256 {
            let q = forwardSyncWeight(Int32(i))
            if q > qmax { qmax = q; bestOffset = Int32(i) }
        }
        if qmax > 0.66 {
            check.pointee.frameSync = true
            check.pointee.confidence = qmax
            check.pointee.offset = bestOffset
            return
        }

        qmax = syncWeight(0)
        for i in 0..<256 {
            let q = singleSyncWeight(Int32(i))
            if q > qmax { qmax = q; bestOffset = Int32(i) }
        }
        if qmax > 0.66 { check.pointee.frameSync = true }
        check.pointee.confidence = qmax
        check.pointee.offset = bestOffset
    }

    @objc(checkSyncForMarkOffset:spaceOffset:sync:)
    func checkSyncForMarkOffset(_ m: Int32, spaceOffset s: Int32, sync check: UnsafeMutablePointer<RTTYByte>) {
        check.pointee.frameSync = false
        check.pointee.confidence = 0

        var bestOffset: Int32 = 0
        var qmax = syncWeight(0)
        var array = [Float](repeating: 0, count: 400)
        for i in 0..<5 {
            let q = forwardSyncWeight(Int32(i))
            array[i] = q
            if q > qmax { qmax = q; bestOffset = Int32(i) }
        }
        if qmax > 0.66 {
            check.pointee.frameSync = true
            check.pointee.confidence = qmax
            check.pointee.offset = bestOffset
        }
        check.pointee.frameSync = true
        check.pointee.confidence = qmax
        check.pointee.offset = bestOffset
    }

    //  return the index that has the best async position
    @objc(bestAsyncForMarkOffset:spaceOffset:sync:)
    func bestAsyncForMarkOffset(_ m: Int32, spaceOffset s: Int32, sync check: UnsafeMutablePointer<RTTYByte>) {
        check.pointee.frameSync = false
        check.pointee.confidence = 0

        //  previous character's stop bit
        var mv = markRegister.sample(-2, offset: m)
        let mmax = 0.05 * markRegister.agcAtOffset(m)
        if mv < mmax { return }
        var sv = spaceRegister.sample(-2, offset: s)
        var stop = mv - sv
        if stop < 0 { return }

        mv = markRegister.sample(-1, offset: m)
        sv = spaceRegister.sample(-1, offset: s)
        let smax = 0.05 * spaceRegister.agcAtOffset(s)
        if sv < smax { return }
        var start = mv - sv
        if start > 0 { return }

        mv = markRegister.sample(5, offset: m)
        if mv < mmax { return }
        sv = spaceRegister.sample(5, offset: s)
        stop = mv - sv
        if stop < 0 { return }

        var bestOffset: Int32 = 0
        var qmax = asyncWeight(0)
        for i in 1..<30 {
            let q = asyncWeight(Int32(i))
            if q > qmax { qmax = q; bestOffset = Int32(i) }
        }
        stop = markRegister.sample(5, offset: bestOffset) - spaceRegister.sample(5, offset: bestOffset)
        start = -markRegister.sample(-1, offset: bestOffset) + spaceRegister.sample(-1, offset: bestOffset)

        var q = abs(stop) + 0.01
        if abs(start) > q { q = abs(start) }

        qmax = (stop + start) / (2 * q)

        check.pointee.frameSync = DarwinBoolean(qmax > 0.4)
        check.pointee.confidence = qmax
        check.pointee.offset = bestOffset
    }

    @objc(likelihoodWithMarkOffset:spaceOffset:)
    func likelihoodWithMarkOffset(_ m: Int32, spaceOffset s: Int32) -> Float {
        var sum: Float = 0.0
        for i in -1..<6 {
            let v = markRegister.sample(Int32(i), offset: m) - spaceRegister.sample(Int32(i), offset: s)
            sum += abs(v)
        }
        return sum
    }
}
