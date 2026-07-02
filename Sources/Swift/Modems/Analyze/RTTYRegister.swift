//
//  RTTYRegister.swift
//  cocoaModem
//
//  Created by Kok Chen on 3/9/05.
//  Swift port of RTTYRegister.m.
//
//  Baudot shift-register ring buffer.  All ring-index arithmetic is done with
//  wrapping integer operators and masked (& RINGMASK / & 0xff) before every
//  array access, mirroring the C two's-complement behaviour without trapping.
//  float -> int conversions are guarded (cInt) the way DisplayColor does.
//

import Cocoa

@objc(RTTYRegister)
class RTTYRegister: NSObject {

    private static let RINGSIZE = 4096
    private static let RINGMASK = 0xfff
    private static let INTSCALE: Float = 100000.0

    private var samplesPerBit: Float = 0
    private var samplesPerWord: Float = 0
    private var bitCenter = [Int32](repeating: 0, count: 10)
    private var wordOffset = [Int32](repeating: 0, count: 32)

    //  C inline RingBuffers kept as heap buffers (freed in deinit).
    private let array = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let agcBuf = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let syncBuf = UnsafeMutablePointer<Float>.allocate(capacity: 4096)

    private var maxRegister = [Int32](repeating: 0, count: 256)   //  AGC register width
    private var accumMax: Int32 = 0
    private var smoothedMax: Float = 0.001
    private var outPointer: Int = 0
    private var inPointer: Int = 0

