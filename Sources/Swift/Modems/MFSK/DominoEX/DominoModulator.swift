//
//  DominoModulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 7/16/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of DominoModulator.m.
//
//  DominoEX modulator.  Subclass of MFSKModulator.  Differential IFK+ tone
//  encoding of nibble Varicode (primary channel) plus a secondary/beacon
//  channel.  Optionally uses the FEC path inherited from MFSKModulator.
//
//  The packed Varicode tables (ASCIITOPRIVAR / ASCIITOSECVAR) and the primary /
//  secondary FEC-encode tables were static data in the original; they are
//  inlined here as Swift constants.  The unpacked nibble strings and the beacon
//  buffers are kept in malloc'd C storage (freed in deinit) so their char*
//  pointers stay stable, exactly as the C code required.
//

import Cocoa

private let NOTTERMINATING: Int32 = 0
private let TERMINATESTARTED: Int32 = 1
private let TERMINATETAIL: Int32 = 2
private let TERMINATED: Int32 = 5

private let nibbleValue: [Int32] = [
    Int32(UInt8(ascii: "0")), Int32(UInt8(ascii: "1")), Int32(UInt8(ascii: "2")), Int32(UInt8(ascii: "3")),
    Int32(UInt8(ascii: "4")), Int32(UInt8(ascii: "5")), Int32(UInt8(ascii: "6")), Int32(UInt8(ascii: "7")),
    Int32(UInt8(ascii: "8")), Int32(UInt8(ascii: "9")), Int32(UInt8(ascii: "a")), Int32(UInt8(ascii: "b")),
    Int32(UInt8(ascii: "c")), Int32(UInt8(ascii: "d")), Int32(UInt8(ascii: "e")), Int32(UInt8(ascii: "f"))
]

//  asciiToNibble: '0'..'9' -> 0..9, 'a'..'f' -> 10..15, everything else 0
private let asciiToNibble: [Int32] = {
    var t = [Int32](repeating: 0, count: 256)
    for i in 0...9 { t[Int(UInt8(ascii: "0")) + i] = Int32(i) }
    for i in 0...5 { t[Int(UInt8(ascii: "a")) + i] = Int32(10 + i) }
    return t
}()

private let primaryFECEncodeTable: [Int32] = [
    /*0*/   0,  95, 95, 95, 95, 95, 95, 95,  8, 95,
    /*1*/   13, 95, 95, 13, 95, 95, 95, 95, 95, 95,
    /*2*/   95, 95, 95, 95, 95, 95, 95, 95, 95, 95,
    /*3*/   95, 95, 32, 33, 34, 35, 36, 37, 38, 39,
    /*4*/   40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
    /*5*/   50, 51, 52, 53, 54, 55, 56, 57, 58, 59,
    /*6*/   60, 61, 62, 63, 64, 65, 66, 67, 68, 69,
    /*7*/   70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
    /*8*/   80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
    /*9*/   90, 91, 92, 93, 94, 95, 96, 97, 98, 99,
    /*10*/  100, 101, 102, 103, 104, 105, 106, 107, 108, 109,
    /*11*/  110, 111, 112, 113, 114, 115, 116, 117, 118, 119,
    /*12*/  120, 121, 122, 123, 124, 125, 126, 95, 95, 95,
    /*13*/  95, 95, 95, 95, 95, 95, 95, 95, 95, 95,
    /*14*/  95, 95, 95, 95, 95, 95, 95, 95, 95, 95,
    /*15*/  95, 95, 95, 95, 95, 95, 95, 95, 95, 95,
    /*16*/  160, 161, 162, 163, 164, 165, 166, 167, 168, 169,
    /*17*/  170, 171, 172, 173, 174, 175, 176, 177, 178, 179,
    /*18*/  180, 181, 182, 183, 184, 185, 186, 187, 188, 189,
    /*19*/  190, 191, 192, 193, 194, 195, 196, 197, 198, 199,
    /*20*/  200, 201, 202, 203, 204, 205, 206, 207, 208, 209,
    /*21*/  210, 211, 212, 213, 214, 215, 216, 217, 218, 219,
    /*22*/  220, 221, 222, 223, 224, 225, 226, 227, 228, 229,
    /*23*/  230, 231, 232, 233, 234, 235, 236, 237, 238, 239,
    /*24*/  240, 241, 242, 243, 244, 245, 246, 247, 248, 249,
    /*25*/  250, 251, 252, 253, 254, 255, 95, 95, 95, 95
]

