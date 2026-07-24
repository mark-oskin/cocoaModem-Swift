//
//  CMPSKModulator.swift
//  CoreModem
//
//  Created by Kok Chen on 11/4/05.
//  Swift port of CMPSKModulator.m.
//
//  BPSK / QPSK modulator.  Subclass of CMNCO.  Works in a pull fashion:
//  characters are pushed in with -appendASCII: (varicode encoded into a ring of
//  APSKStream bits) and audio is fetched with -getBufferWithIdleFill:length:.
//  The (I,Q) phasor is slewed cosinusoidally between the reference phasors using
//  the raisedCosine table.
//
//  raisedCosine index (C: int iPhase = bitPhase*(BITPHASEMASK+1)) is computed
//  with the guarded cmPhaseTrunc and clamped to the table so a stray bitPhase
//  cannot trap or read out of bounds.
//

import Cocoa

private let BITPHASEMASK: Int32 = 0xfff
private let RINGMASK: Int32 = 0xfff

private let kBPSK31: Int32 = 0
private let kBPSK63: Int32 = 1
private let kQPSK31: Int32 = 2
private let kQPSK63: Int32 = 3

//  ring buffer element (was APSKStream in CMPSKModulator.h)
struct APSKStream {
    var bit: Int32 = 0          //  bit polarity
    var character: Int32 = 0    //  either 0 or an ASCII character
}

@objc(CMPSKModulator)
class CMPSKModulator: CMNCO {

    weak var delegate: AnyObject?
    var raisedCosine = [Float](repeating: 0, count: Int(BITPHASEMASK) + 16)
    var bitPhase: Float = 0
    var lastBitPhase: Float = 0
    var dBitPhase: Float = 0
    var thisI: Float = 0
    var lastI: Float = 0
    var thisQ: Float = 0
    var lastQ: Float = 0
    var carrier: Float = 0
    var pskMode: Int32 = 0
    //  bit buffer
    var bitLock: NSRecursiveLock!
    var bitProducer: Int32 = 0
    var bitConsumer: Int32 = 0
    var ring = [APSKStream](repeating: APSKStream(), count: Int(RINGMASK) + 1)
    var varicode: CMVaricode!
    var terminated: Bool = false
    //  convolution encoder's shift register
    var convolution: Int32 = 0

    override init() {
        super.init()
        delegate = nil
        for i in 0..<(Int(BITPHASEMASK) + 16) {
            var angle = Float(Double(i) / (Double(BITPHASEMASK) + 1.0))
            if angle > 1.0 { angle = 1.0 }
            angle = Float(Double(angle) * 3.141592653589)
            raisedCosine[i] = Float((Foundation.cos(Double(angle)) + 1.0) * 0.5)
        }
        //  phase (0 to 1)
        setPSKMode(kBPSK31)
        bitLock = NSRecursiveLock()
        varicode = CMVaricode()
        resetModulator()
    }

    @objc(delegate)
    func delegateObject() -> AnyObject? {
        return delegate
    }

    @objc(setDelegate:)
    func setDelegate(_ client: AnyObject?) {
        delegate = client
    }

    @objc(frequency)
    func frequencyValue() -> Float {
        return Float(Double(carrier) * kCMFs / kPeriod)
    }

    //  setup carrier for self (NCO object)
    @objc(setFrequency:)
    func setFrequency(_ freq: Float) {
        carrier = Float(Double(freq) * kPeriod / kCMFs)
    }

    //  index into the raisedCosine table, guarded/clamped
    @inline(__always)
    private func raisedCosineIndex(_ iPhase: Int32) -> Int {
        let n = raisedCosine.count
        let i = Int(iPhase)
        if i < 0 { return 0 }
        if i >= n { return n - 1 }
        return i
    }

    /* local */
    //  insert bits into the ring buffer
    func insertBits(_ bits: UnsafePointer<CChar>, length: Int32, fromCharacter ch: Int32) {
        bitLock.lock()
        for i in 0..<Int(length) {
            ring[Int(bitProducer)].character = (i == 0) ? ch : 0
            ring[Int(bitProducer)].bit = Int32(bits[i])
            bitProducer += 1
            bitProducer &= RINGMASK
        }
        bitLock.unlock()
    }

    @objc(appendASCII:)
    func appendASCII(_ ascii: Int32) {
        guard let e = varicode.encode(ascii) else { return }
        let bitsPtr = UnsafeRawPointer(e).assumingMemoryBound(to: CChar.self)
        insertBits(bitsPtr, length: e.pointee.length, fromCharacter: ascii)
    }

    //  insert a short sequence of idle tone
    @objc(insertShortIdle)
    func insertShortIdle() {
        //  stuff with initial idle (0) bits (31 bits at 31.25 per second)
        var idle = [CChar](repeating: 0, count: 32)
        idle.withUnsafeBufferPointer { insertBits($0.baseAddress!, length: 31, fromCharacter: 0) }
    }

    @objc(insertSquelchTail)
    func insertSquelchTail() {
        //  send a 6 in the stream to indicate the need of a squelch carrier tail
        var tail = [CChar](repeating: 0, count: 1)
        tail[0] = 6
        tail.withUnsafeBufferPointer { insertBits($0.baseAddress!, length: 1, fromCharacter: 0) }
    }

