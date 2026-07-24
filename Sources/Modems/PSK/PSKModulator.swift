//
//  PSKModulator.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon Aug 09 2004.
//  Swift port of PSKModulator.m.
//
//  PSK31/63/125 modulator.  Subclass of CMPSKModulator; overrides the baseband
//  path to apply a lowpass FIR (basebandFilter*) matched to the symbol rate and
//  echoes transmitted characters to the Modem / voice synthesizer.
//

import Cocoa

private let RINGMASK: Int32 = 0xfff

private let kBPSK31: Int32 = 0
private let kBPSK63: Int32 = 1
private let kQPSK31: Int32 = 2

let ASCIINULL: Int32 = 0x10000      //  v0.70 used when null is inserted in the modulated stream

//  unmap odd ASCII characters
private func unmap(_ d: Int32) -> Int32 {
    if d == 216 || d == 175 { return Int32(UInt8(ascii: "0")) }
    if d == 0x20ac { return 0x80 }              // euro symbol on Windows
    return d
}

@objc(PSKModulator)
class PSKModulator: CMPSKModulator {

    private weak var modem: Modem?
    private var basebandFilter: UnsafeMutablePointer<CMFIR>?
    private var basebandFilter63: UnsafeMutablePointer<CMFIR>?
    private var basebandFilter125: UnsafeMutablePointer<CMFIR>?
    private var psk125: Bool = false

    override init() {
        super.init()
        modem = nil
        psk125 = false
        basebandFilter = CMFIRLowpassFilter(40.0, Float(kCMFs), 1024)
        basebandFilter63 = CMFIRLowpassFilter(80.0, Float(kCMFs), 512)
        basebandFilter125 = CMFIRLowpassFilter(160.0, Float(kCMFs), 256)    //  v0.64f
    }

    @objc(setModemClient:)
    func setModemClient(_ client: Modem?) {
        modem = client
    }

    //  Fetch next data bit modulation from the ring buffer.
    override func getNextBit() -> Int32 {
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
                //  generate carrier tail here (1 = no phase change).
                //  C: char tail[34]; memset(tail,1,33); tail[0]=0; tail[32]=5;
                var tail = [CChar](repeating: 1, count: 34)     // send a squelch tail (1)
                tail[0] = 0                                     //  v0.70 send an extra idle bit
                tail[32] = 5                                    //  then end transmission
                tail.withUnsafeBufferPointer { insertBits($0.baseAddress!, length: 33, fromCharacter: 0) }
            }
            bit = 0
        case 5:
            // end transmission without a phase change
            terminated = true
            bit = 1  // continue to generate steady carrier
        default:
            //  save character for echo back in fillBuffer
            if newCharacter > 1 { transmittedCharacter(newCharacter) }
            //  actual bit
            bit = (newBit == 0) ? 0 : 1
        }
        return bit
    }

    //  v0.64f -- set PSK31/PSK63/PSK125 rate
    @objc(setPSKMode:)
    override func setPSKMode(_ mode: Int32) {
        psk125 = ((mode & 0x8) != 0)
        pskMode = mode & 0x3

        if pskMode == kBPSK31 || pskMode == kQPSK31 {
            dBitPhase = Float(31.25 / kCMFs)
        } else {
            dBitPhase = psk125 ? Float(125.0 / kCMFs) : Float(62.5 / kCMFs)
        }
    }

    //  (local) PSK modulator
    @objc(nextSample)
    override func nextSample() -> Float {
        if terminated { return 0.0 }

        let alpha = nextAlpha()  // get next raised cosine factor
        let beta = 1 - alpha
        var result: Float = 0

        if pskMode == kBPSK31 || pskMode == kBPSK63 {
            // only need to work with in-phase signal for BPSK
            if pskMode == kBPSK31 {
                result = sin(Double(carrier)) * CMSimpleFilter(basebandFilter, lastI * alpha + thisI * beta)
            } else {
                if psk125 == false {
                    result = sin(Double(carrier)) * CMSimpleFilter(basebandFilter63, lastI * alpha + thisI * beta)
                } else {
                    result = sin(Double(carrier)) * CMSimpleFilter(basebandFilter125, lastI * alpha + thisI * beta)
                }
            }

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

    //  0.44 - avoid clearing the ring buffer
    @objc(resetModulator)
    override func resetModulator() {
        bitPhase = 0.5      //  start at bit transition
        lastBitPhase = 0.5
        lastI = -1.0
        thisI = 1.0
        lastQ = 0.0
        thisQ = 0.0
        convolution = 0x1f
        //bitProducer = bitConsumer = 0
        terminated = false
    }

    @objc(resetModulatorAndFlush)
    func resetModulatorAndFlush() {
        resetModulator()
        bitProducer = 0
        bitConsumer = 0
    }

    //  v0.70 Allow ASCII NULL to pass through to -transmittedCharacter in PSK.m
    @objc(appendASCII:)
    override func appendASCII(_ ch: Int32) {
        // sanity check: opt u, i, `, e, n
        if (ch == 168) || (ch == 710) || (ch == 96) || (ch == 180) || (ch == 732) { return }

        var ascii = unmap(ch)
        guard let e = varicode.encode(ascii) else { return }
        if ascii == 0 { ascii = ASCIINULL }
        let bitsPtr = UnsafeRawPointer(e).assumingMemoryBound(to: CChar.self)
        insertBits(bitsPtr, length: e.pointee.length, fromCharacter: ascii)
    }

    //  v0.70 Send two bytes to the modulator, combining them into the returned character
    @objc(appendDoubleByte:second:)
    func appendDoubleByte(_ first: Int32, second: Int32) {
        if first == 0 && second <= 26 {
            //  EOT and other control characters
            if let e = varicode.encode(second) {
                let bitsPtr = UnsafeRawPointer(e).assumingMemoryBound(to: CChar.self)
                insertBits(bitsPtr, length: e.pointee.length, fromCharacter: second)
            }
            return
        }
        //  v0.81 unmap Shift Zero
        if first == 0 && second == 216 {
            if let e = varicode.encode(Int32(UInt8(ascii: "0"))) {
                let bitsPtr = UnsafeRawPointer(e).assumingMemoryBound(to: CChar.self)
                insertBits(bitsPtr, length: e.pointee.length, fromCharacter: (first * 256 + second))
            }
            return
        }
        if let e = varicode.encode(first) {
            let bitsPtr = UnsafeRawPointer(e).assumingMemoryBound(to: CChar.self)
            insertBits(bitsPtr, length: e.pointee.length, fromCharacter: 0)
        }
        if let e = varicode.encode(second) {
            let bitsPtr = UnsafeRawPointer(e).assumingMemoryBound(to: CChar.self)
            insertBits(bitsPtr, length: e.pointee.length, fromCharacter: (first * 256 + second))
        }
    }

    @objc(transmittedCharacter:)
    override func transmittedCharacter(_ ch: Int32) {
        if let modem = modem {
            modem.transmittedCharacter(ch)
            modem.application()?.addToVoice(ch, channel: 0)     //  v0.96d voice synthesizer
        }
    }
}