private let secondaryFECEncodeTable: [Int32] = [
    /*0*/   0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    /*1*/   0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    /*2*/   0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    /*3*/   0, 0, 1, 2, 3, 0, 5, 6, 7, 9,
    /*4*/   10, 11, 12, 24, 25, 26, 27, 28, 14, 15,
    /*5*/   16, 17, 18, 19, 20, 21, 22, 23, 29, 30,
    /*6*/   31, 153, 154, 155, 156, 127, 128, 129, 130, 131,
    /*7*/   132, 133, 134, 135, 136, 137, 138, 139, 140, 141,
    /*8*/   142, 143, 144, 145, 146, 147, 148, 149, 150, 151,
    /*9*/   152, 157, 158, 159, 0, 4, 0, 127, 128, 129,
    /*10*/  130, 131, 132, 133, 134, 135, 136, 137, 138, 139,
    /*11*/  140, 141, 142, 143, 144, 145, 146, 147, 148, 149,
    /*12*/  150, 151, 152, 10, 158, 11, 0, 0, 0, 0,
    /*13*/  0, 132, 0, 0, 0, 0, 0, 0, 0, 0,
    /*14*/  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    /*15*/  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    /*16*/  0, 0, 0, 138, 0, 0, 0, 0, 0, 129,
    /*17*/  127, 31, 0, 0, 144, 0, 0, 0, 16, 17,
    /*18*/  0, 15, 0, 0, 0, 0, 130, 154, 0, 0,
    /*19*/  0, 155, 127, 127, 127, 127, 127, 127, 131, 129,
    /*20*/  131, 131, 131, 131, 135, 135, 135, 135, 130, 140,
    /*21*/  141, 141, 141, 141, 141, 150, 14, 147, 147, 147,
    /*22*/  147, 151, 0, 128, 127, 127, 127, 127, 127, 127,
    /*23*/  131, 129, 131, 131, 131, 131, 135, 135, 135, 135,
    /*24*/  0, 140, 141, 141, 141, 141, 141, 0, 0, 147,
    /*25*/  147, 147, 147, 151, 0, 151, 0, 0, 0, 0
]