    /* local */
    func nextAlpha() -> Float {
        let iPhase = cmPhaseTrunc(Double(bitPhase * Float(BITPHASEMASK + 1)))
        lastBitPhase = bitPhase
        bitPhase += dBitPhase
        if bitPhase > 1 { bitPhase -= 1 }
        return raisedCosine[raisedCosineIndex(iPhase)]
    }

    func shouldEndTransmission() -> Bool {
        //  this used to be [ modem shouldEndTransmission]
        return true
    }

    //  Fetch next data bit modulation from the ring buffer.
    func getNextBit() -> Int32 {
        if terminated { return 0 }

        if bitConsumer == bitProducer {
            //  insert an idle bit
            bitLock.lock()
            ring[Int(bitProducer)].character = 0
            ring[Int(bitProducer)].bit = 0
            bitProducer += 1
            bitProducer &= RINGMASK
            bitLock.unlock()
        }
        let newCharacter = ring[Int(bitConsumer)].character
        let newBit = ring[Int(bitConsumer)].bit
        bitConsumer += 1
        bitConsumer &= RINGMASK
        var bit: Int32 = 0 //  generate idle

        switch newBit {
        case 6:
            //  check if at the end of message or a series of messages
            if shouldEndTransmission() {
                //  generate carrier tail here (1 = no phase change)
                var tail = [CChar](repeating: 1, count: 31)
                tail[30] = 5
                tail.withUnsafeBufferPointer { insertBits($0.baseAddress!, length: 31, fromCharacter: 0) }
            }
        case 5:
            // end transmission without a phase change
            terminated = true
            bit = 1  // continue to generate steady carrier
        default:
            //  save character for echo back in fillBuffer
            if newCharacter != 0 { transmittedCharacter(newCharacter) }
            //  actual bit
            bit = (newBit == 0) ? 0 : 1
        }
        return bit
    }

    //  (local) PSK modulator
    @objc(nextSample)
    func nextSample() -> Float {
        if terminated { return 0.0 }

        let alpha = nextAlpha()  // get next raised cosine factor
        let beta = 1 - alpha
        var result: Float = 0

        if pskMode == kBPSK31 || pskMode == kBPSK63 {
            // only need to work with in-phase signal for BPSK
            result = sin(Double(carrier)) * (lastI * alpha + thisI * beta)

            if bitPhase < lastBitPhase {
                lastI = (thisI > 0) ? 1.0 : -1.0    // regenerate to make sure error does not grow
                let bit = getNextBit()
                //  shift phase if bit == 0
                thisI = (bit == 0) ? (-lastI) : lastI
            }
        } else {
            // need both in-phase and quadrature signals for QPSK
            let slewI = lastI * alpha + thisI * beta
            let slewQ = lastQ * alpha + thisQ * beta

            //  complex local oscillator
            var sine: Double = 0
            var cosine: Double = 0
            sin(&sine, cos: &cosine, delta: Double(carrier))
            result = Float(sine * Double(slewI) + cosine * Double(slewQ))

            if bitPhase < lastBitPhase {
                lastI = thisI
                lastQ = thisQ

                //  encode each bit of data into 2 bits with convolution encoder
                let bit: Int32 = (getNextBit() != 0) ? 0 : 1
                convolution = ((convolution << 1) + bit) & 0x1f

                var g: Int32 = (convolution & 0x1) != 0 ? 3 : 0
                g ^= (convolution & 0x2) != 0 ? 1 : 0
                g ^= (convolution & 0x4) != 0 ? 1 : 0
                g ^= (convolution & 0x8) != 0 ? 2 : 0
                g ^= (convolution & 0x10) != 0 ? 3 : 0

                //  cocoaModem uses (1,0), (0,1), (-1,0) and (0,-1) as the reference phasors
                switch g {
                case 0:
                    //  keep the old phasor
                    break
                case 1:
                    //  rotate phasor by +90 degrees
                    thisI = -lastQ
                    thisQ = lastI
                case 3:
                    //  rotate phasor by -90 degrees
                    thisI = lastQ
                    thisQ = -lastI
                default:
                    //  flip phasors by 180 degrees
                    if lastI * lastI < 0.1 {
                        thisI = 0.0
                        thisQ = (lastQ > 0) ? (-1.0) : 1.0
                    } else {
                        thisI = (lastI > 0) ? (-1.0) : 1.0
                        thisQ = 0.0
                    }
                }
            }
        }
        return result
    }

    @objc(getBufferWithIdleFill:length:)
    func getBufferWithIdleFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) { buf[i] = nextSample() }
    }

    @objc(resetModulator)
    func resetModulator() {
        bitPhase = 0.5      //  start at bit transition
        lastBitPhase = 0.5
        lastI = -1.0
        thisI = 1.0
        lastQ = 0.0
        thisQ = 0.0
        convolution = 0x1f
        bitProducer = 0
        bitConsumer = 0
        terminated = false
    }

    //  set PSK31/PSK63 rate
    @objc(setPSKMode:)
    func setPSKMode(_ mode: Int32) {
        pskMode = mode
        dBitPhase = (pskMode == kBPSK31 || pskMode == kQPSK31) ? Float(31.25 / kCMFs) : Float(62.5 / kCMFs)
    }

    // delegates
    @objc(transmittedCharacter:)
    func transmittedCharacter(_ ch: Int32) {
        guard let d = delegate as? NSObject else { return }
        let sel = NSSelectorFromString("transmittedCharacter:")
        if d.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Void
            let fn = unsafeBitCast(d.method(for: sel), to: Fn.self)
            fn(d, sel, ch)
        }
    }
}
