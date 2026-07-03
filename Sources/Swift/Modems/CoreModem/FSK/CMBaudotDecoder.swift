//
//  CMBaudotDecoder.swift
//  CoreModem
//
//  Created by Kok Chen on 10/24/05.
//	(ported from cocoaModem, original file dated Fri Jul 16 2004)
//  Swift port of CMBaudotDecoder.m.
//
//  Baudot decoder.  Subclass of CMPipe.  Receives 5-bit Baudot codes in the
//  incoming stream's userData and translates them to ASCII using the CMLtrs /
//  CMFigs tables (defined at module scope in CMFSKModulator.swift -- reused
//  here, NOT redefined).  The letter/figure shift state is held in `encoding`.
//
//  The C indexed the 32-entry table directly with the userData value; Swift
//  masks the index with 0x1f before subscripting so a stray value can never
//  trap (the valid Baudot range is 0..31, which the mask preserves exactly).
//

import Cocoa

@objc(CMBaudotDecoder)
class CMBaudotDecoder: CMPipe {

    weak var demodulator: CMFSKDemodulator?
    //  decoder states
    internal var bell: Bool = false
    internal var cr: Bool = false
    internal var lf: Bool = false
    internal var usos: Bool = false
    internal var encoding: [Int32] = CMLtrs     //  points to CMLtrs or CMFigs (module-scope tables)

    @objc(initWithDemodulator:)
    init(demodulator rx: CMFSKDemodulator?) {
        super.init()
        demodulator = rx
        encoding = CMLtrs
        cr = false; lf = false; usos = false; bell = false
    }

    @objc(setLTRS)
    func setLTRS() {
        encoding = CMLtrs
    }

    //  Baudot decoder -- receives character data from ATC (see [ atc setClient... ] in setupReceiverChain of RTTYReceiver)
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        guard let d = pipe.stream() else { return }
        let b = Int(d.pointee.userData)
        var c: Int32 = (b < 0) ? 0x7e /* '~' */ : encoding[b & 0x1f]
        if c == 0x2a /* '*' */ {
            switch b {
            case 0x05:
                if bell { NSSound.beep() }
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
    @objc(setUSOS:)
    func setUSOS(_ state: Bool) {
        usos = state
    }

    @objc(setBell:)
    func setBell(_ state: Bool) {
        bell = state
    }
}
