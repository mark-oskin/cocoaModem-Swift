//
//  ASCIIDecoderStage.swift
//  CoreDSP
//
//  Final decode stage: receives the ATC's raw N-bit code (in the incoming
//  CMPipe's stream userData) and turns it into a clean ASCII text stream --
//  sanitizing control codes through asciiSanitizeTable and collapsing CR/LF
//  pairs so "\r\n" and "\n\r" each produce exactly one newline.  Faithful
//  transplant of ASCIIDecoder.importData
//  (Sources/Swift/Modems/ASCII/ASCIIDecoder.swift), with the ObjC duck-typed
//  callback replaced by a proper Swift delegate protocol and the NSSound.beep()
//  UI hook dropped (this is a headless DSP core; a bell character is simply
//  not forwarded to text output, matching the original's "swallow it" branch).
//

import Foundation

public protocol ASCIIDecoderDelegate: AnyObject {
    func asciiReceivedCharacter(_ c: Int32)
}

public extension ASCIIDecoderDelegate {
    func asciiReceivedCharacter(_ c: Int32) {}
}

final class ASCIIDecoderStage: CMPipe {

    weak var delegate: ASCIIDecoderDelegate?

    private var cr = false
    private var lf = false

    override func importData(_ pipe: CMPipe!) {
        guard let d = pipe.stream() else { return }
        let b = asciiSanitizeTable[Int(d.pointee.userData) & 0xff]

        if b <= 0 { return }     //  control and diddle characters

        var c: Int32 = (b < 0) ? 0x7e /* '~' */ : b & 0x7f      //  7 bit ASCII

        if c == 0x2a /* '*' */ {
            switch b {
            case 0x05, 0x00:
                //  bell / null -- dropped (no UI bell in a headless DSP core)
                return
            default:
                break
            }
        }

        //  check for cr/lf pairs
        if c == 0x0d /* '\r' */ {
            if lf { lf = false; return }
            if cr { /* ignore multiple c/r */ return }
            c = 0x0a /* '\n' */
            cr = true
            lf = false
        } else if c == 0x0a /* '\n' */ {
            if cr { cr = false; return }
            lf = true
            cr = false
        } else {
            cr = false; lf = false
        }
        delegate?.asciiReceivedCharacter(c)
    }
}