//  ascii to privar
private let ASCIITOPRIVAR: [UInt16] = [
    0x1f9, 0x1fa, 0x1fb, 0x1fc, 0x1fd, 0x1fe, 0x1ff, 0x288, 0x2c, 0x289,
    0x28a, 0x28b, 0x28c, 0x2d, 0x28d, 0x28e, 0x28f, 0x298, 0x299, 0x29a,
    0x29b, 0x29c, 0x29d, 0x29e, 0x29f, 0x2a8, 0x2a9, 0x2aa, 0x2ab, 0x2ac,
    0x2ad, 0x2ae, 0x0, 0x7b, 0x08e, 0x0ab, 0x09a, 0x099, 0x08f, 0x7a,
    0x08c, 0x08b, 0x09d, 0x088, 0x2b, 0x7e, 0x7d, 0x089, 0x3f, 0x4a,
    0x4f, 0x59, 0x68, 0x5c, 0x5e, 0x6c, 0x6b, 0x6e, 0x08a, 0x08d,
    0x0a8, 0x7f, 0x09f, 0x7c, 0x098, 0x39, 0x4e, 0x3c, 0x3e, 0x38,
    0x4c, 0x58, 0x5a, 0x3a, 0x78, 0x6a, 0x4b, 0x48, 0x4d, 0x3b,
    0x49, 0x6f, 0x3d, 0x2f, 0x2e, 0x5b, 0x6d, 0x5d, 0x5f, 0x69,
    0x79, 0x0ae, 0x0a9, 0x0af, 0x0aa, 0x09c, 0x09b, 0x4, 0x1b, 0x0c,
    0x0b, 0x1, 0x0f, 0x19, 0x0a, 0x5, 0x2a, 0x1e, 0x09, 0x0e,
    0x6, 0x3, 0x18, 0x28, 0x7, 0x08, 0x2, 0x0d, 0x1d, 0x1c,
    0x1f, 0x1a, 0x29, 0x0ac, 0x09e, 0x0ad, 0x0b8, 0x2af, 0x2b8, 0x2b9,
    0x2ba, 0x2bb, 0x2bc, 0x2bd, 0x2be, 0x2bf, 0x2c8, 0x2c9, 0x2ca, 0x2cb,
    0x2cc, 0x2cd, 0x2ce, 0x2cf, 0x2d8, 0x2d9, 0x2da, 0x2db, 0x2dc, 0x2dd,
    0x2de, 0x2df, 0x2e8, 0x2e9, 0x2ea, 0x2eb, 0x2ec, 0x2ed, 0x2ee, 0x2ef,
    0x0b9, 0x0ba, 0x0bb, 0x0bc, 0x0bd, 0x0be, 0x0bf, 0x0c8, 0x0c9, 0x0ca,
    0x0cb, 0x0cc, 0x0cd, 0x0ce, 0x0cf, 0x0d8, 0x0d9, 0x0da, 0x0db, 0x0dc,
    0x0dd, 0x0de, 0x0df, 0x0e8, 0x0e9, 0x0ea, 0x0eb, 0x0ec, 0x0ed, 0x0ee,
    0x0ef, 0x0f8, 0x0f9, 0x0fa, 0x0fb, 0x0fc, 0x0fd, 0x0fe, 0x0ff, 0x188,
    0x189, 0x18a, 0x18b, 0x18c, 0x18d, 0x18e, 0x18f, 0x198, 0x199, 0x19a,
    0x19b, 0x19c, 0x19d, 0x19e, 0x19f, 0x1a8, 0x1a9, 0x1aa, 0x1ab, 0x1ac,
    0x1ad, 0x1ae, 0x1af, 0x1b8, 0x1b9, 0x1ba, 0x1bb, 0x1bc, 0x1bd, 0x1be,
    0x1bf, 0x1c8, 0x1c9, 0x1ca, 0x1cb, 0x1cc, 0x1cd, 0x1ce, 0x1cf, 0x1d8,
    0x1d9, 0x1da, 0x1db, 0x1dc, 0x1dd, 0x1de, 0x1df, 0x1e8, 0x1e9, 0x1ea,
    0x1eb, 0x1ec, 0x1ed, 0x1ee, 0x1ef, 0x1f8
]

