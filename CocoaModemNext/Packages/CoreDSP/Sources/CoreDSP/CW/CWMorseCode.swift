//
//  CWMorseCode.swift
//  CoreDSP
//
//  Morse code tables shared by CWModulator (ASCII -> dot/dash, ported from
//  CWModulator.initMorse) and CWMorseDecoder (dot/dash -> ASCII/prosign,
//  ported from MorseDecoder.m's ternary codeTable + decodeToCodeTableIndex).
//  The originals were sized for 16384-entry ASCII arrays plus a runtime
//  ~/Library/Application Support/cocoaModem/Morse.txt override file -- both
//  Mac-app config features, not DSP, and are dropped here (only the fixed
//  standard tables are transplanted).
//

import Foundation

//  ---- encode: ASCII -> dot/dash string (from CWModulator.initMorse) ----
enum CWMorseEncodeTable {
    static let table: [UInt8: String] = {
        var t: [UInt8: String] = [:]
        func set(_ c: Character, _ s: String) { t[c.asciiValue!] = s }

        set(" ", " ")   //  interword handled specially by the modulator, not looked up here
        set("a", ".-");   set("b", "-..."); set("c", "-.-.");  set("d", "-..")
        set("e", ".");    set("f", "..-."); set("g", "--.");   set("h", "....")
        set("i", "..");   set("j", ".---"); set("k", "-.-");   set("l", ".-..")
        set("m", "--");   set("n", "-.");   set("o", "---");   set("p", ".--.")
        set("q", "--.-"); set("r", ".-.");  set("s", "...");   set("t", "-")
        set("u", "..-");  set("v", "...-"); set("w", ".--");   set("x", "-..-")
        set("y", "-.--"); set("z", "--..")
        for lower in UInt8(ascii: "a")...UInt8(ascii: "z") {
            t[lower - UInt8(ascii: "a") + UInt8(ascii: "A")] = t[lower]
        }
        set("0", "-----"); set("1", ".----"); set("2", "..---"); set("3", "...--"); set("4", "....-")
        set("5", "....."); set("6", "-...."); set("7", "--..."); set("8", "---.."); set("9", "----.")

        set(".", ".-.-.-"); set(",", "--..--"); set("?", "..--..")
        t[0x22] = ".-..-."   //  "
        t[UInt8(ascii: "#")] = ".."; t[UInt8(ascii: "%")] = ".."
        t[UInt8(ascii: "&")] = ".."; t[UInt8(ascii: "*")] = ".."
        set("$", "...-..-")
        t[0x27] = ".----."    //  '
        set("(", "-.--.");  set(")", "-.--.-"); set("+", ".-.-.");  set("-", "-....-"); set("/", "-..-.")
        set(":", "-.--.");  set(";", ".-.-");   set("<", ".-.-.");  set("=", "-...-");  set(">", "...-.-")
        set("@", ".--.-.")
        return t
    }()
}

//  ---- decode: dot/dash string -> ASCII/prosign code (from MorseDecoder.m) ----

//  upper-ASCII prosign / miskey codes (kept exactly as the original constants)
enum CWProsign {
    static let AR: Int32 = 0x80, AS: Int32 = 0x81, SK: Int32 = 0x82, NR: Int32 = 0x83
    static let US: Int32 = 0xc0, AME: Int32 = 0xc1, NAME: Int32 = 0xc2
    static let RST: Int32 = 0xc3, WA: Int32 = 0xc4, KN: Int32 = 0xc5
}

//  (code, dot/dash sequence) -- was "Code morse[]" in MorseDecoder.m
private let cwMorseDecodeEntries: [(Int32, String)] = [
    (0x41, ".-"), (0x42, "-..."), (0x43, "-.-."), (0x44, "-.."), (0x45, "."),
    (0x46, "..-."), (0x47, "--."), (0x48, "...."), (0x49, ".."), (0x4a, ".---"),
    (0x4b, "-.-"), (0x4c, ".-.."), (0x4d, "--"), (0x4e, "-."), (0x4f, "---"),
    (0x50, ".--."), (0x51, "--.-"), (0x52, ".-."), (0x53, "..."), (0x54, "-"),
    (0x55, "..-"), (0x56, "...-"), (0x57, ".--"), (0x58, "-..-"), (0x59, "-.--"),
    (0x5a, "--.."),
    (0x31, ".----"), (0x32, "..---"), (0x33, "...--"), (0x34, "....-"), (0x35, "....."),
    (0x36, "-...."), (0x37, "--..."), (0x38, "---.."), (0x39, "----."), (0x30, "-----"),
    (0x2e, ".-.-.-"), (0x2c, "--..--"), (0x3f, "..--.."), (0x2f, "-..-."), (0x3d, "-...-"),
    (0x40, ".--.-."),
    (CWProsign.AR, ".-.-."), (CWProsign.AS, ".-..."), (CWProsign.SK, "...-.-"),
    //  possible miskeys
    (CWProsign.US, "..-..."), (CWProsign.AME, ".---."), (CWProsign.NAME, "-..---."),
    (CWProsign.RST, ".-....-"), (CWProsign.WA, ".--.-"), (CWProsign.KN, "-.--."),
    //  possible error corrections
    (0x2e, "-.-.-"), (0x33, "..--"),
]

//  ternary index: '.' -> 1, anything else (incl '-') -> 2, up to 8 symbols
func cwDecodeToCodeTableIndex(_ sequence: some StringProtocol) -> Int {
    var n = 0
    for (count, ch) in sequence.utf8.enumerated() {
        if count >= 8 { break }
        n = n * 3 + (ch == UInt8(ascii: ".") ? 1 : 2)
    }
    if n >= 6561 { n = 6560 }
    return n
}

enum CWMorseDecodeTable {
    //  8 ternary digits -> ASCII/prosign byte ('*' = unrecognized, matches the original)
    static let table: [UInt8] = {
        var t = [UInt8](repeating: 0x2a, count: 6561)
        for (code, sequence) in cwMorseDecodeEntries {
            t[cwDecodeToCodeTableIndex(sequence)] = UInt8(truncatingIfNeeded: code)
        }
        return t
    }()
}
