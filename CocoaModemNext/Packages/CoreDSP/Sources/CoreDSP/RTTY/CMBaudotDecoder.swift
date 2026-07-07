//
//  CMBaudotDecoder.swift
//  CoreDSP
//
//  Baudot decoder: receives 5-bit Baudot codes in the incoming stream's
//  `userData` (as decoded by CMATC.exportCharacter) and translates them to
//  ASCII using the CMLtrs/CMFigs tables, tracking LTRS/FIGS shift state,
//  CR/LF pairing, and unshift-on-space (USOS).
//
//  Dropped relative to the original: the NSSound.beep() bell alert (no audio
//  concept in this headless module -- the BEL control code is still
//  recognized and swallowed, just silently) and RTTYBaudotDecoder's
//  `printControl` debug echo of raw control codes (a UI/diagnostic feature,
//  not part of normal decode).
//

import Foundation

final class CMBaudotDecoder: CMPipe {

    weak var demodulator: CMFSKDemodulator?
    //  decoder states
    var bell: Bool = false
    var cr: Bool = false
    var lf: Bool = false
    var usos: Bool = false
    var encoding: [Int32] = CMLtrs     //  points to CMLtrs or CMFigs

    init(demodulator rx: CMFSKDemodulator?) {
        super.init()
        demodulator = rx
        encoding = CMLtrs
        cr = false; lf = false; usos = false; bell = false
    }

    func setLTRS() {
        encoding = CMLtrs
    }

    //  Baudot decoder -- receives character data from the ATC stage
    override func importData(_ pipe: CMPipe!) {
        guard let d = pipe.stream() else { return }
        let b = Int(d.pointee.userData)
        var c: Int32 = (b < 0) ? 0x7e /* '~' */ : encoding[b & 0x1f]
        if c == 0x2a /* '*' */ {
            switch b {
            case 0x05:
                //  bell -- no audio alert in this headless module, just swallow it
                return
            case 0x00:
                // null
                return
            case Int(CMFIGSCODE):
                encoding = CMFigs
                return
            case Int(CMLTRSCODE):
                encoding = CMLtrs
                return
            default:
                break
            }
        }
        //  check for cr/lf pairs
        if c == 0x0d /* '\r' */ {
            if lf {
                lf = false
                return
            }
            if cr { /* ignore multiple c/r */ return }
            c = 0x0a /* '\n' */
            cr = true
            lf = false
        } else {
            if c == 0x0a /* '\n' */ {
                if cr {
                    cr = false
                    return
                }
                lf = true
                cr = false
            } else {
                cr = false; lf = false
            }
        }
        demodulator?.receivedCharacter(c)
        //  unshift on space
        if c == 0x20 /* ' ' */ && usos { encoding = CMLtrs }
    }

    //  USOS state passed in from CMFSKDemodulator
    func setUSOS(_ state: Bool) {
        usos = state
    }

    func setBell(_ state: Bool) {
        bell = state
    }
}