//  ascii to secvar
private let ASCIITOSECVAR: [UInt16] = [
    0x6f9, 0x6fa, 0x6fb, 0x6fc, 0x6fd, 0x6fe, 0x6ff, 0x788, 0x4ac, 0x789,
    0x78a, 0x78b, 0x78c, 0x4ad, 0x78d, 0x78e, 0x78f, 0x798, 0x799, 0x79a,
    0x79b, 0x79c, 0x79d, 0x79e, 0x79f, 0x7a8, 0x7a9, 0x7aa, 0x7ab, 0x7ac,
    0x7ad, 0x7ae, 0x388, 0x4fb, 0x58e, 0x5ab, 0x59a, 0x599, 0x58f, 0x4fa,
    0x58c, 0x58b, 0x59d, 0x588, 0x4ab, 0x4fe, 0x4fd, 0x589, 0x4bf, 0x4ca,
    0x4cf, 0x4d9, 0x4e8, 0x4dc, 0x4de, 0x4ec, 0x4eb, 0x4ee, 0x58a, 0x58d,
    0x5a8, 0x4ff, 0x59f, 0x4fc, 0x598, 0x4b9, 0x4ce, 0x4bc, 0x4be, 0x4b8,
    0x4cc, 0x4d8, 0x4da, 0x4ba, 0x4f8, 0x4ea, 0x4cb, 0x4c8, 0x4cd, 0x4bb,
    0x4c9, 0x4ef, 0x4bd, 0x4af, 0x4ae, 0x4db, 0x4ed, 0x4dd, 0x4df, 0x4e9,
    0x4f9, 0x5ae, 0x5a9, 0x5af, 0x5aa, 0x59c, 0x59b, 0x38c, 0x49b, 0x48c,
    0x48b, 0x389, 0x48f, 0x499, 0x48a, 0x38d, 0x4aa, 0x49e, 0x489, 0x48e,
    0x38e, 0x38b, 0x498, 0x4a8, 0x38f, 0x488, 0x38a, 0x48d, 0x49d, 0x49c,
    0x49f, 0x49a, 0x4a9, 0x5ac, 0x59e, 0x5ad, 0x5b8, 0x7af, 0x7b8, 0x7b9,
    0x7ba, 0x7bb, 0x7bc, 0x7bd, 0x7be, 0x7bf, 0x7c8, 0x7c9, 0x7ca, 0x7cb,
    0x7cc, 0x7cd, 0x7ce, 0x7cf, 0x7d8, 0x7d9, 0x7da, 0x7db, 0x7dc, 0x7dd,
    0x7de, 0x7df, 0x7e8, 0x7e9, 0x7ea, 0x7eb, 0x7ec, 0x7ed, 0x7ee, 0x7ef,
    0x5b9, 0x5ba, 0x5bb, 0x5bc, 0x5bd, 0x5be, 0x5bf, 0x5c8, 0x5c9, 0x5ca,
    0x5cb, 0x5cc, 0x5cd, 0x5ce, 0x5cf, 0x5d8, 0x5d9, 0x5da, 0x5db, 0x5dc,
    0x5dd, 0x5de, 0x5df, 0x5e8, 0x5e9, 0x5ea, 0x5eb, 0x5ec, 0x5ed, 0x5ee,
    0x5ef, 0x5f8, 0x5f9, 0x5fa, 0x5fb, 0x5fc, 0x5fd, 0x5fe, 0x5ff, 0x688,
    0x689, 0x68a, 0x68b, 0x68c, 0x68d, 0x68e, 0x68f, 0x698, 0x699, 0x69a,
    0x69b, 0x69c, 0x69d, 0x69e, 0x69f, 0x6a8, 0x6a9, 0x6aa, 0x6ab, 0x6ac,
    0x6ad, 0x6ae, 0x6af, 0x6b8, 0x6b9, 0x6ba, 0x6bb, 0x6bc, 0x6bd, 0x6be,
    0x6bf, 0x6c8, 0x6c9, 0x6ca, 0x6cb, 0x6cc, 0x6cd, 0x6ce, 0x6cf, 0x6d8,
    0x6d9, 0x6da, 0x6db, 0x6dc, 0x6dd, 0x6de, 0x6df, 0x6e8, 0x6e9, 0x6ea,
    0x6eb, 0x6ec, 0x6ed, 0x6ee, 0x6ef, 0x6f8
]

@objc(DominoModulator)
class DominoModulator: MFSKModulator {

