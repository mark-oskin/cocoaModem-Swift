//
//  MooreCode.swift
//  CoreDSP
//
//  CCIR-476 Moore code tables used by SITOR-B / AMTOR / NAVTEX: a 7-bit
//  constant-weight (4 mark + 3 space, or 3 mark + 4 space) error-detecting
//  code -- any received codeword whose bit weight isn't exactly 4 is
//  guaranteed corrupt, which is what makes the FEC/ARQ machinery in
//  MooreDecoder possible. Transcribed verbatim from the original Moore.h
//  (the `#ifdef CCIR476` branch -- ITA3 is a separate, unused code and is not
//  transcribed) -- see http://www.wunclub.com/digfaq/signals.html and
//  http://ftp.funet.fi/pub/dx/text/utility/Moore.code. This is standardized
//  teleprinter code, not something to "clean up": every character position,
//  including the `~` (invalid codeword) and `*` (control) placeholders, is
//  transcribed exactly as tabulated. Follows the CMDataStream/CMAnalyticPair
//  precedent in CoreDSPTypes.swift for porting a C value table as a plain
//  Swift type local to its mode's subfolder.
//
//  Both tables were already transcribed once, faithfully, by an earlier pass
//  at this port (Sources/Swift/SITOR-B/MooreDecoder.swift); the 128-character
//  literal strings below are copied unchanged from that transcription.
//

import Foundation

enum MooreCode {

    /// 128-entry LTRS (letters) shift table, indexed by the 7-bit received codeword.
    /// '~' marks a codeword that isn't a valid assignment in this shift state.
    static let ltrs: [Int8] = table(
        "~~~~~~~\r~~~T~BO~" +
        "~~~\n~NH~~*L~Z~~~" +
        "~~~ ~*N~~ER~D~~~" +
        "~UI~S~~~A~~~~~~~" +
        "~~~V~XM~~*G~B~~~" +
        "~QP~Y~~~W~~~~~~~" +
        "~KC~F~~~J~~~~~~~" +
        "*~~~~~~~~~~~~~~~")

    /// 128-entry FIGS (figures/symbols) shift table, indexed by the 7-bit received codeword.
    static let figs: [Int8] = table(
        "~~~~~~~\r~~~5~?9~" +
        "~~~\n~,#~~*)~+~~~" +
        "~~~ ~*,~~34~$~~~" +
        "~78~*~~~-~~~~~~~" +
        "~~~=~/.~~*&~?~~~" +
        "~10~6~~~2~~~~~~~" +
        "~(:~!~~~'~~~~~~~" +
        "*~~~~~~~~~~~~~~~")

    /// Codeword that means "switch to FIGS shift" (both tables map it to '*', a control marker).
    static let figsCode: Int32 = 0x49
    /// Codeword that means "switch to LTRS shift".
    static let ltrsCode: Int32 = 0x25
    /// Codeword that decodes to nothing (idle filler).
    static let nullCode: Int32 = 0x15
    /// "Repeat request" control codeword used by the ARQ (not FEC) handshake.
    static let rq: Int32 = 0x19
    /// One of the two ARQ idle-phasing codewords (never carries data).
    static let alpha: Int32 = 0x70
    /// The other ARQ idle-phasing codeword.
    static let beta: Int32 = 0x4c

    private static func table(_ s: String) -> [Int8] {
        //  each string above is exactly 128 ASCII characters
        return Array(s.utf8).map { Int8(bitPattern: $0) }
    }
}
