//
//  MooreDecoder.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/6/06.
//
//  Swift port of MooreDecoder.m.  MooreDecoder remains a subclass of the
//  Objective-C class CMBaudotDecoder (CMBaudotDecoder stays Objective-C; its
//  header is in the bridging header).
//
//  Note on inherited state: Swift cannot read an Objective-C superclass's
//  @protected instance variables (demodulator, encoding, cr, lf, usos, bell).
//  MooreDecoder fully manages its own copies of that state and overrides every
//  base setter (initWithDemodulator:, setLTRS, setUSOS:, setBell:) plus
//  importData: so the base copies are never consulted.  This mirrors the C
//  behaviour exactly.
//

import Cocoa

//  SITOR indicator states (mirror the #defines in SITORRxControl.h -- must
//  stay numerically identical because SITORRxControl -setIndicator: switches
//  on them).
private let kSITOROff: Int32 = 0
private let kSITOROn: Int32 = 1
private let kSITORWait: Int32 = 2
private let kSITORFEC: Int32 = 3
private let kSITORError: Int32 = 4

//  CCIR476 code points (see Moore.h, CCIR476 branch)
private let kRQ = 0x19
private let kAlpha = 0x70
private let kMooreFigsCode = 0x49
private let kMooreLtrsCode = 0x25

//  ASCII scalars used for character comparisons
private let cTilde: Int32 = 126        // '~'  (not a codeword)
private let cStar: Int32 = 42          // '*'  (control)
private let cCR: Int32 = 13            // '\r'
private let cLF: Int32 = 10            // '\n'
private let cSpace: Int32 = 32         // ' '
private let cUnderscore: Int32 = 95    // '_'  (error print)
private let cTilde8: Int8 = 126        // '~' as a table byte

//  Informal, dynamically dispatched access to -[SITORRxControl setIndicator:]
//  (SITORRxControl remains Objective-C).  Resolved through AnyObject message
//  dispatch (like RTTYMonitor's scope view) so we do not have to pull
//  SITORRxControl.h into the bridging header.
@objc private protocol SITORIndicatorControl {
    @objc func setIndicator(_ state: Int32)
}

@objc(MooreDecoder)
class MooreDecoder: CMBaudotDecoder {

    //  --- CCIR476 Moore code tables (from Moore.h) ---
    private static func table(_ s: String) -> [Int8] {
        //  each String below is exactly 128 ASCII characters
        return Array(s.utf8).map { Int8(bitPattern: $0) }
    }

    private static let mooreLtrs: [Int8] = table(
        "~~~~~~~\r~~~T~BO~" +
        "~~~\n~NH~~*L~Z~~~" +
        "~~~ ~*N~~ER~D~~~" +
        "~UI~S~~~A~~~~~~~" +
        "~~~V~XM~~*G~B~~~" +
        "~QP~Y~~~W~~~~~~~" +
        "~KC~F~~~J~~~~~~~" +
        "*~~~~~~~~~~~~~~~")

    private static let mooreFigs: [Int8] = table(
        "~~~~~~~\r~~~5~?9~" +
        "~~~\n~,#~~*)~+~~~" +
        "~~~ ~*,~~34~$~~~" +
        "~78~*~~~-~~~~~~~" +
        "~~~=~/.~~*&~?~~~" +
        "~10~6~~~2~~~~~~~" +
        "~(:~!~~~'~~~~~~~" +
        "*~~~~~~~~~~~~~~~")

    //  shadow of the base @protected state
    private weak var moore_demodulator: CMFSKDemodulator?
    private var encoding: [Int8] = MooreDecoder.mooreLtrs
    private var moore_cr = false
    private var moore_lf = false
    private var moore_usos = false
    private var moore_bell = false

    private var bitRegister = [UInt8](repeating: 0, count: 6)   // 7 bit values
    private var hammingMapped = [UInt8](repeating: 0, count: 128)
    private var weight = [Int32](repeating: 0, count: 256)
    private var syncProbability = [Float](repeating: 0, count: 14)
    private var cycle: Int32 = 0
    private var squelch: Float = 0.0

    private var decodeState: Int32 = kSITOROff
    private var err: Int32 = 0
    private var indicatorDelay: Int32 = 0
    private var sync = false
    private var errorPrint = false

    private var control: AnyObject?

