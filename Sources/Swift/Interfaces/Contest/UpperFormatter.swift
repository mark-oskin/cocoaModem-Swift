//
//  UpperFormatter.swift
//  Contest
//
//  Created by Kok Chen on Wed Dec 11 2002.
//  Swift port of UpperFormatter.m.
//
//  Uppercase formatter for NSTextField.
//  control-drag formatter of NSTextField's to instance of this class in Interface
//  Builder, or use setFormatter: for NSTextField.
//

import Cocoa

@objc(UpperFormatter)
class UpperFormatter: Formatter {

    //  Phi/phi come from cocoaModemParams.h; kTextEncoding is NSISOLatin1StringEncoding.
    private static let phi: Int32 = 0xf8
    private static let Phi: Int32 = 0xd8

    //  Faithful port of the C getUppercase(): folds a..z to A..Z and turns a
    //  phi/Phi byte into a NUL (which truncates the reconstructed string).  The
    //  original walks signed `char` bytes, so a high-bit byte promotes negative
    //  and never equals phi/Phi — that quirk is preserved by comparing Int32 of
    //  the signed CChar.
    private func getUppercase(_ string: [CChar]) -> [CChar] {
        var result = [CChar]()
        result.reserveCapacity(string.count)
        for c in string {
            if c == 0 { break }             //  while ( *string )
            var v = Int32(c)
            if v == UpperFormatter.phi || v == UpperFormatter.Phi { v = 0 }
            if v >= Int32(UInt8(ascii: "a")) && v <= Int32(UInt8(ascii: "z")) {
                v += Int32(UInt8(ascii: "A")) - Int32(UInt8(ascii: "a"))
            }
            result.append(CChar(truncatingIfNeeded: v))
        }
        result.append(0)                    //  *result = 0
        return result
    }

    //  substitute with upper cased characters, range positions remain the same
    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
                                       proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
                                       originalString origString: String,
                                       originalSelectedRange origSelRange: NSRange,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let partial = partialStringPtr.pointee as String
        guard let s = partial.cString(using: .isoLatin1), (s.count - 1) <= 60 else {
            //  invalid string for this formatter
            return super.isPartialStringValid(partialStringPtr,
                                              proposedSelectedRange: proposedSelRangePtr,
                                              originalString: origString,
                                              originalSelectedRange: origSelRange,
                                              errorDescription: error)
        }
        let u = getUppercase(s)
        if let upper = u.withUnsafeBufferPointer({ buf -> NSString? in
            guard let base = buf.baseAddress else { return nil }
            return NSString(cString: base, encoding: String.Encoding.isoLatin1.rawValue)
        }) {
            partialStringPtr.pointee = upper
        }
        return false
    }

    //  return current string as is in objectValue
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = NSString(string: string)
        return true
    }

    //  return the string that is obtained from -getObjectValue.
    //  this is the final string that is accepted by NSTextField
    override func string(for obj: Any?) -> String? {
        return obj as? String
    }
}
