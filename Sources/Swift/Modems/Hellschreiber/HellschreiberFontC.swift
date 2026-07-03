//
//  HellschreiberFontC.swift
//  cocoaModem 2.0
//
//  Swift port of HellschreiberFont.c (+ HellschreiberFont.h)
//  Created by Kok Chen on 1/29/06 (Obj-C); ported to Swift.
//

import Foundation

//  ---------------------------------------------------------------------------
//  Ported from HellschreiberFont.h
//
//  The struct layout MUST match the original C struct byte-for-byte because
//  HellModulator.swift reads the `index[]` table via a hard-coded byte offset
//  (kFontIndexOffset == 36) into the raw struct memory:
//
//      short version ;   // offset 0
//      short size ;      // offset 2
//      char  name[32] ;  // offset 4
//      short index[128]; // offset 36
//      unsigned char *fontData ;
//
//  Homogeneous Swift tuples are laid out contiguously with the same alignment
//  as C arrays, so `name` (32 × CChar) and `index` (128 × Int16) reproduce the
//  original layout, keeping `index` at byte offset 36.
//  ---------------------------------------------------------------------------

struct HellschreiberFontHeader {
    var version: Int16
    var size: Int16
    var name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
    var index: (Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16)
    var fontData: UnsafeMutablePointer<UInt8>!
}

//  Version flags
let STEMALIGNED = 0x8000

//  ---------------------------------------------------------------------------
//  Ported from HellschreiberFont.c
//
//  HellschreiberFontHeader* MakeHellFont( const char *filename )
//
//  Swift-imported signature preserved:
//     MakeHellFont(_ filename: UnsafePointer<CChar>!) -> UnsafeMutablePointer<HellschreiberFontHeader>!
//  ---------------------------------------------------------------------------

func MakeHellFont(_ filename: UnsafePointer<CChar>!) -> UnsafeMutablePointer<HellschreiberFontHeader>! {

    guard let f = fopen(filename, "rb") else { return nil }

    let header = UnsafeMutablePointer<HellschreiberFontHeader>.allocate(capacity: 1)

    fread(header, MemoryLayout<HellschreiberFontHeader>.size, 1, f)

    //  ntohs (big-endian on disk -> host order)
    header.pointee.version = Int16(bitPattern: UInt16(bigEndian: UInt16(bitPattern: header.pointee.version)))
    header.pointee.size = Int16(bitPattern: UInt16(bigEndian: UInt16(bitPattern: header.pointee.size)))
    withUnsafeMutablePointer(to: &header.pointee.index) { tuplePtr in
        tuplePtr.withMemoryRebound(to: Int16.self, capacity: 128) { ip in
            for i in 0..<128 {
                ip[i] = Int16(bitPattern: UInt16(bigEndian: UInt16(bitPattern: ip[i])))
            }
        }
    }

    let size = Int(header.pointee.size)
    let fontData = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    fread(fontData, 1, size, f)
    fclose(f)

    header.pointee.fontData = fontData
    return header
}