    @objc(initWithDemodulator:)
    override init(demodulator rx: CMFSKDemodulator!) {
        super.init()
        squelch = 0.0
        control = nil
        moore_demodulator = rx
        encoding = MooreDecoder.mooreLtrs
        decodeState = kSITOROff
        for i in 0..<6 { bitRegister[i] = 0 }
        moore_cr = false; moore_lf = false; moore_usos = false; moore_bell = false

        for i in 0..<256 {
            var w: Int32 = 0
            var n = i
            for _ in 0..<8 {
                if (n & 0x1) != 0 { w &+= 1 }
                n >>= 1
            }
            weight[i] = w
        }
        indicatorDelay = 0
        //  initialize sync
        cycle = 0
        for i in 0..<14 { syncProbability[i] = 0.0 }

        //  map index to closest index with a codeword
        let ltrs = MooreDecoder.mooreLtrs
        for i in 0..<128 {
            hammingMapped[i] = UInt8(truncatingIfNeeded: i)
            if ltrs[i] == cTilde8 {
                //  not a codeword, try to remap
                var n = 0x40
                for _ in 0..<7 {
                    let idx = i ^ n
                    if ltrs[idx] != cTilde8 {
                        hammingMapped[i] = UInt8(truncatingIfNeeded: idx)
                        break
                    }
                    n >>= 1
                }
            }
        }
    }

    override func setLTRS() {
        encoding = MooreDecoder.mooreLtrs
    }

    //  USOS state passed in from CMFSKDemodulator
    override func setUSOS(_ state: Bool) {
        moore_usos = state
    }

    override func setBell(_ state: Bool) {
        moore_bell = state
    }

    //  squelch = 0 : maximal squelch
    @objc(setSquelch:)
    func setSquelch(_ value: Float) {
        squelch = value
    }

    @objc(setControl:)
    func setControl(_ ctrl: AnyObject?) {
        control = ctrl
    }

    @objc(setErrorPrint:)
    func setErrorPrint(_ state: DarwinBoolean) {
        errorPrint = state.boolValue
    }

    private func setIndicatorState(_ state: Int32) {
        if decodeState == state { return }
        decodeState = state
        control?.setIndicator?(state)
    }

    //  Moore decoder -- receives character data from the bit sync stage
    private func decodeMoore(_ byte: Int32) {
        let b = Int(byte)
        var c: Int32 = (b < 0 || b >= encoding.count) ? cTilde : Int32(encoding[b])

        if c == cTilde {
            if errorPrint { moore_demodulator?.receivedCharacter(cUnderscore) }
            return
        }

        if c == cStar {
            switch b {
            case 0x34:
                if moore_bell { NSSound.beep() }
                return
            case kMooreFigsCode:
                encoding = MooreDecoder.mooreFigs
                return
            case kMooreLtrsCode:
                encoding = MooreDecoder.mooreLtrs
                return
            default:
                //  0x70 and all other control positions -> null
                return
            }
        }
        //  check for cr/lf pairs
        if c == cCR {
            if moore_lf {
                moore_lf = false
                return
            }
            if moore_cr { /* ignore multiple c/r */ return }
            c = cLF
            moore_cr = true
            moore_lf = false
        } else {
            if c == cLF {
                if moore_cr {
                    moore_cr = false
                    return
                }
                moore_lf = true
                moore_cr = false
            } else {
                moore_cr = false; moore_lf = false
            }
        }
        moore_demodulator?.receivedCharacter(c)
        //  unshift on space
        if c == cSpace && moore_usos { encoding = MooreDecoder.mooreLtrs }
    }

    /* local */
    //  return decoded character -- return 0 if sync or alpha and -1 if error.
    private func decodeFrom(_ vector: Int, and repeatedFrom: Int) -> Int {
        if vector == kAlpha { return 0 }        // ignore idle

        //  find closest codewords
        let codedVector = Int(hammingMapped[vector])
        let codedRepeat = Int(hammingMapped[repeatedFrom])

        if vector == repeatedFrom && vector == codedVector {
            /* perfect copy */
            err = 0
            setIndicatorState(kSITOROn)
            return vector
        }

        //  squelch any possible error
        if squelch < 0.25 {
            err = 2
            return -1
        }

        //  allow one of them to have a one bit error
        err = 1
        if codedVector == repeatedFrom { return codedVector }
        if codedRepeat == vector { return vector }

        if squelch < 0.5 {
            err = 2
            return -1
        }

        //  allow both to have a one bit error, as long as the corrections match
        let ltrs = MooreDecoder.mooreLtrs
        if codedRepeat == codedVector && ltrs[codedVector] != cTilde8 { return codedVector }

        if squelch < 0.75 {
            err = 2
            return -1
        }

        //  allow either to go through if it is mapped
        err = 2
        if ltrs[codedVector] != cTilde8 { return codedVector }
        if ltrs[codedRepeat] != cTilde8 { return codedRepeat }

        return -1
    }

