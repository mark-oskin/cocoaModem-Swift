//
//  RTTYModulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/31/05.
//  Swift port of RTTYModulator.m.
//
//  Adds a second tone (for two-tone testing) to the FSK modulator, echoes
//  transmitted characters back to the Modem, and saves the tone-pair audio
//  frequencies (as opposed to the DDA increments kept by the base class).
//

import Cocoa

//  unmap phi to zero
private func unmap(_ d: Int32) -> Int32 {
    if d == 216 || d == 175 { return Int32(UInt8(ascii: "0")) }
    return d & 0x7f
}

@objc(RTTYModulator)
class RTTYModulator: RTTYModulatorBase {

    weak var modem: Modem?
    //  second tone (for two tone test)
    private var theta2: Double = 0
    private let toneFreqPtr = UnsafeMutablePointer<CMTonePair>.allocate(capacity: 1)

    override init() {
        toneFreqPtr.pointee = CMTonePair(mark: 0, space: 0, baud: 0)
        super.init()
        theta2 = 0
    }

    deinit {
        toneFreqPtr.deallocate()
    }

    //  intercept setTonePair to save frequencies (CMRTTYModulator uses the DDA frequencies)
    @objc(setTonePair:)
    override func setTonePair(_ inTonePair: UnsafePointer<CMTonePair>) {
        toneFreqPtr.pointee = inTonePair.pointee
        super.setTonePair(inTonePair)
    }

    @objc(toneFrequencies)
    func toneFrequencies() -> UnsafeMutablePointer<CMTonePair> {
        return toneFreqPtr
    }

    //  callback target as each character is transmitted
    @objc(setModemClient:)
    func setModemClient(_ inModem: Modem?) {
        modem = inModem
    }

    //  override CoreModem framework, which was 6 bits long
    //  append a long mark tone (10 bits long, with no start bit)
    @objc(appendLongMark)
    override func appendLongMark() {
        producer = consumer
        stream[Int(producer)] = stopBit
        stream[Int(producer)].dda = bitDDA / 10.0                   // v0.85b

        currentBitDDA = stream[Int(producer)].dda                   // v0.85b
        bitTheta = 0
        ookAssert = false
        if ook == 2 { ookAssert = !ookAssert }                      //  ook: mark

        producer = (producer + 1) & CMSTREAMMASK
    }

    @objc(appendASCII:)
    override func appendASCII(_ ascii: Int32) {
        //  this will unmap any phi into zero and also map '\n' into '\r'
        super.appendASCII(unmap(ascii))
    }

    // send transmitted character to modem to echo in the exchange view
    @objc(transmittedCharacter:)
    override func transmittedCharacter(_ character: Int32) {
        if let modem = modem, character != 0 {
            modem.transmittedCharacter(character)
        }
    }

    //  consume from the current buffer
    //  add repeats of character if there is no more bits to consume
    @objc(getBufferWithRepeatFill:length:)
    func getBufferWithRepeatFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) {
            buf[i] = sin(current)
            //  modulation
            if modulation(currentBitDDA) {
                if producer == 0 { current = tonePair.mark }
                else {
                    consumer += 1
                    if consumer == producer { consumer = 0 } else { consumer &= CMSTREAMMASK }
                    currentBitDDA = stream[Int(consumer)].dda
                    current = (stream[Int(consumer)].polarity == 0) ? tonePair.space : tonePair.mark
                }
            }
        }
    }

    @objc(getBufferOfMarkTone:length:)
    func getBufferOfMarkTone(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) { buf[i] = sin(tonePair.mark) }
    }

    @objc(getBufferOfSpaceTone:length:)
    func getBufferOfSpaceTone(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) { buf[i] = sin(tonePair.space) }
    }

    @objc(getBufferOfTwoTone:length:)
    func getBufferOfTwoTone(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) { buf[i] = (sin(tonePair.space) + sin2(tonePair.mark)) * 0.5 }
    }

    //  second channel
    //  NOTE: delta must be less than kPeriod and greater than or equal to 0
    @objc(sin2:)
    func sin2(_ delta: Double) -> Float {
        theta2 += delta
        var th = theta2
        if th > kPeriod {
            th -= kPeriod
            theta2 = th
        }
        let t = cmPhaseTrunc(th)
        let mst = cmTableIndex(t >> kBits)
        let lst = cmTableIndex(t & kMask)
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        let s = mssin[mst] * lscos[lst] + mscos[mst] * lssin[lst]
        return Float(Double(s) * scale)
    }

    //  NOTE: delta must be less than kPeriod and greater than or equal to 0
    @objc(cos2:)
    func cos2(_ delta: Double) -> Float {
        theta2 += delta
        var th = theta2
        if th > kPeriod {
            th -= kPeriod
            theta2 = th
        }
        let t = cmPhaseTrunc(th)
        let mst = cmTableIndex(t >> kBits)
        let lst = cmTableIndex(t & kMask)
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        let s = mscos[mst] * lscos[lst] - mssin[mst] * lssin[lst]
        return Float(Double(s) * scale)
    }
}
