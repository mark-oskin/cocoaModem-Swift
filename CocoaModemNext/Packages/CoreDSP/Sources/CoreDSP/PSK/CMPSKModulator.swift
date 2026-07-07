//
//  CMPSKModulator.swift
//  CoreDSP
//
//  BPSK / QPSK modulator. Works in a pull fashion: characters are pushed in
//  with appendASCII(_:) (varicode-encoded into a ring of bits) and audio is
//  fetched with getBufferWithIdleFill(_:length:). The (I,Q) phasor is
//  slewed cosinusoidally between reference phasors using the raisedCosine
//  table.
//

import Foundation

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

public protocol CMPSKModulatorDelegate: AnyObject {
    func pskTransmittedCharacter(_ ch: Int32)
}

final class CMPSKModulator: CMNCO {

    weak var delegate: CMPSKModulatorDelegate?
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
    let bitLock = NSRecursiveLock()
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
        setPSKMode(kBPSK31)
        varicode = CMVaricode()
        resetModulator()
    }

    func frequencyValue() -> Float {
        return Float(Double(carrier) * kCMFs / kPeriod)
    }

    func setFrequency(_ freq: Float) {
        carrier = Float(Double(freq) * kPeriod / kCMFs)
    }

    @inline(__always)
    private func raisedCosineIndex(_ iPhase: Int32) -> Int {
        let n = raisedCosine.count
        let i = Int(iPhase)
        if i < 0 { return 0 }
        if i >= n { return n - 1 }
        return i
    }

    private func insertBits(_ bits: [Int8], length: Int32, fromCharacter ch: Int32) {
        bitLock.lock()
        for i in 0..<Int(length) {
            ring[Int(bitProducer)].character = (i == 0) ? ch : 0
            ring[Int(bitProducer)].bit = Int32(bits[i])
            bitProducer += 1
            bitProducer &= RINGMASK
        }
        bitLock.unlock()
    }

    func appendASCII(_ ascii: Int32) {
        let e = varicode.encode(ascii)
        insertBits(e.bits, length: e.length, fromCharacter: ascii)
    }

    //  insert a short sequence of idle tone
    func insertShortIdle() {
        let idle = [Int8](repeating: 0, count: 32)
        insertBits(idle, length: 31, fromCharacter: 0)
    }

    func insertSquelchTail() {
        //  send a 6 in the stream to indicate the need of a squelch carrier tail
        insertBits([6], length: 1, fromCharacter: 0)
    }

    private func nextAlpha() -> Float {
        let iPhase = cmPhaseTrunc(Double(bitPhase * Float(BITPHASEMASK + 1)))
        lastBitPhase = bitPhase
        bitPhase += dBitPhase
        if bitPhase > 1 { bitPhase -= 1 }
        return raisedCosine[raisedCosineIndex(iPhase)]
    }

    private func shouldEndTransmission() -> Bool {
        return true
    }

    //  Fetch next data bit modulation from the ring buffer.
    private func getNextBit() -> Int32 {
        if terminated { return 0 }

        if bitConsumer == bitProducer {
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
        var bit: Int32 = 0

        switch newBit {
        case 6:
            if shouldEndTransmission() {
                var tail = [Int8](repeating: 1, count: 31)
                tail[30] = 5
                insertBits(tail, length: 31, fromCharacter: 0)
            }
        case 5:
            terminated = true
            bit = 1
        default:
            if newCharacter != 0 { transmittedCharacter(newCharacter) }
            bit = (newBit == 0) ? 0 : 1
        }
        return bit
    }

    func nextSample() -> Float {
        if terminated { return 0.0 }

        let alpha = nextAlpha()
        let beta = 1 - alpha
        var result: Float = 0

        if pskMode == kBPSK31 || pskMode == kBPSK63 {
            result = sin(Double(carrier)) * (lastI * alpha + thisI * beta)

            if bitPhase < lastBitPhase {
                lastI = (thisI > 0) ? 1.0 : -1.0
                let bit = getNextBit()
                thisI = (bit == 0) ? (-lastI) : lastI
            }
        } else {
            let slewI = lastI * alpha + thisI * beta
            let slewQ = lastQ * alpha + thisQ * beta

            var sine: Double = 0
            var cosine: Double = 0
            sin(&sine, cos: &cosine, delta: Double(carrier))
            result = Float(sine * Double(slewI) + cosine * Double(slewQ))

            if bitPhase < lastBitPhase {
                lastI = thisI
                lastQ = thisQ

                let bit: Int32 = (getNextBit() != 0) ? 0 : 1
                convolution = ((convolution << 1) + bit) & 0x1f

                var g: Int32 = (convolution & 0x1) != 0 ? 3 : 0
                g ^= (convolution & 0x2) != 0 ? 1 : 0
                g ^= (convolution & 0x4) != 0 ? 1 : 0
                g ^= (convolution & 0x8) != 0 ? 2 : 0
                g ^= (convolution & 0x10) != 0 ? 3 : 0

                switch g {
                case 0:
                    break
                case 1:
                    thisI = -lastQ
                    thisQ = lastI
                case 3:
                    thisI = lastQ
                    thisQ = -lastI
                default:
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

    func getBufferWithIdleFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) { buf[i] = nextSample() }
    }

    func resetModulator() {
        bitPhase = 0.5
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

    func setPSKMode(_ mode: Int32) {
        pskMode = mode
        dBitPhase = (pskMode == kBPSK31 || pskMode == kQPSK31) ? Float(31.25 / kCMFs) : Float(62.5 / kCMFs)
    }

    private func transmittedCharacter(_ ch: Int32) {
        delegate?.pskTransmittedCharacter(ch)
    }
}
