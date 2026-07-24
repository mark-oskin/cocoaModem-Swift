//
//  CMFSKModulator.swift
//  CoreModem
//
//  Created by Kok Chen on 10/31/05.
//  Swift port of CMFSKModulator.m.
//
//  Baudot/ASCII FSK modulator.  Subclass of CMNCO.  A ring of CMBinaryStream
//  "bits" (CMSTREAMMASK+1 = 65536 entries) is filled by the append* methods and
//  consumed one sample at a time by -getBufferWithDiddleFill:length:.
//
//  The Baudot letter/figure tables (CMLtrs / CMFigs) and the shift-code
//  constants were static data in CMBaudot.h; they are inlined here as Swift
//  constants (they are pure constant data and used only by this class tree).
//

import Foundation

//  ---- shared FSK constants (were #defines in CMFSKModulator.h) ----
let CMLTRSHIFT: Int32 = 0x20
let CMFIGSHIFT: Int32 = 0x40
let CMSTREAMMASK: Int32 = 0xffff

let FIGSTATE: Bool = true
let LTRSTATE: Bool = false

//  ---- Baudot data (were static arrays / #defines in CMBaudot.h) ----
let CMFIGSCODE: Int32 = 0x1b
let CMLTRSCODE: Int32 = 0x1f

private func ch(_ c: Unicode.Scalar) -> Int32 { return Int32(c.value) }

let CMLtrs: [Int32] = [
    ch("*"), ch("E"), 0x0a, ch("A"), ch(" "), ch("S"), ch("I"), ch("U"),
    0x0d, ch("D"), ch("R"), ch("J"), ch("N"), ch("F"), ch("C"), ch("K"),
    ch("T"), ch("Z"), ch("L"), ch("W"), ch("H"), ch("Y"), ch("P"), ch("Q"),
    ch("O"), ch("B"), ch("G"), ch("*"), ch("M"), ch("X"), ch("V"), ch("*")
]

let CMFigs: [Int32] = [
    ch("*"), ch("3"), 0x0a, ch("-"), ch(" "), ch("*"), ch("8"), ch("7"),
    0x0d, ch("$"), ch("4"), ch("'"), ch(","), ch("!"), ch(":"), ch("("),
    ch("5"), ch("\""), ch(")"), ch("2"), ch("#"), ch("6"), ch("0"), ch("1"),
    ch("9"), ch("?"), ch("&"), ch("*"), ch("."), ch("/"), ch(";"), ch("*")
]

//  output bit stream element (was CMBinaryStream in CMFSKModulator.h)
struct CMBinaryStream {
    var polarity: Int32 = 0     //  0 == mark, 1 == space
    var dda: Double = 0
    var character: Int32 = 0    //  either 0 or an ASCII character
    var code: Int32 = 0         //  v0.88  0 or the original code (e.g. Baudot)
}

private let kRobustThreshold: Int32 = 16

@objc(CMFSKModulator)
class CMFSKModulator: CMNCO {

    weak var delegate: AnyObject?
    var tonePair = CMTonePair(mark: 0, space: 0, baud: 0)
    var bitDDA: Double = 0
    var currentBitDDA: Double = 0
    var stopDDA: Double = 0
    var stopDuration: Float = 0             // stop bit duration

    var stopBit = CMBinaryStream()
    var startBit = CMBinaryStream()
    var dataBit = [CMBinaryStream](repeating: CMBinaryStream(), count: 2)
    var stream = [CMBinaryStream](repeating: CMBinaryStream(), count: Int(CMSTREAMMASK) + 1)

    var mapping = [Int32](repeating: 0, count: 256)     // ascii to baudot mapping
    var sideband: Int32 = 0                 // 0 = LSB, 1 = USB
    var usos: Bool = false
    var shifted: Bool = false
    var robust: Bool = false
    var robustCount: Int32 = 0

    var bitsPerCharacter: Int32 = 0         //  v0.83

    var spaceFollowedFIGS: Bool = false     //  v0.88  USOS "compatibility mode"