    //  data is exported from SITORBitSync to here.
    //  The stream array contains the sampled data at mid-bit; stream.samples is
    //  the number of bits (usually 19 to 20 in a 256 sample buffer at 11025 s/s).
    override func importData(_ pipe: CMPipe!) {
        guard let streamPtr = pipe.stream() else { return }
        let bits = Int(streamPtr.pointee.samples)
        guard bits > 0, let array = streamPtr.pointee.array else { return }

        for i in 0..<bits {
            //  first shift the 7-bit registers
            var j = 5
            while j >= 1 {
                bitRegister[j] = bitRegister[j] &>> 1
                if (bitRegister[j - 1] & 0x1) != 0 { bitRegister[j] |= 0x40 }
                j -= 1
            }
            bitRegister[0] = bitRegister[0] &>> 1
            if array[i] > 0 { bitRegister[0] |= 0x40 }

            //  look for sync clues
            cycle = (cycle == 13) ? 0 : (cycle &+ 1)

            let vector = Int(bitRegister[0] & 0x7f)
            let repeatedFrom = Int(bitRegister[5])

            //  assign probabilities that this cycle starts a repeated character
            var prob: Float = 0.0
            sync = false

            if vector == kAlpha && Int(bitRegister[1]) == kRQ {
                prob = 3.0          // RQ-alpha pair received
                sync = true
            } else {
                if vector == repeatedFrom && vector != kRQ {
                    prob = 0.01     // prime during long no-RQ periods
                } else {
                    if vector == kAlpha && repeatedFrom == kRQ { prob = 2.0 }
                }
            }
            //  modifiers of base probabilities
            if Int(bitRegister[1]) == kRQ { prob *= 1.4 }
            if Int(bitRegister[2]) == kAlpha { prob *= 1.4 }
            if Int(bitRegister[3]) == kRQ { prob *= 1.4 }
            if Int(bitRegister[4]) == kAlpha { prob *= 1.4 }
            if repeatedFrom == kRQ { prob *= 1.4 }

            if prob > 0.0 {
                //  update sync probabilities
                var maxv: Float = 0.01
                for k in 0..<14 {
                    if Int32(k) != cycle { syncProbability[k] *= 0.98 }
                    if syncProbability[k] > maxv { maxv = syncProbability[k] }
                }
                syncProbability[Int(cycle)] += prob / maxv
                //  make sure it does not overflow floating point range!
                if syncProbability[Int(cycle)] > 100.0 {
                    for k in 0..<14 { syncProbability[k] *= 0.01 }
                }
            }

            //  find out if this is the beginning of the repeat cycle
            var index = 0
            var best = syncProbability[0]
            for k in 1..<14 {
                let test = syncProbability[k]
                if test > best {
                    best = test
                    index = k
                }
            }

            //  check for printable character if this is the repeated bit cycle
            if Int32(index) == cycle {
                //  bit cycle for repeated character
                let result = decodeFrom(vector, and: repeatedFrom)
                if result != 0 {
                    decodeMoore(Int32(truncatingIfNeeded: result))
                }

                if sync {
                    if decodeState == kSITOROff || decodeState == kSITORError {
                        setIndicatorState(kSITORWait)
                    }
                } else {
                    switch err {
                    case 0:
                        if indicatorDelay <= 0 { setIndicatorState(kSITOROn) } else { indicatorDelay -= 1 }
                    case 1:
                        setIndicatorState(kSITORFEC)
                        indicatorDelay = 3
                    case 2:
                        setIndicatorState(kSITORError)
                        indicatorDelay = 3
                    default:
                        if indicatorDelay <= 0 { setIndicatorState(kSITOROff) } else { indicatorDelay -= 1 }
                    }
                }
            }
        }
    }
}
