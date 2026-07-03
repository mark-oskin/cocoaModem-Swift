//
//  MorseDecoder.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/2/06.
//  Swift port of MorseDecoder.m.
//
//  Morse (CW) decoder.  Subclass of CMBaudotDecoder.  A ternary code table
//  (codeTable, 6561 = 3^8 entries) maps a dot/dash sequence to a character.
//  The dot/dash string is turned into a ternary index by decodeToCodeTableIndex
//  ('.' -> 1, anything else -> 2).  Extra characters can be defined at runtime
//  in ~/Library/Application Support/cocoaModem/Morse.txt.
//
//  Notes on the port:
//   * `codeTable` and `extension` were file-scope C statics; they are made
//     per-instance here (deterministic content, single decoder in practice).
//     `extension` is a Swift keyword, so the ivar is named `morseExtension`.
//   * The Morse.txt parse mirrors the original fscanf("%d %s")+fgets loop
//     (including its odd "accept if a non ',' / '-' char is present" test).
//

import Cocoa

//  use upper ASCII for Prosigns
private let AR: Int32   = 0x80
private let AS: Int32   = 0x81
private let SK: Int32   = 0x82
private let NR: Int32   = 0x83

//  mis keys
private let US: Int32   = 0xc0
private let AME: Int32  = 0xc1
private let NAME: Int32 = 0xc2
private let RST: Int32  = 0xc3
private let WA: Int32   = 0xc4
private let KN: Int32   = 0xc5

//  (code, dot/dash sequence) -- was "Code morse[]" in MorseDecoder.m
private let morse: [(Int32, String)] = [
    (0x41 /* 'A' */, ".-"),
    (0x42 /* 'B' */, "-..."),
    (0x43 /* 'C' */, "-.-."),
    (0x44 /* 'D' */, "-.."),
    (0x45 /* 'E' */, "."),
    (0x46 /* 'F' */, "..-."),
    (0x47 /* 'G' */, "--."),
    (0x48 /* 'H' */, "...."),
    (0x49 /* 'I' */, ".."),
    (0x4a /* 'J' */, ".---"),
    (0x4b /* 'K' */, "-.-"),
    (0x4c /* 'L' */, ".-.."),
    (0x4d /* 'M' */, "--"),
    (0x4e /* 'N' */, "-."),
    (0x4f /* 'O' */, "---"),
    (0x50 /* 'P' */, ".--."),
    (0x51 /* 'Q' */, "--.-"),
    (0x52 /* 'R' */, ".-."),
    (0x53 /* 'S' */, "..."),
    (0x54 /* 'T' */, "_"),
    (0x55 /* 'U' */, "..-"),
    (0x56 /* 'V' */, "...-"),
    (0x57 /* 'W' */, ".--"),
    (0x58 /* 'X' */, "-..-"),
    (0x59 /* 'Y' */, "-.--"),
    (0x5a /* 'Z' */, "--.."),
    (0x31 /* '1' */, ".----"),
    (0x32 /* '2' */, "..---"),
    (0x33 /* '3' */, "...--"),
    (0x34 /* '4' */, "....-"),
    (0x35 /* '5' */, "....."),
    (0x36 /* '6' */, "-...."),
    (0x37 /* '7' */, "--..."),
    (0x38 /* '8' */, "---.."),
    (0x39 /* '9' */, "----."),
    (0x30 /* '0' */, "-----"),
    (0x2e /* '.' */, ".-.-.-"),
    (0x2c /* ',' */, "--..--"),
    (0x3f /* '?' */, "..--.."),
    (0x2f /* '/' */, "-..-."),
    (0x3d /* '=' */, "-...-"),
    (0x40 /* '@' */, ".--.-."),
    (AR, ".-.-."),
    (AS, ".-..."),
    (SK, "...-.-"),
    //  possible miskeys
    (US, "..-..."),
    (AME, ".---."),
    (NAME, "-..---."),
    (RST, ".-....-"),
    (WA, ".--.-"),
    (KN, "-.--."),
    //  possible error corrections
    (0x2e /* '.' */, "-.-.-"),
    (0x33 /* '3' */, "..--"),
]