    //  C truncates a (finite) float toward zero; guard NaN/inf so a bad sample
    //  can never trap (mirror DisplayColor.cInt).
    @inline(__always)
    private func cInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int32.max }
        if t <= -2147483648.0 { return Int32.min }
        return Int32(t)
    }

    //  assume data rate is at 11.025/8 (Fs/8) (about 30.32 samples per Baudot bit)
    //  (approximately 6 characters/second)
    @objc(initWithBitPeriod:)
    init(bitPeriod milliseconds: Float) {
        super.init()

        samplesPerBit = Float(Double(milliseconds) * (CMFs / 8.0) * 0.001)
        //  word offsets, set to 1.5 stop bits, wrapped around ring buffer size
        samplesPerWord = samplesPerBit * 7.5

        let ringSize = Int32(RTTYRegister.RINGSIZE)
        let ringMask = Int32(RTTYRegister.RINGMASK)
        for i in 0..<32 {
            wordOffset[i] = (cInt(samplesPerWord * Float(i - 16)) &+ ringSize) & ringMask   // 1.5 stop bits
        }

        //  first bitOffset is at the 1.5 stop bit location (1/2 bit offset)
        //  subsequent indexes are spaced at 1 bit time apart
        //  last position is again 0.5 bit time away for trailing 1.5 stop bit
        //  i.e., index 0,1 = stop, index 2 = start, index 3 = LSB, ... index 7 = MSB, index 8,9 = stop
        var pos = samplesPerBit * 0.5
        bitCenter[0] = 0
        for i in 1..<9 {
            bitCenter[i] = cInt(pos + 0.5)
            pos += samplesPerBit
        }
        pos -= samplesPerBit * 0.5
        bitCenter[9] = cInt(pos + 0.5)
        var last = bitCenter[9]
        last = last &+ cInt(samplesPerBit * 0.5)
        //  referenced to the end of a Baudot character, i.e., bitCenter[i] are all negative
        for i in 0..<10 { bitCenter[i] = bitCenter[i] &- last }

        initBuffers()
    }

    deinit {
        array.deallocate()
        agcBuf.deallocate()
        syncBuf.deallocate()
    }

    //  called before the start of a stream
    private func initBuffers() {
        for i in 0..<255 { maxRegister[i] = 1 }
        maxRegister[255] = 0            //  (int).01 == 0
        accumMax = 0                    //  (int).01 == 0
        smoothedMax = 0.001

        for i in 0..<RTTYRegister.RINGSIZE {
            array[i] = 0.0
            agcBuf[i] = 0.01
            syncBuf[i] = 0.0
        }
        outPointer = 0
        inPointer = 0
    }

    //  number of characters available between input pointer and output pointer
    @objc func charactersAvailable() -> Float {
        if inPointer > outPointer { return Float(inPointer - outPointer) / samplesPerWord }
        return Float(inPointer + RTTYRegister.RINGSIZE - outPointer) / samplesPerWord
    }

    @objc(getBuffer:offset:stride:)
    func getBuffer(_ buf: UnsafeMutablePointer<Float>, offset: Int32, stride: Int32) {
        var k = Int(offset) + outPointer
        var j = 0
        for _ in 0..<256 {
            buf[j] = array[k & RTTYRegister.RINGMASK]
            j += Int(stride)
            k += 1
        }
    }

    @objc(getCompensatedBuffer:offset:stride:)
    func getCompensatedBuffer(_ buf: UnsafeMutablePointer<Float>, offset: Int32, stride: Int32) {
        var k = Int(offset) + outPointer
        var j = 0
        for _ in 0..<256 {
            let kk = k & RTTYRegister.RINGMASK
            buf[j] = array[kk] - agcBuf[kk]
            j += Int(stride)
            k += 1
        }
    }

    //  bit -3  previous 1.5 stop bit
    //  bit -2  previous stop bit
    //  bit -1  current start bit
    //  bit 0 thru 4 LSB through MSB of Baudot
    //  bit 5 current stop bit
    //  bit 6 current 1.5 stop bit

    @objc(sample:)
    func sample(_ bit: Int32) -> Float {
        return sample(bit, word: 0, offset: 0)
    }

    //  word is 0 for current word, -1 for previous word, -2 for word 2 characters ago, etc
    //  word must be no smaller than -16 and no greater than +16
    @objc(sample:word:offset:)
    func sample(_ bit: Int32, word: Int32, offset: Int32) -> Float {
        //  mask the word index into the wordOffset[32] table (C would read OOB
        //  at word == +16; callers never hit it, but guard against a trap)
        var wi = Int(word) + 16
        if wi < 0 { wi = 0 } else if wi > 31 { wi = 31 }
        return sample(bit, offset: offset &+ wordOffset[wi])
    }

    @objc(sample:offset:)
    func sample(_ bit: Int32, offset: Int32) -> Float {
        let b = Int(bit) + 3
        if b < 0 || b > 9 { return 0.0 }
        let i = (Int(bitCenter[b]) + outPointer + Int(offset)) & RTTYRegister.RINGMASK
        return array[i]
    }

    //  max over current 8 Baudot start/stop and data bits starting at current data offset
    //  0 offset is the center of the first preceeding stop bit
    @objc func agc() -> Float {
        return agcBuf[outPointer]
    }

    @objc(agcForWord:)
    func agcForWord(_ word: Int32) -> Float {
        var wi = Int(word) + 16
        if wi < 0 { wi = 0 } else if wi > 31 { wi = 31 }
        let i = (outPointer + Int(wordOffset[wi])) & RTTYRegister.RINGMASK
        return agcBuf[i]
    }

    @objc(agcAtOffset:)
    func agcAtOffset(_ offset: Int32) -> Float {
        let i = (outPointer + Int(offset) + RTTYRegister.RINGSIZE) & RTTYRegister.RINGMASK
        return agcBuf[i]
    }

    //  delay = -320 : from optimization on 0dB selective fade file
    @objc(addSample:)
    func addSample(_ data: Float) {
        //  update the data and agc registers
        array[inPointer] = data
        syncBuf[inPointer] = 0
        agcBuf[(inPointer + (RTTYRegister.RINGSIZE - 320)) & RTTYRegister.RINGMASK] = smoothedMax * 0.5

        //  find max over the previous 256 samples
        let maxPtr = inPointer & 0xff
        let old = maxRegister[maxPtr]
        var d = cInt(data * RTTYRegister.INTSCALE)
        if d < 0 { d = 0 }
        maxRegister[maxPtr] = d

        //  smooth max
        smoothedMax = smoothedMax * 0.95 + Float(accumMax) * 0.05 / RTTYRegister.INTSCALE

        //  update max over register
        if d >= accumMax {
            accumMax = d
        } else {
            if old >= accumMax {
                //  largest agc voltage removed, need to update max agc with a full search
                accumMax = maxRegister[0]
                for i in 1..<256 {
                    if maxRegister[i] > accumMax { accumMax = maxRegister[i] }
                }
            }
        }
        //  wrap pointer around
        inPointer = (inPointer &+ 1) & RTTYRegister.RINGMASK
    }

    @objc(addSamples:array:)
    func addSamples(_ size: Int32, array data: UnsafeMutablePointer<Float>) {
        for i in 0..<Int(size) { addSample(data[i]) }
    }

    @objc func advance() {
        outPointer = (outPointer &+ 1) & RTTYRegister.RINGMASK
    }

    //  in to out delay
    @objc func delay() -> Int32 {
        return Int32((inPointer - outPointer + RTTYRegister.RINGSIZE) & RTTYRegister.RINGMASK)
    }
}
