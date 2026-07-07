//
//  CMFSKModulator.swift
//  CoreDSP
//
//  Baudot/ASCII FSK modulator (subclass of CMNCO, exactly like the original --
//  rule #3 keeps the real inheritance since CMNCO is a shared CoreDSP kernel).
//  A ring of CMBinaryStream "bits" is filled by appendASCII(_:) (translated
//  through the ASCII->Baudot `mapping` table, built once in init from the
//  CMLtrs/CMFigs tables) and consumed one sample at a time by
//  getBufferWithDiddleFill(_:length:), which mark/space-keys the inherited
//  CMNCO oscillator at the configured baud rate with 1.5 stop bits.
//
//  Dropped relative to the original: OOK/two-tone-test support (RTTYModulator/
//  RTTYModulatorBase additions, TX-side test features unrelated to normal
//  Baudot keying) and the AppDelegate/fskHub robust-mode echo call (UI-layer
//  coupling with no equivalent in this headless module). Everything else --
//  the varicode-equivalent Baudot bit packing, USOS, the "robust mode" extra
//  shift-character insertion, and the diddle/idle-fill logic -- is preserved
//  verbatim.
//

import Foundation

private let kRobustThreshold: Int32 = 16

protocol CMFSKModulatorDelegate: AnyObject {
    func fskTransmittedCharacter(_ ch: Int32)
}

extension CMFSKModulatorDelegate {
    func fskTransmittedCharacter(_ ch: Int32) {}
}

final class CMFSKModulator: CMNCO {

    weak var delegate: CMFSKModulatorDelegate?
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

    var bitsPerCharacter: Int32 = 0

    var spaceFollowedFIGS: Bool = false     //  USOS "compatibility mode"

    override init() {
        super.init()
        var tonepair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)
        delegate = nil
        producer = 0
        consumer = 0
        usos = true
        shifted = LTRSTATE
        spaceFollowedFIGS = false
        robust = false
        robustCount = 0
        sideband = 0
        bitsPerCharacter = 5
        setTonePair(&tonepair)
        setStopBits(1.5)
        //  create ascii to baudot translation
        //  LSB 5 bits is the baudot code, LTRSHIFT and FIGSHIFT are the flag bits
        for i in 0..<128 { mapping[i] = 0 }  // fill with Baudot blank
        let star = rttyChar("*")
        for i in 0..<32 {
            let ltr = CMLtrs[i]
            let fig = CMFigs[i]
            if ltr == fig && ltr != 0 && ltr != star {
                mapping[Int(ltr)] = Int32(i) | CMLTRSHIFT | CMFIGSHIFT
            } else {
                if ltr != 0 && ltr != star {
                    mapping[Int(ltr)] = Int32(i) | CMLTRSHIFT
                    if ltr >= rttyChar("A") && ltr <= rttyChar("Z") { mapping[Int(ltr - rttyChar("A") + rttyChar("a"))] = Int32(i) | CMLTRSHIFT }
                }
                if fig != 0 && fig != star {
                    mapping[Int(fig)] = Int32(i) | CMFIGSHIFT
                }
            }
        }
    }

    //  Rest condition = Mark.  startbit = 0 = space, stop bit = 1 = mark
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
    func setStopBits(_ stopBits: Float) {
        //  sanity check
        if stopBits < 0.99 || stopBits > 2.01 { return }

        stopDuration = stopBits
        stopDDA = bitDDA / Double(stopDuration)
        stopBit.dda = stopDDA
        stopBit.polarity = 1
        stopBit.character = 0
    }

    func setSideband(_ usb: Int32) {
        sideband = usb
    }

    func setUSOS(_ state: Bool) {
        usos = state
    }

    func setRobustMode(_ state: Bool) {
        robust = state
    }

    func setBitsPerCharacter(_ bits: Int32) {
        bitsPerCharacter = bits
    }

    //  append a long mark tone (11 bits long, with no start bit)
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

    //  consolidate shift here
    func shiftToState(_ state: Bool) {
        appendBits((state == FIGSTATE) ? CMFIGSCODE : CMLTRSCODE, ascii: 0)
        shifted = state
        robustCount = 0
    }

    //  append a single ascii character
    func appendASCII(_ ascii: Int32) {
        var ascii = ascii
        var code: Int32
        var echo: Int32

        //  direct LTRS/FIGS output
        if ascii == CMLTRSCODE || ascii == CMFIGSCODE {
            lock.lock()
            shiftToState(ascii == CMFIGSCODE)
            lock.unlock()
            return
        }

        if ascii <= 26 {
            //  control characters
            switch rttyChar("a") + ascii - 1 {
            case rttyChar("e"):
                appendDiddle(0)
                appendDiddle(ascii)
                return
            case rttyChar("z"):
                appendDiddle(ascii)
                return
            default:
                break
            }
        }
        echo = ascii

        switch ascii {
        case rttyChar("="):
            /* LTRS */
            code = CMLTRSCODE | CMLTRSHIFT
            ascii = 0
        case rttyChar("|"):
            /* long mark character */
            appendLongMark()
            appendBits(CMLTRSCODE, ascii: 0)
            appendBits(CMLTRSCODE, ascii: 0)
            return
        default:
            if ascii == rttyChar("\n") {
                //  transmit newline from textview as CR
                ascii = rttyChar("\r")
                echo = 0
            }
            code = mapping[Int(ascii & 0xff)]              // ASCII to Baudot map
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

            //  send extra shift character after a space when we are in robust mode
            if ascii == rttyChar(" ") {
                if shifted == FIGSTATE { spaceFollowedFIGS = true }         //  for USOS compatibility
                if usos == true {
                    //  note: no explicit LTRS character is sent
                    shifted = LTRSTATE
                }
            }
            if robustCount >= kRobustThreshold {
                //  add in extra FIGS and LTRS for robustness, stay in the same shift
                shiftToState(shifted == FIGSTATE)
            }

            if ascii == rttyChar("\r") {
                //  send \n from text view as cr/lf pair
                appendBits(mapping[Int(rttyChar("\n"))] & 0x1f, ascii: rttyChar("\n"))
            }
            lock.unlock()
        }
    }

    //  append the string, replacing completely any previous string that is in the buffer if clearExistingCharacters is true
    func appendString(_ s: String, clearExistingCharacters reset: Bool) {
        if reset { producer = 0; consumer = 0 }
        for scalar in s.unicodeScalars { appendASCII(Int32(scalar.value)) }
        bitTheta = 0
        current = tonePair.mark
        currentBitDDA = bitDDA
    }

    func clearOutput() {
        if consumer < (producer - 1) { consumer = producer - 1 }
    }

    //  consume from the current buffer
    //  add diddle if there is no more bits to consume
    //  (note: at 11025 samples/sec, an RTTY character takes up about 1830 samples)
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

    func lengthOfActiveStream() -> Int32 {
        var n = producer - consumer
        if n < 0 { n += CMSTREAMMASK + 1 }
        return n
    }

    // delegate
    private func transmittedCharacter(_ ch: Int32) {
        delegate?.fskTransmittedCharacter(ch)
    }
}