    //  CodeString = unsigned char[4]; 256 of them, contiguous
    private let primaryVaricode = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 * 4)
    private let secondaryVaricode = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 * 4)
    private let beaconString = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
    private let defaultBeaconString = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
    private var defaultString: String = ""
    private var beaconPtr: UnsafeMutablePointer<CChar>?
    private var deltaTone: Int32 = 0
    private var lastTone: Int32 = 0
    private var binWidth: Float = 0     //  15.625 for DominoEX 16 and DominoEX 8
    private var baudRatio: Int32 = 0    //  2 for DominoEX 4/5/8, 1 for full rate modes

    //  unpack Varicode into string of nibbleValues
    private func unpack(_ codeString: UnsafeMutablePointer<UInt8>, from packedVaricode: [UInt16]) {
        for i in 0..<256 {
            let s = codeString.advanced(by: i * 4)
            for j in 0..<4 { s[j] = 0 }     //  first zero out unpacked code
            var packed = Int32(packedVaricode[i])
            if packed == 0 { s[0] = UInt8(truncatingIfNeeded: nibbleValue[0]) }
            else {
                if (packed & 0xff0) == 0 {
                    let n = packed & 0xf
                    if packed < 8 { s[0] = UInt8(truncatingIfNeeded: nibbleValue[Int(n)]) }
                    else {
                        s[0] = UInt8(truncatingIfNeeded: nibbleValue[0])
                        s[1] = UInt8(truncatingIfNeeded: nibbleValue[Int(n)])
                    }
                } else if (packed & 0xf00) == 0 {
                    let n = (packed / 16) & 0xf
                    if n < 8 {
                        s[1] = UInt8(truncatingIfNeeded: nibbleValue[Int(packed & 0xf)])
                        packed /= 16
                        s[0] = UInt8(truncatingIfNeeded: nibbleValue[Int(packed & 0xf)])
                    } else {
                        s[2] = UInt8(truncatingIfNeeded: nibbleValue[Int(packed & 0xf)])
                        packed /= 16
                        s[1] = UInt8(truncatingIfNeeded: nibbleValue[Int(packed & 0xf)])
                        s[0] = UInt8(truncatingIfNeeded: nibbleValue[0])
                    }
                } else {
                    s[2] = UInt8(truncatingIfNeeded: nibbleValue[Int(packed & 0xf)])
                    packed /= 16
                    s[1] = UInt8(truncatingIfNeeded: nibbleValue[Int(packed & 0xf)])
                    packed /= 16
                    s[0] = UInt8(truncatingIfNeeded: nibbleValue[Int(packed & 0xf)])
                }
            }
        }
    }

    override init() {
        beaconString.initialize(repeating: 0, count: 2048)
        defaultBeaconString.initialize(repeating: 0, count: 64)
        super.init()
        binWidth = 15.625
        baudDDA = Double(binWidth) * kPeriod / kCMFs
        useFEC = false                          //  default to no FEC
        interleaverStages = 4                   //  default FEC to 4 stage interleaver

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        defaultString = " cocoaModem 2.0 v\(version) .."
        //  strcpy( defaultBeaconString, defaultString )  (bounded to 64)
        let dbytes = Array(defaultString.utf8CString)
        let dn = min(dbytes.count, 64)
        for i in 0..<dn { defaultBeaconString[i] = dbytes[i] }
        if dn > 0 && defaultBeaconString[dn - 1] != 0 { defaultBeaconString[63] = 0 }
        beaconString[0] = 0                     //  strcpy( beaconString, "" )
        beaconPtr = defaultBeaconString
        unpack(primaryVaricode, from: ASCIITOPRIVAR)
        unpack(secondaryVaricode, from: ASCIITOSECVAR)
    }

    deinit {
        primaryVaricode.deallocate()
        secondaryVaricode.deallocate()
        beaconString.deallocate()
        defaultBeaconString.deallocate()
    }

    @objc(setUseFEC:)
    override func setUseFEC(_ state: Bool) {
        useFEC = state
    }

    @objc(resetModulator)
    override func resetModulator() {
        super.resetModulator()
        deltaTone = 0
        lastTone = 0
        beaconPtr = beaconString
    }

    @objc(flushOutput)
    override func flushOutput() {
        bitLock.lock()
        bitProducer = 0
        bitConsumer = 0
        bitLock.unlock()
    }

    //  Note: caller must apply lock to bitLock
    private func insertPrimaryValue(_ value: Int32, withCharacter ch: Int32) {
        ring[Int(bitProducer)].character = ch
        ring[Int(bitProducer)].secondaryCharacter = 0
        ring[Int(bitProducer)].value = value
        bitProducer += 1
        bitProducer &= 0xfff
    }

    //  Note: caller must apply lock to bitLock
    private func insertSecondaryValue(_ value: Int32, withCharacter ch: Int32) {
        ring[Int(bitProducer)].character = 0
        ring[Int(bitProducer)].secondaryCharacter = ch
        ring[Int(bitProducer)].value = value
        bitProducer += 1
        bitProducer &= 0xfff
    }

    //  Non-FEC DominoEX
    private func insertNibbles(_ array: UnsafePointer<CChar>, length: Int32, fromCharacter ch: Int32, secondary isSecondary: Bool) {
        bitLock.lock()
        if isSecondary {
            for i in 0..<Int(length) {
                insertValue(Int32(array[i]), withCharacter: 0, secondary: (i == 0) ? ch : 0)
            }
        } else {
            for i in 0..<Int(length) {
                insertValue(Int32(array[i]), withCharacter: (i == 0) ? ch : 0, secondary: 0)
            }
        }
        bitLock.unlock()
    }

    //  non-FEC DominoEX
    @objc(appendEOM)
    override func appendEOM() {
        var e = [CChar](repeating: 0, count: 2)
        e[0] = CChar(truncatingIfNeeded: nibbleValue[0])
        e[1] = CChar(truncatingIfNeeded: nibbleValue[0])
        e.withUnsafeBufferPointer { insertNibbles($0.baseAddress!, length: 2, fromCharacter: 5, secondary: false) }
    }

    //  non-FEC DominoEX
    private func insertPrimaryASCIIIntoNibbleBuffer(_ ascii: Int32) {
        let nibbles = primaryVaricode.advanced(by: Int(ascii) * 4)
        nibbles.withMemoryRebound(to: CChar.self, capacity: 4) { p in
            insertNibbles(p, length: Int32(strlen(p)), fromCharacter: ascii, secondary: false)
        }
    }

    //  non-FEC DominoEX
    private func insertSecondaryASCIIIntoNibbleBuffer(_ ascii: Int32) {
        let nibbles = secondaryVaricode.advanced(by: Int(ascii) * 4)
        nibbles.withMemoryRebound(to: CChar.self, capacity: 4) { p in
            insertNibbles(p, length: Int32(strlen(p)), fromCharacter: ascii, secondary: true)
        }
    }

    //  New ASCII arrived
    private func encodeAndInsertCharacter(_ ascii: Int32, secondary asSecondary: Bool) {
        var ascii = ascii
        if useFEC {
            if !asSecondary {
                ascii = primaryFECEncodeTable[Int(ascii)]
                insertPrimaryASCIIIntoFECBuffer(ascii, fromCharacter: ascii)
            } else {
                var secondary = secondaryFECEncodeTable[Int(ascii)]
                if secondary == 0 {
                    ascii = Int32(UInt8(ascii: "_"))
                    secondary = secondaryFECEncodeTable[Int(ascii)]
                }
                insertSecondaryASCIIIntoFECBuffer(secondary, fromCharacter: ascii)
            }
        } else {
            if !asSecondary { insertPrimaryASCIIIntoNibbleBuffer(ascii) } else { insertSecondaryASCIIIntoNibbleBuffer(ascii) }
        }
    }

    @objc(appendASCII:)
    override func appendASCII(_ ascii: Int32) {
        var ascii = ascii & 0xff

        // ignore opt u, i, `, e, n (e.g., umlaut prefix)
        if (ascii == 168) || (ascii == 710) || (ascii == 96) || (ascii == 180) || (ascii == 732) { return }

        switch ascii {
        case 0x5: // %[rx]
            if useFEC { super.appendEOM() } else { appendEOM() }
            return
        case 0x6: // %[tx]
            if terminateState == TERMINATESTARTED || terminateState == TERMINATETAIL {
                terminateState = NOTTERMINATING
                modem?.changeTransmitLight(1)
            }
            return
        default:
            if terminateState == NOTTERMINATING {
                //  make sure zero is not transmitted as phi
                if ascii == 0xd8 || ascii == 0xf8 { ascii = Int32(UInt8(ascii: "0")) }
                encodeAndInsertCharacter(ascii, secondary: false)
            }
        }
    }

    private func getNextToneIndex() -> Int32 {
        if terminateState == TERMINATED { return 0 }

        if bitConsumer == bitProducer {
            //  no more user input, insert beacon or empty message into the secondary channel
            if terminateState == NOTTERMINATING {
                var ascii = Int32(beaconPtr!.pointee); beaconPtr = beaconPtr!.advanced(by: 1)
                if ascii == 0 {
                    //  end of beacon message
                    beaconPtr = (beaconString[0] != 0) ? beaconString : defaultBeaconString
                    ascii = Int32(beaconPtr!.pointee); beaconPtr = beaconPtr!.advanced(by: 1)
                }
                insertSecondaryASCIIIntoNibbleBuffer(ascii)
            } else {
                //  Send spaces in secondary channel
                terminateState = (terminateState == TERMINATESTARTED) ? TERMINATETAIL : TERMINATED
                insertSecondaryASCIIIntoNibbleBuffer(Int32(UInt8(ascii: " ")))
            }
        }
        var primaryChar = ring[Int(bitConsumer)].character
        var secondaryChar = ring[Int(bitConsumer)].secondaryCharacter
        var nibble = ring[Int(bitConsumer)].value
        bitConsumer += 1
        bitConsumer &= 0xfff

        //  check for end-of-message that the client has inserted
        switch primaryChar {
        case 5 /* ^E */:
            terminateState = TERMINATESTARTED
            insertSecondaryASCIIIntoNibbleBuffer(Int32(UInt8(ascii: " ")))
            primaryChar = ring[Int(bitConsumer)].character
            secondaryChar = ring[Int(bitConsumer)].secondaryCharacter
            nibble = ring[Int(bitConsumer)].value
            bitConsumer += 1
            bitConsumer &= 0xfff
            modem?.changeTransmitLight(2)
            return getNextToneIndex()
        default:
            break
        }
        //  echo back
        if primaryChar != 0 { modem?.transmittedPrimaryCharacter(primaryChar) }
        if secondaryChar != 0 { modem?.transmittedSecondaryCharacter(secondaryChar) }

        return asciiToNibble[Int(nibble)]
    }

    //  (Private API)
    override func setDDAFrequency(_ freq: Float) {
        carrier = Float(Double(freq) * kPeriod / kCMFs)
    }

    //  Fetch next data bit modulation from the ring buffer (beacon-backed)
    private func getNextDominoFECBit() -> Int32 {
        if terminateState == TERMINATED { return 0 }

        if bitConsumer == bitProducer {
            if terminateState == NOTTERMINATING {
                var ascii = Int32(beaconPtr!.pointee); beaconPtr = beaconPtr!.advanced(by: 1)
                if ascii == 0 {
                    beaconPtr = (beaconString[0] != 0) ? beaconString : defaultBeaconString
                    ascii = Int32(beaconPtr!.pointee); beaconPtr = beaconPtr!.advanced(by: 1)
                }
                encodeAndInsertCharacter(ascii, secondary: true)    //  output to beacon channel
            } else {
                switch terminateState {
                case TERMINATESTARTED:
                    terminateCount += 1
                    if terminateCount < 5 { insertPrimaryFECVaricode(for: 0, fromCharacter: 0) }
                    else {
                        terminateState = TERMINATETAIL
                        terminateCount = 0
                        insertValue(0, withCharacter: 0, secondary: 0)
                    }
                case TERMINATETAIL:
                    terminateCount += 1
                    if terminateCount < 52 {
                        lockAndInsertValue(0, withCharacter: 0, secondary: 0)
                    } else {
                        terminateState = TERMINATED
                        terminateCount = 0
                    }
                default:
                    break
                }
            }
        }
        var primaryChar = ring[Int(bitConsumer)].character
        var secondaryChar = ring[Int(bitConsumer)].secondaryCharacter
        var newBit = ring[Int(bitConsumer)].value
        bitConsumer += 1
        bitConsumer &= 0xfff

        //  check for end-of-message that the client has inserted
        switch primaryChar {
        case 5 /* ^E */:
            if bitConsumer == bitProducer {
                terminateState = TERMINATESTARTED
                terminateCount = 0
                insertPrimaryASCIIIntoFECBuffer(0, fromCharacter: 0)
                primaryChar = ring[Int(bitConsumer)].character
                secondaryChar = ring[Int(bitConsumer)].secondaryCharacter
                newBit = ring[Int(bitConsumer)].value
                bitConsumer += 1
                bitConsumer &= 0xfff
                modem?.changeTransmitLight(2)
            } else {
                //  continue transmitting
                return getNextFECBit()
            }
        default:
            break
        }
        //  echo back
        if primaryChar != 0 { modem?.transmittedPrimaryCharacter(primaryChar) }
        if secondaryChar != 0 { modem?.transmittedSecondaryCharacter(secondaryChar) }

        characterRing[Int(characterRingIndex)] = primaryChar
        characterRingIndex = (characterRingIndex + 1) & 0x3f

        return (newBit == 0) ? 0 : 1
    }

    override func getNextFECBit() -> Int32 {
        return getNextDominoFECBit()
    }

    //  Fetch next audio sample
    override func nextAudioSample() -> Float {
        if terminateState == TERMINATED {
            return (transmitBPF != nil) ? CMSimpleFilter(transmitBPF, 0.0) : 0.0
        }
        if cw { return Float(Double(sin(Double(carrier))) * 0.9) }       // test CW tone

        //  check if the next symbol is needed
        if modulation(baudDDA) {
            //  differential encode FSK here
            lastTone = (lastTone + deltaTone + 2) % 18
            if !useFEC {
                deltaTone = getNextToneIndex()
            } else {
                deltaTone = getNextFECIndex()                           //  same as MFSK16, but with no gray scale encoding
            }
            setDDAFrequency(Float(Double(idleFrequency) + Double(binWidth) * Double(sideband) * Double(lastTone)))
        }
        let v = Float(Double(sin(Double(carrier))) * 0.9)

        return (transmitBPF != nil) ? CMSimpleFilter(transmitBPF, v) : v
    }

    @objc(getBufferWithIdleFill:length:)
    override func getBufferWithIdleFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        if idleFrequency < 20.0 {
            for i in 0..<Int(samples) { buf[i] = 0.0 }
            return
        }
        for i in 0..<Int(samples) { buf[i] = nextAudioSample() }
    }

    @objc(setFrequency:)
    override func setFrequency(_ freq: Float) {
        idleFrequency = freq
        setDDAFrequency(freq)

        if let bpf = transmitBPF {
            transmitBPF = nil
            CMDeleteFIR(bpf)
        }
        let side = Float(Double(binWidth) * 3.2)            //  lower cutoff
        let delta = Float(Double(binWidth) * 17 + Double(side))     //  upper cutoff

        if sideband > 0 {
            transmitBPF = CMFIRBandpassFilter(freq - side, freq + delta, Float(kCMFs), 1024)
        } else {
            transmitBPF = CMFIRBandpassFilter(freq - delta, freq + side, Float(kCMFs), 1024)
        }
    }

    @objc(setBinWidth:baudRatio:)
    func setBinWidth(_ hz: Float, baudRatio inBaudRatio: Int32) {
        binWidth = hz
        baudRatio = inBaudRatio
        baudDDA = Double(binWidth) * kPeriod / kCMFs / Double(baudRatio)
    }

    @objc(setBeacon:)
    func setBeacon(_ msg: UnsafePointer<CChar>) {
        let length = Int(strlen(msg))
        if length >= 2047 { return }        //  sanity check for buffer overflow

        //  memset( &beaconString[length], 0, 2048-length ); strcpy( beaconString, msg )
        for i in length..<2048 { beaconString[i] = 0 }
        for i in 0..<length { beaconString[i] = msg[i] }
        beaconString[length] = 0
        if length > 0 { beaconPtr = beaconString }
    }

    //  ----- FEC -----

    @objc(insertSecondaryASCIIIntoFECBuffer:fromCharacter:)
    func insertSecondaryASCIIIntoFECBuffer(_ ascii: Int32, fromCharacter ch: Int32) {
        bitLock.lock()
        idleSequenceState = 0
        guard let bits = varicode.encode(ascii) else { bitLock.unlock(); return }
        let length = Int(strlen(bits))
        let zero = CChar(UInt8(ascii: "0"))

        for i in 0..<length {
            let b = bits[i]
            insertValue((b == zero || b == 0) ? 0 : 1, withCharacter: 0, secondary: (i == 0) ? ch : 0)
        }
        bitLock.unlock()
    }

    @objc(insertPrimaryFECVaricodeFor:fromCharacter:)
    override func insertPrimaryFECVaricode(for ascii: Int32, fromCharacter echo: Int32) {
        var ascii = ascii
        let secondary = secondaryFECEncodeTable[Int(ascii)]
        if secondary != 0 { ascii = Int32(UInt8(ascii: "_")) }      //  ASCII code overlaps into secondary code, replace by _

        insertPrimaryASCIIIntoFECBuffer(ascii, fromCharacter: echo)
    }

    @objc(insertSecondaryFECVaricodeFor:fromCharacter:)
    override func insertSecondaryFECVaricode(for ascii: Int32, fromCharacter echo: Int32) {
        var ascii = ascii
        var secondary = secondaryFECEncodeTable[Int(ascii)]
        if secondary == 0 {
            ascii = Int32(UInt8(ascii: "_"))                        //  Unassigned secondary code, replace by secondary _
            secondary = ascii
        }
        insertSecondaryASCIIIntoFECBuffer(secondary, fromCharacter: echo)
    }
}
