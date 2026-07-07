//
//  CWMorseDecoder.swift
//  CoreDSP
//
//  Swift port of the old app's MorseDecoder.swift: dot/dash sequence -> ASCII
//  character (or a short prosign string like "<AR>"), plus the requested
//  inter-word spaces. Runtime ~/Library/Application Support/cocoaModem/Morse.txt
//  customization is dropped (a Mac-app config feature -- see
//  CWMorseCode.swift); the fixed standard table is transplanted as-is.
//

import Foundation

final class CWMorseDecoder {

    /// Emits one decoded character per call (prosign/miskey strings are
    /// broken down into individual ASCII bytes here, exactly like the
    /// original's `demodulator?.receivedCharacter(_:)` calls).
    var onCharacter: ((Int32) -> Void)?

    /// `sequence` is a dot/dash string (e.g. ".-"); pass "" with a non-zero
    /// `wordSpacing` to flush a word gap with no character.
    func newCharacter(_ sequence: String, wordSpacing spacing: Int32) {
        if !sequence.isEmpty {
            let d = cwDecodeToCodeTableIndex(sequence)
            let c = Int32(CWMorseDecodeTable.table[d])
            if c < 0x80 {
                if c != 0x2a /* '*' */ { onCharacter?(c) }
            } else {
                //  extended prosign / miskey code
                let s: String
                switch c {
                case CWProsign.AR:   s = "<AR>"
                case CWProsign.SK:   s = "<SK>"
                case CWProsign.AS:   s = "<AS>"
                case CWProsign.NR:   s = "<NR>"
                case CWProsign.US:   s = "US"
                case CWProsign.AME:  s = "AME"
                case CWProsign.NAME: s = "NAME"
                case CWProsign.RST:  s = "RST"
                case CWProsign.WA:   s = "WA"
                case CWProsign.KN:   s = "KN"
                default:             s = "<??>"
                }
                //  send up to 4 characters
                var count = 0
                for byte in s.utf8 {
                    if count >= 4 { break }
                    onCharacter?(Int32(byte))
                    count += 1
                }
            }
        }
        var i: Int32 = 0
        while i < spacing {
            onCharacter?(0x20 /* ' ' */)
            i += 1
        }
    }
}
