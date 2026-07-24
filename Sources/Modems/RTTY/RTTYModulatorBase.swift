//
//  RTTYModulatorBase.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 3/21/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of RTTYModulatorBase.m.
//
//  Adds on-off-keying (OOK / 2500 Hz tone burst) support to CMFSKModulator, plus
//  the v0.88 Baudot-code carry-through used by the aural OOK monitor.
//

import Cocoa

private let ookMark: Double = 2500.0 * kPeriod / kCMFs

@objc(RTTYModulatorBase)
class RTTYModulatorBase: CMFSKModulator {

    var ook: Int32 = 0                          //  v0.85
    var ookAssert: Bool = false
    private var currentBaudotCharacter: Int32 = 0

    override init() {
        super.init()
        delegate = nil
        producer = 0
        consumer = 0
        ook = 0                                 //  v0.85
        ookAssert = true                        //  v0.85
        currentBaudotCharacter = 0x1f
        initSetup()
    }

    @objc(initSetup)
    func initSetup() {
        var tonepair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)

        usos = true
        shifted = false
        robust = false
        sideband = 0
        robustCount = 0
        setTonePair(&tonepair)
        setStopBits(1.5)
        //  create ascii to baudot translation
        for i in 0..<128 { mapping[i] = 0 }  // fill with Baudot blank
        let star = Int32(UInt8(ascii: "*"))
        let aUp = Int32(UInt8(ascii: "A"))
        let zUp = Int32(UInt8(ascii: "Z"))
        let aLo = Int32(UInt8(ascii: "a"))
        for i in 0..<32 {
            let ltr = CMLtrs[i]
            let fig = CMFigs[i]
            if ltr == fig && ltr != 0 && ltr != star {
                mapping[Int(ltr)] = Int32(i) | CMLTRSHIFT | CMFIGSHIFT
            } else {
                if ltr != 0 && ltr != star {
                    mapping[Int(ltr)] = Int32(i) | CMLTRSHIFT
                    if ltr >= aUp && ltr <= zUp { mapping[Int(ltr - aUp + aLo)] = Int32(i) | CMLTRSHIFT }
                }
                if fig != 0 && fig != star {
                    mapping[Int(fig)] = Int32(i) | CMFIGSHIFT
                }
            }
        }
    }

    //  v0.85
    @objc(setOOK:invert:)
    func setOOK(_ ookState: Int32, invert invertTransmit: Bool) {
        ook = ookState
        if ook != 0 && invertTransmit { ook = 2 }
    }

    //  Rest condition = Mark.  startbit = 0 = space, stop bit = 1 = mark
    @objc(setTonePair:)
    override func setTonePair(_ inTonePair: UnsafePointer<CMTonePair>) {
        var tonepair = inTonePair.pointee

        if sideband != 0 {
            let t = tonepair.mark
            tonepair.mark = tonepair.space
            tonepair.space = t
        }
        tonePair.mark = tonepair.mark * kPeriod / kCMFs
        tonePair.space = tonepair.space * kPeriod / kCMFs
        bitDDA = tonepair.baud * kPeriod / kCMFs

        current = tonePair.mark
        if ook != 0 { current = 0 }
        currentBitDDA = bitDDA

        startBit.dda = bitDDA
        startBit.polarity = 0
        startBit.character = 0
        startBit.code = 0
        dataBit[0].dda = bitDDA
        dataBit[0].polarity = 0
        dataBit[0].character = 0
        dataBit[0].code = 0
        dataBit[1].dda = bitDDA
        dataBit[1].polarity = 1
        dataBit[1].character = 0
        dataBit[1].code = 0
        setStopBits(stopDuration)
    }

    //  Stop bits (defaulted to 1.5 by init)
    @objc(setStopBits:)
    override func setStopBits(_ stopBits: Float) {
        //  sanity check
        if stopBits < 0.99 || stopBits > 2.01 { return }

        stopDuration = stopBits
        stopDDA = bitDDA / Double(stopDuration)
        stopBit.dda = stopDDA
        stopBit.polarity = 1
        stopBit.character = 0
        stopBit.code = 0
    }

    @objc(setSideband:)
    override func setSideband(_ usb: Int32) {
        sideband = usb
    }

    @objc(setUSOS:)
    override func setUSOS(_ state: Bool) {
        usos = state
    }

    //  (Private API)
    //  append diddle (LTRS)
    override func appendDiddle(_ flag: Int32) {
        var diddle = CMLTRSCODE
        lock.lock()
        shifted = false
        var tempProducer = producer
        stream[Int(tempProducer)] = startBit
        stream[Int(tempProducer)].character = flag
        tempProducer = (tempProducer + 1) & CMSTREAMMASK
        for _ in 0..<5 {
            stream[Int(tempProducer)] = dataBit[Int(diddle & 1)]
            tempProducer = (tempProducer + 1) & CMSTREAMMASK
            diddle >>= 1  // next bit of diddle character
        }
        stream[Int(tempProducer)] = stopBit
        tempProducer = (tempProducer + 1) & CMSTREAMMASK
        producer = tempProducer
        lock.unlock()
    }

    //  (Private API)
    override func appendBits(_ code: Int32, ascii: Int32) {
        var code = code
        var tempProducer = producer
        stream[Int(tempProducer)] = startBit
        stream[Int(tempProducer)].character = ascii
        stream[Int(tempProducer)].code = code
        tempProducer = (tempProducer + 1) & CMSTREAMMASK
        for _ in 0..<5 {
            stream[Int(tempProducer)] = dataBit[Int(code & 1)]
            tempProducer = (tempProducer + 1) & CMSTREAMMASK
            code >>= 1  // next bit of Baudot character
        }
        stream[Int(tempProducer)] = stopBit
        tempProducer = (tempProducer + 1) & CMSTREAMMASK
        producer = tempProducer
    }

    //  append the string, replacing completely any previous string that is in the buffer if clearExistingCharacters is true
    @objc(appendString:clearExistingCharacters:)
    override func appendString(_ s: UnsafePointer<CChar>, clearExistingCharacters reset: Bool) {
        if reset { producer = 0; consumer = 0 }
        var p = s
        while p.pointee != 0 {
            appendASCII(Int32(p.pointee))
            p += 1
        }
        bitTheta = 0
        current = (ook == 0) ? tonePair.mark : ookMark          //  v0.85
        currentBitDDA = bitDDA
    }

    @objc(clearOutput)
    override func clearOutput() {
        if consumer < (producer - 1) { consumer = producer - 1 }
    }

    //  v0.88 send Baudot character to FSKHub so OOK aural Monitor can fetch it
    func setAuralTransmitCharacter(_ code: Int32) {
        (NSApp.delegate as? AppDelegate)?.application()?.fskHub()?.setCurrentBaudotCharacter(code)
    }

    //  v0.85  2500 Hz tone bursts
    @objc(getOOKBufferWithDiddleFill:length:)
    func getOOKBufferWithDiddleFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) {
            let v = sin(current)
            buf[i] = ookAssert ? v : 0.0
            //  modulation
            if modulation(currentBitDDA) {
                consumer = (consumer + 1) & CMSTREAMMASK
                if consumer == producer { appendDiddle(0) }
                let bit = stream[Int(consumer)]
                currentBitDDA = bit.dda
                current = ookMark
                ookAssert = (bit.polarity == 0)
                if ook == 2 { ookAssert = !ookAssert }
                //  set clock for zero crossing
                theta = 0
                if bit.code != 0 { setAuralTransmitCharacter(bit.code) }     //  v0.88
                if bit.character != 0 { transmittedCharacter(bit.character) }
            }
        }
    }

    //  consume from the current buffer
    @objc(getBufferWithDiddleFill:length:)
    override func getBufferWithDiddleFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        if ook != 0 {
            getOOKBufferWithDiddleFill(buf, length: samples)
            return
        }
        for i in 0..<Int(samples) {
            buf[i] = sin(current)
            //  modulation
            if modulation(currentBitDDA) {
                consumer = (consumer + 1) & CMSTREAMMASK
                if consumer == producer { appendDiddle(0) }
                let bit = stream[Int(consumer)]
                currentBitDDA = bit.dda
                current = (bit.polarity == 0) ? tonePair.space : tonePair.mark
                if bit.code != 0 { setAuralTransmitCharacter(bit.code) }     //  v0.88
                if bit.character != 0 { transmittedCharacter(bit.character) }
            }
        }
    }

    @objc(lengthOfActiveStream)
    override func lengthOfActiveStream() -> Int32 {
        var n = producer - consumer
        if n < 0 { n += CMSTREAMMASK + 1 }
        return n
    }

    @objc(delegate)
    override func delegateObject() -> AnyObject? {
        return delegate
    }

    @objc(setDelegate:)
    override func setDelegate(_ client: AnyObject?) {
        delegate = client
    }

    // delegate
    @objc(transmittedCharacter:)
    override func transmittedCharacter(_ ch: Int32) {
        guard let d = delegate as? NSObject else { return }
        let sel = NSSelectorFromString("transmittedCharacter:")
        if d.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Void
            let fn = unsafeBitCast(d.method(for: sel), to: Fn.self)
            fn(d, sel, ch)
        }
    }
}
