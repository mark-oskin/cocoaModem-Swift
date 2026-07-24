//
//  DisplayColor.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 3/1/06.
//  Swift port of DisplayColor.m.
//

import Foundation

@objc(DisplayColor)
class DisplayColor: NSObject {

    //  get actual bitmap values from r, g, b values with endian swapping
    //  inputs are in the range of 0 (black) to 1.0 (saturated)
    //  output is either 32 bit values (millions) or 16 bit values (thousands)
    //
    //  The original used a __BIG_ENDIAN__ compile-time switch (PPC).  All
    //  currently supported Macs are little-endian, so only that branch remains.

    //  C truncates a float to (signed) int toward zero and lets the result
    //  wrap when assigned to the UInt32 bitmap word.  Inputs here can fall
    //  slightly outside 0...1 (the caller's colour interpolation is not clamped
    //  below zero), so we must not trap the way Swift's checked conversions and
    //  arithmetic operators do — mirror C with a guarded truncation and the
    //  wrapping (&) operators.
    @inline(__always)
    private static func cInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int32.max }
        if t <= -2147483648.0 { return Int32.min }
        return Int32(t)
    }

    @objc(millionsOfColorsFromRed:green:blue:)
    class func millionsOfColors(fromRed r: Float, green g: Float, blue b: Float) -> UInt32 {
        let rr = cInt(r * 255.5)
        let gg = cInt(g * 255.5)
        let bb = cInt(b * 255.5)
        let result = rr &+ (gg &<< 8) &+ (bb &<< 16) &+ Int32(bitPattern: 0xff000000)
        return UInt32(bitPattern: result)
    }

    @objc(thousandsOfColorsFromRed:green:blue:)
    class func thousandsOfColors(fromRed r: Float, green g: Float, blue b: Float) -> UInt32 {
        let rr = cInt(r * 15.5)
        let gg = cInt(g * 15.5)
        let bb = cInt(b * 15.5)
        let result = (rr &<< 4) &+ gg &+ (bb &<< 12) &+ 0xf00
        return UInt32(bitPattern: result)
    }
}