private func decodeToCodeTableIndex(_ string: UnsafePointer<CChar>) -> Int {
    var n = 0
    var p = string
    for _ in 0..<8 {
        if p.pointee == 0 { break }
        n = n * 3 + ((p.pointee == 0x2e /* '.' */) ? 1 : 2)
        p += 1
    }
    if n >= 6561 { n = 6560 }
    return n
}

@objc(MorseDecoder)
class MorseDecoder: CMBaudotDecoder {

    private var codeTable = [UInt8](repeating: 0, count: 6561)       //  8 ternary digits
    private var morseExtension = [Bool](repeating: false, count: 256)  //  chars extended by Morse.txt

    @objc(initWithDemodulator:)
    override init(demodulator demod: CMFSKDemodulator?) {
        super.init(demodulator: demod)

        for i in 0..<6561 { codeTable[i] = 0x2a /* '*' */ }
        for i in 0..<256 { morseExtension[i] = false }
        for entry in morse {
            let n = entry.1.withCString { decodeToCodeTableIndex($0) }
            codeTable[n] = UInt8(truncatingIfNeeded: entry.0)
        }

        //  0.53e -- set up output for Morse.txt
        let name = "~/Library/Application Support/cocoaModem/Morse.txt" as NSString
        let path = name.expandingTildeInPath
        loadMorseExtensions(path)
    }

    //  Faithful reproduction of the fscanf("%d %s") + fgets(skip line) loop.
    private func loadMorseExtensions(_ path: String) {
        guard let contents = try? String(contentsOfFile: path, encoding: .isoLatin1) else { return }
        //  fscanf("%d %s") skips whitespace (incl. newlines); the trailing fgets
        //  then discards the rest of the line.  With one record per line this is
        //  line-based parsing of "<index> <sequence> ...".
        let lines = contents.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for line in lines {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.count < 2 { break }                       //  fscanf would fail
            guard let index = Int32(tokens[0]) else { break }
            if index <= 0 { break }
            let string = String(tokens[1])
            let utf = Array(string.utf8)
            let n0 = utf.count                                  //  strlen(string)
            if index > 0 && index < 6560 && !utf.isEmpty && n0 < 8 {
                //  find first char that is not ',' and not '-' (original test)
                var i = 0
                while i < n0 {
                    if utf[i] != 0x2c /* ',' */ && utf[i] != 0x2d /* '-' */ { break }
                    i += 1
                }
                if i < n0 {
                    let n = string.withCString { decodeToCodeTableIndex($0) }
                    codeTable[n] = UInt8(truncatingIfNeeded: index)
                    morseExtension[Int(index)] = true
                }
            }
        }
    }

    @objc(newCharacter:length:wordSpacing:)
    func newCharacter(_ string: UnsafePointer<CChar>, length: Int32, wordSpacing spacing: Int32) {
        if length > 0 {
            let d = decodeToCodeTableIndex(string)
            let c = Int32(codeTable[d])
            if c < 0x80 {
                if c != 0x2a /* '*' */ { demodulator?.receivedCharacter(c) }
            } else {
                //  v0.53e -- extended by Morse.txt
                if c < 256 && morseExtension[Int(c)] {
                    demodulator?.receivedCharacter(c)
                } else {
                    let s: String
                    switch c {
                    case AR:   s = "<AR>"
                    case SK:   s = "<SK>"
                    case AS:   s = "<AS>"
                    case NR:   s = "<NR>"
                    //  possible miskeys
                    case US:   s = "US"
                    case AME:  s = "AME"
                    case NAME: s = "NAME"
                    case RST:  s = "RST"
                    case WA:   s = "WA"
                    case KN:   s = "KN"
                    default:   s = "<??>"
                    }
                    //  send up to 4 characters
                    var count = 0
                    for byte in s.utf8 {
                        if count >= 4 || byte == 0 { break }
                        demodulator?.receivedCharacter(Int32(byte))
                        count += 1
                    }
                }
            }
        }
        var i: Int32 = 0
        while i < spacing {
            demodulator?.receivedCharacter(0x20 /* ' ' */)
            i += 1
        }
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        // data comes in from a direct call
    }
}
