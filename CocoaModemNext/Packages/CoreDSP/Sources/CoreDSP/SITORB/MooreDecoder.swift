//
//  MooreDecoder.swift
//  CoreDSP
//
//  Swift port of SITOR-B's CCIR-476 Moore-code decoder (Sources/Swift/
//  SITOR-B/MooreDecoder.swift, itself a port of MooreDecoder.m). This is the
//  FEC/error-tolerance heart of SITOR-B: it holds a cascaded 6 x 7-bit shift
//  register fed one recovered bit at a time by SITORBitSync, compares the
//  current 7-bit codeword against the codeword received exactly 35 bits ago
//  (register[5] -- SITOR-B/AMTOR repeats every character after a fixed delay
//  as its forward error-detection scheme), and only accepts a character once
//  a "repeat cycle" phase has been statistically located (the syncProbability
//  voting in `importData`). `decodeFrom` additionally tolerates a single
//  bit error in either the original or the repeat, using the CCIR-476
//  constant-weight code's Hamming-neighbor table (`hammingMapped`) to correct
//  it -- this FEC logic (including its wrapping arithmetic, `&+=`/`&>>`) is
//  preserved exactly; it is not something to "clean up".
//
//  Port notes:
//   * The original subclassed the Objective-C CMBaudotDecoder purely to
//     inherit CMPipe's importData/setClient plumbing (Swift couldn't read
//     that base class's @protected ivars, so MooreDecoder fully shadowed all
//     of its state anyway -- see the original's own doc comment). Since this
//     transplant has no CMBaudotDecoder-for-SITOR dependency to satisfy, this
//     port subclasses CMPipe directly; the shadowed `moore_`-prefixed ivars
//     collapse to plain unprefixed stored properties.
//   * The informal `@objc protocol SITORIndicatorControl` / dynamic
//     `control?.setIndicator?(state)` dispatch (reaching the Objective-C
//     SITORRxControl's status-lamp UI) becomes a plain Swift delegate
//     callback (`MooreDecoderDelegate.mooreSyncStateChanged`); `NSSound.beep()`
//     (AppKit, and a real speaker beep has no meaning in a headless DSP
//     core) is dropped in favor of a delegate callback the UI layer can wire
//     up to its own bell sound if desired.
//   * The `weight` table (population count of every byte value 0...255) was
//     computed in the original's `-init` but never read anywhere else in the
//     file (confirmed by inspection) -- vestigial, dropped.
//

import Foundation

/// SITOR-B receive lock/error indicator state, mirrors the original's
/// kSITOROff/On/Wait/FEC/Error constants (SITORRxControl.swift) as a proper enum.
public enum SITORSyncState {
    case off
    case locked
    case waitingForSync
    case fecCorrected
    case error
}

protocol MooreDecoderDelegate: AnyObject {
    func mooreReceivedCharacter(_ c: Int32)
    func mooreSyncStateChanged(_ state: SITORSyncState)
}

extension MooreDecoderDelegate {
    func mooreReceivedCharacter(_ c: Int32) {}
    func mooreSyncStateChanged(_ state: SITORSyncState) {}
}

//  ASCII scalars used for character comparisons
private let cTilde: Int32 = 126        // '~'  (not a codeword)
private let cStar: Int32 = 42          // '*'  (control)
private let cCR: Int32 = 13            // '\r'
private let cLF: Int32 = 10            // '\n'
private let cSpace: Int32 = 32         // ' '
private let cUnderscore: Int32 = 95    // '_'  (error print)
private let cTilde8: Int8 = 126        // '~' as a table byte
private let cBellCodeword: Int32 = 0x34  // LTRS-shift codeword that rings the bell

final class MooreDecoder: CMPipe {

    weak var delegate: MooreDecoderDelegate?

    private var mooreEncoding: [Int8] = MooreCode.ltrs
    private var moore_cr = false
    private var moore_lf = false
    private var moore_usos = false
    private var moore_bell = false

    private var bitRegister = [UInt8](repeating: 0, count: 6)   // 7 bit values
    private var hammingMapped = [UInt8](repeating: 0, count: 128)
    private var cycle: Int32 = 0
    private var squelch: Float = 0.6

    private(set) var syncState: SITORSyncState = .off
    private var err: Int32 = 0
    private var indicatorDelay: Int32 = 0
    private var sync = false
    private var errorPrint = false
    private var syncProbability = [Float](repeating: 0, count: 14)

    override init() {
        super.init()

        //  map index to closest index with a codeword
        let ltrs = MooreCode.ltrs
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

    func setLTRS() {
        mooreEncoding = MooreCode.ltrs
    }

    //  USOS state passed in from the demodulator
    func setUSOS(_ state: Bool) {
        moore_usos = state
    }

    func setBell(_ state: Bool) {
        moore_bell = state
    }

    //  squelch = 0 : maximal squelch
    func setSquelch(_ value: Float) {
        squelch = value
    }

    func setErrorPrint(_ state: Bool) {
        errorPrint = state
    }

    private func setIndicatorState(_ state: SITORSyncState) {
        if syncState == state { return }
        syncState = state
        delegate?.mooreSyncStateChanged(state)
    }

    //  Moore decoder -- receives character data from the bit sync stage
    private func decodeMoore(_ byte: Int32) {
        let b = Int(byte)
        var c: Int32 = (b < 0 || b >= mooreEncoding.count) ? cTilde : Int32(mooreEncoding[b])

        if c == cTilde {
            if errorPrint { delegate?.mooreReceivedCharacter(cUnderscore) }
            return
        }

        if c == cStar {
            switch b {
            case Int(cBellCodeword):
                if moore_bell { delegate?.mooreReceivedCharacter(7) /* BEL */ }
                return
            case Int(MooreCode.figsCode):
                mooreEncoding = MooreCode.figs
                return
            case Int(MooreCode.ltrsCode):
                mooreEncoding = MooreCode.ltrs
                return
            default:
                //  RQ / alpha / beta / NULL and all other control positions -> null
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
        delegate?.mooreReceivedCharacter(c)
        //  unshift on space
        if c == cSpace && moore_usos { mooreEncoding = MooreCode.ltrs }
    }

    /* local */
    //  return decoded character -- return 0 if sync or alpha and -1 if error.
    private func decodeFrom(_ vector: Int, and repeatedFrom: Int) -> Int {
        if vector == Int(MooreCode.alpha) { return 0 }        // ignore idle

        //  find closest codewords
        let codedVector = Int(hammingMapped[vector])
        let codedRepeat = Int(hammingMapped[repeatedFrom])

        if vector == repeatedFrom && vector == codedVector {
            /* perfect copy */
            err = 0
            setIndicatorState(.locked)
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
        let ltrs = MooreCode.ltrs
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

        let kRQ = Int(MooreCode.rq)
        let kAlpha = Int(MooreCode.alpha)

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
                    if syncState == .off || syncState == .error {
                        setIndicatorState(.waitingForSync)
                    }
                } else {
                    switch err {
                    case 0:
                        if indicatorDelay <= 0 { setIndicatorState(.locked) } else { indicatorDelay -= 1 }
                    case 1:
                        setIndicatorState(.fecCorrected)
                        indicatorDelay = 3
                    case 2:
                        setIndicatorState(.error)
                        indicatorDelay = 3
                    default:
                        if indicatorDelay <= 0 { setIndicatorState(.off) } else { indicatorDelay -= 1 }
                    }
                }
            }
        }
    }
}
