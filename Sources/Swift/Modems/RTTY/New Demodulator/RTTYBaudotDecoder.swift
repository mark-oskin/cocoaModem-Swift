//
//  RTTYBaudotDecoder.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 3/21/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of RTTYBaudotDecoder.m.
//
//  Baudot decoder with optional control-character echo ("<figs>", "<ltrs>", ...).
//  The CMLtrs / CMFigs tables and CMFIGSCODE / CMLTRSCODE constants are the
//  module-scope definitions from CMFSKModulator.swift.  (The original imported
//  "Baudot.h", a file-local copy of CMBaudot.h.)
//

import Cocoa

@objc(RTTYBaudotDecoder)
class RTTYBaudotDecoder: CMBaudotDecoder {

    internal var printControl: Bool = false

    @objc(initWithDemodulator:)
    override init(demodulator rx: CMFSKDemodulator?) {
        super.init(demodulator: rx)
        printControl = false
    }

    @objc(setPrintControl:)
    func setPrintControl(_ state: Bool) {
        printControl = state
    }

    func sendString(_ s: UnsafePointer<CChar>) {
        var p = s
        while true {
            let c = Int32(p.pointee)
            if c == 0 { return }
            demodulator?.receivedCharacter(c)
            p += 1
        }
    }

    //  Baudot decoder -- receives character data from ATC (see [ atc setClient... ] in setupReceiverChain of RTTYReceiver)
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        guard let d = pipe.stream() else { return }
        let b = Int(d.pointee.userData)

        if printControl {
            switch b {
            case 0x00:
                sendString("<null>")
            case 0x02:
                sendString("<lf>")
            case 0x08:
                sendString("<cr>")
            case Int(CMFIGSCODE):
                sendString("<figs>")
            case Int(CMLTRSCODE):
                sendString("<ltrs>")
            default:
                break
            }
        }
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
}