    override init() {
        super.init()
        var tonepair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)
        delegate = nil
        producer = 0
        consumer = 0
        usos = true
        shifted = LTRSTATE
        spaceFollowedFIGS = false           //  v0.88
        robust = false
        robustCount = 0
        sideband = 0
        bitsPerCharacter = 5
        setTonePair(&tonepair)
        setStopBits(1.5)
        //  create ascii to baudot translation
        //  LSB 5 bits is the baudot code, LTRSHIFT and FIGSHIFT are the flag bits
        for i in 0..<128 { mapping[i] = 0 }  // fill with Baudot blank
        let star = ch("*")
        for i in 0..<32 {
            let ltr = CMLtrs[i]
            let fig = CMFigs[i]
            if ltr == fig && ltr != 0 && ltr != star {
                mapping[Int(ltr)] = Int32(i) | CMLTRSHIFT | CMFIGSHIFT
            } else {
                if ltr != 0 && ltr != star {
                    mapping[Int(ltr)] = Int32(i) | CMLTRSHIFT
                    if ltr >= ch("A") && ltr <= ch("Z") { mapping[Int(ltr - ch("A") + ch("a"))] = Int32(i) | CMLTRSHIFT }
                }
                if fig != 0 && fig != star {
                    mapping[Int(fig)] = Int32(i) | CMFIGSHIFT
                }
            }
        }
    }

    //  Rest condition = Mark.  startbit = 0 = space, stop bit = 1 = mark
    @objc(setTonePair:)
    func setTonePair(_ inTonePair: UnsafePointer<CMTonePair>) {
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
        currentBitDDA = bitDDA

        startBit.dda = bitDDA
        startBit.polarity = 0
        startBit.character = 0
        dataBit[0].dda = bitDDA
        dataBit[0].polarity = 0
        dataBit[0].character = 0
        dataBit[1].dda = bitDDA
        dataBit[1].polarity = 1
        dataBit[1].character = 0
        setStopBits(stopDuration)
    }

    //  Stop bits (defaulted to 1.5 by init)
    @objc(setStopBits:)
    func setStopBits(_ stopBits: Float) {
        //  sanity check
        if stopBits < 0.99 || stopBits > 2.01 { return }

        stopDuration = stopBits
        stopDDA = bitDDA / Double(stopDuration)
        stopBit.dda = stopDDA
        stopBit.polarity = 1
        stopBit.character = 0
    }

    @objc(setSideband:)
    func setSideband(_ usb: Int32) {
        sideband = usb
    }

    @objc(setUSOS:)
    func setUSOS(_ state: Bool) {
        usos = state
    }

    @objc(setRobustMode:)
    func setRobustMode(_ state: Bool) {
        robust = state
        (NSApp.delegate as? AppDelegate)?.application()?.fskHub()?.setRobustMode(robust)
    }

    @objc(setBitsPerCharacter:)
    func setBitsPerCharacter(_ bits: Int32) {
        bitsPerCharacter = bits
    }

    //  append a long mark tone (11 bits long, with no start bit)
    @objc(appendLongMark)
    func appendLongMark() {
        stream[Int(producer)] = stopBit
        stream[Int(producer)].dda /= 11.0
        producer = (producer + 1) & CMSTREAMMASK
    }

    /* local */
    //  append diddle (LTRS)
    func appendDiddle(_ flag: Int32) {
        var diddle = CMLTRSCODE
        lock.lock()
        shifted = LTRSTATE
        var tempProducer = producer
        stream[Int(tempProducer)] = startBit
        stream[Int(tempProducer)].character = flag   // flag for special diddle character that returns data to RTTY object
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
    func appendBits(_ code: Int32, ascii: Int32) {
        var code = code
        var tempProducer = producer
        stream[Int(tempProducer)] = startBit
        stream[Int(tempProducer)].character = ascii
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

    //  v0.88 consolidate shift here
    @objc(shiftToState:)
    func shiftToState(_ state: Bool) {
        appendBits((state == FIGSTATE) ? CMFIGSCODE : CMLTRSCODE, ascii: 0)
        shifted = state
        robustCount = 0
    }

    //  append a single ascii character
    @objc(appendASCII:)
    func appendASCII(_ ascii: Int32) {
        var ascii = ascii
        var code: Int32
        var echo: Int32

        //  direct LTRS/FIGS output (v0.88 added here from RTTYModulatorBase, but apparently unused?)
        if ascii == CMLTRSCODE || ascii == CMFIGSCODE {
            lock.lock()
            shiftToState(ascii == CMFIGSCODE)
            lock.unlock()
            return
        }

        if ascii <= 26 {
            //  control characters
            switch ch("a") + ascii - 1 {
            case ch("e"):
                appendDiddle(0)
                appendDiddle(ascii)
                return
            case ch("z"):
                appendDiddle(ascii)
                return
            default:
                break
            }
        }
        echo = ascii

        switch ascii {
        case ch("="):
            /* LTRS */
            code = CMLTRSCODE | CMLTRSHIFT
            ascii = 0
        case ch("|"):
            /* long mark character */
            appendLongMark()
            appendBits(CMLTRSCODE, ascii: 0)
            appendBits(CMLTRSCODE, ascii: 0)
            return
        default:
            if ascii == ch("\n") {
                //  transmit newline from textview as CR
                ascii = ch("\r")
                echo = 0
            }
            code = mapping[Int(ascii)]              // ASCII to Baudot map
        }

        if code != 0 {

            if robust { robustCount += 1 }

            lock.lock()

            if spaceFollowedFIGS {

                if robust == true {

                    //  check if we need to force a LTRS shift (for USOS) or FIGS shift (for non-USOS)
                    if usos == true {
                        //  transmitting with USOS, check for the case "1<space>A"
                        if (code & CMFIGSHIFT) == 0 { shiftToState(LTRSTATE) }
                    } else {
                        //  transmitting with non-USOS, check for the case "1<space>2"
                        if (code & CMLTRSHIFT) == 0 { shiftToState(FIGSTATE) }
                    }
                }
                spaceFollowedFIGS = false
            }

            if shifted == FIGSTATE {
                // in FIGS at the moment, shift to LTRS if needed
                if (code & CMFIGSHIFT) == 0 { shiftToState(LTRSTATE) }
            } else {
                //  in LTRS at the moment, shift to FIGS if needed
                if (code & CMLTRSHIFT) == 0 { shiftToState(FIGSTATE) }
            }
            //  send character
            appendBits(code & 0x1f, ascii: echo)

            //  v0.88  now send extra shift character after a space when we are in robust mode
            if ascii == ch(" ") {
                if shifted == FIGSTATE { spaceFollowedFIGS = true }         //  v0.88 for USOS compatibility
                if usos == true {
                    //  note: no explicit LTRS character is sent
                    shifted = LTRSTATE
                }
            }
            if robustCount >= kRobustThreshold {
                //  add in extra FIGS and LTRS for robustness, stay in the same shift
                shiftToState(shifted == FIGSTATE)
            }

            if ascii == ch("\r") {
                //  send \n from text view as cr/lf pair
                appendBits(mapping[Int(ch("\n"))] & 0x1f, ascii: ch("\n"))
            }
            lock.unlock()
        }
    }

    //  append the string, replacing completely any previous string that is in the buffer if clearExistingCharacters is true
    @objc(appendString:clearExistingCharacters:)
    func appendString(_ s: UnsafePointer<CChar>, clearExistingCharacters reset: Bool) {
        if reset { producer = 0; consumer = 0 }
        var p = s
        while p.pointee != 0 {
            appendASCII(Int32(p.pointee))
            p += 1
        }
        bitTheta = 0
        current = tonePair.mark
        currentBitDDA = bitDDA
    }

    @objc(clearOutput)
    func clearOutput() {
        if consumer < (producer - 1) { consumer = producer - 1 }
    }

    //  consume from the current buffer
    //  add diddle if there is no more bits to consume
    //  (note: at 11025 samples/sec, an RTTY character takes up about 1830 samples)
    @objc(getBufferWithDiddleFill:length:)
    func getBufferWithDiddleFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) {
            buf[i] = sin(current)
            //  modulation
            if modulation(currentBitDDA) {
                consumer = (consumer + 1) & CMSTREAMMASK
                if consumer == producer { appendDiddle(0) }
                let bit = stream[Int(consumer)]
                currentBitDDA = bit.dda
                current = (bit.polarity == 0) ? tonePair.space : tonePair.mark
                if bit.character != 0 { transmittedCharacter(bit.character) }
            }
        }
    }

    @objc(lengthOfActiveStream)
    func lengthOfActiveStream() -> Int32 {
        var n = producer - consumer
        if n < 0 { n += CMSTREAMMASK + 1 }
        return n
    }

    @objc(delegate)
    func delegateObject() -> AnyObject? {
        return delegate
    }

    @objc(setDelegate:)
    func setDelegate(_ client: AnyObject?) {
        delegate = client
    }

    // delegate
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
