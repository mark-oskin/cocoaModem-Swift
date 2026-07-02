//
//  StripPhi.swift
//  cocoaModem
//
//  Created by Kok Chen on 12/5/04.
//
//  Swift port of StripPhi.m.  Base class that normalizes strings that may
//  contain the "slashed zero" glyph (phi / Phi) back into ordinary ASCII.
//  QSO (Swift) and the Contest tree (Swift) subclass this.
//

import Cocoa

//  kTextEncoding == NSISOLatin1StringEncoding (see TextEncoding.h)
private let kTextEncoding = String.Encoding.isoLatin1.rawValue

@objc(StripPhi)
class StripPhi: NSObject {

    //  replace string with one that is normal ascii.
    //  (the original scanned for a byte > 127 and, if found, replaced every
    //   phi/Phi byte with '0'.)
    @objc(asciiString:)
    func asciiString(_ input: String) -> String {
        let ns = input as NSString
        guard let c = ns.cString(using: kTextEncoding) else { return input }
        var p = c
        var hasPhi = false
        while p.pointee != 0 {
            if Int(UInt8(bitPattern: p.pointee)) > 127 { hasPhi = true; break }
            p += 1
        }
        if !hasPhi { return input }
        return StripPhi.stripped(c) ?? input
    }

    //  client must release the string (ARC handles that in Swift)
    @objc(asciiCString:)
    func asciiCString(_ input: UnsafeMutablePointer<CChar>!) -> String {
        guard let input = input else { return "" }
        var p = input
        var hasPhi = false
        while p.pointee != 0 {
            if Int(UInt8(bitPattern: p.pointee)) > 127 { hasPhi = true; break }
            p += 1
        }
        if !hasPhi {
            return NSString(cString: input, encoding: kTextEncoding) as String? ?? ""
        }
        return StripPhi.stripped(input) ?? ""
    }

    //  copy the C string, replacing phi/Phi with '0'
    private static func stripped(_ input: UnsafePointer<CChar>) -> String? {
        var out = [CChar]()
        var q = input
        let zero = CChar(bitPattern: UInt8(ascii: "0"))
        while q.pointee != 0 {
            let t = Int(UInt8(bitPattern: q.pointee))
            out.append((t == Int(phi) || t == Int(Phi)) ? zero : q.pointee)
            q += 1
        }
        out.append(0)
        return NSString(cString: out, encoding: kTextEncoding) as String?
    }
}
