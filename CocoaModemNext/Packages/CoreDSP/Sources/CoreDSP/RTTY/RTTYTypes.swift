//
//  RTTYTypes.swift
//  CoreDSP
//
//  Plain-Swift-struct replacements for the C structs that only ever existed
//  via bridging-header .h files in the old app (CoreModemTypes.h, CMBaudot.h,
//  CMATCTypes.h). None of these carry DSP algorithm logic themselves -- they
//  are just data layout -- so they are transcribed as straightforward Swift
//  value types rather than the raw-pointer / struct-field-aliasing tricks the
//  original Objective-C/C bridging relied on. The tables (CMLtrs / CMFigs) and
//  the bit-pattern constants ARE DSP-relevant (the standard 5-bit Baudot/ITA2
//  code) and are transcribed verbatim.
//

import Foundation

//  ---- CoreModemTypes.h ----

/// Mark/space tone pair + baud rate (was `typedef struct { double mark, space, baud; } CMTonePair`).
struct CMTonePair {
    var mark: Double
    var space: Double
    var baud: Double
}

/// A single local-oscillator DDA (digital delta accumulator) state (was
/// `typedef struct { float freq; double deltaTheta, cost, sint, theta; } CMDDA`).
/// NOTE: `freq` is `float` in the original, all other fields `double` -- kept
/// exactly, this is not an oversight.
struct CMDDA {
    var freq: Float = 0
    var deltaTheta: Double = 0
    var cost: Double = 0
    var sint: Double = 0
    var theta: Double = 0
}

//  ---- CMATCTypes.h ----

/// One mark/space amplitude sample pair (was `typedef struct { float mark, space; } CMATCPair`).
struct CMATCPair {
    var mark: Float = 0
    var space: Float = 0
}

/// One of the 6 "equalizer case" bit accumulators tried per candidate character
/// start (was `typedef struct { int startingIndex, endingIndex, eq, bits[8], weight, decoded; } CMATCCase`).
struct CMATCCase {
    var startingIndex: Int32 = 0
    var endingIndex: Int32 = 0
    var eq: Int32 = 0
    var bits: [Int32] = [Int32](repeating: 0, count: 8)
    var weight: Int32 = 0
    var decoded: Int32 = 0

    init(startingIndex: Int32 = 0, endingIndex: Int32 = 0, eq: Int32 = 0) {
        self.startingIndex = startingIndex
        self.endingIndex = endingIndex
        self.eq = eq
    }
}

//  ---- CMBaudot.h ----
//  Standard 5-bit Baudot/ITA2 code tables (LTRS and FIGS shift states).
//  Transcribed verbatim -- this is standardized teleprinter code, not
//  something to "clean up".

let CMFIGSCODE: Int32 = 0x1b
let CMLTRSCODE: Int32 = 0x1f

func rttyChar(_ c: Unicode.Scalar) -> Int32 { Int32(c.value) }

let CMLtrs: [Int32] = [
    rttyChar("*"), rttyChar("E"), 0x0a, rttyChar("A"), rttyChar(" "), rttyChar("S"), rttyChar("I"), rttyChar("U"),
    0x0d, rttyChar("D"), rttyChar("R"), rttyChar("J"), rttyChar("N"), rttyChar("F"), rttyChar("C"), rttyChar("K"),
    rttyChar("T"), rttyChar("Z"), rttyChar("L"), rttyChar("W"), rttyChar("H"), rttyChar("Y"), rttyChar("P"), rttyChar("Q"),
    rttyChar("O"), rttyChar("B"), rttyChar("G"), rttyChar("*"), rttyChar("M"), rttyChar("X"), rttyChar("V"), rttyChar("*")
]

let CMFigs: [Int32] = [
    rttyChar("*"), rttyChar("3"), 0x0a, rttyChar("-"), rttyChar(" "), rttyChar("*"), rttyChar("8"), rttyChar("7"),
    0x0d, rttyChar("$"), rttyChar("4"), rttyChar("'"), rttyChar(","), rttyChar("!"), rttyChar(":"), rttyChar("("),
    rttyChar("5"), rttyChar("\""), rttyChar(")"), rttyChar("2"), rttyChar("#"), rttyChar("6"), rttyChar("0"), rttyChar("1"),
    rttyChar("9"), rttyChar("?"), rttyChar("&"), rttyChar("*"), rttyChar("."), rttyChar("/"), rttyChar(";"), rttyChar("*")
]

//  ---- CMFSKModulator.h shared #defines ----

let CMLTRSHIFT: Int32 = 0x20
let CMFIGSHIFT: Int32 = 0x40
let CMSTREAMMASK: Int32 = 0xffff

let FIGSTATE: Bool = true
let LTRSTATE: Bool = false

/// Output bit-stream ring element (was `CMBinaryStream` in CMFSKModulator.h).
struct CMBinaryStream {
    var polarity: Int32 = 0     //  0 == mark, 1 == space
    var dda: Double = 0
    var character: Int32 = 0    //  either 0 or an ASCII character
    var code: Int32 = 0         //  0 or the original code (e.g. Baudot)
}
