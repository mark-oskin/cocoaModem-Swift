//
//  ASCIIModulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/30/10.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//  Swift port of ASCIIModulator.m.
//
//  7/8-bit ASCII FSK modulator (110 baud).  Subclass of RTTYModulator; the
//  encoding table is an identity ASCII-to-ASCII map and characters are sent
//  bitsPerCharacter bits wide rather than 5-bit Baudot.
//

import Foundation

//  unmap phi to zero
private func unmap(_ d: Int32) -> Int32 {
    if d == 216 || d == 175 { return Int32(UInt8(ascii: "0")) }
    return d & 0x7f
}

@objc(ASCIIModulator)
class ASCIIModulator: RTTYModulator {

    @objc(initSetup)
    override func initSetup() {
        var tonepair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 110.0)

        usos = false
        shifted = false
        robust = false
        sideband = 0
        robustCount = 0
        bitsPerCharacter = 7
        setTonePair(&tonepair)
        setStopBits(2.0)
        for i in 0..<256 { mapping[i] = Int32(i) }  // set the encoding table to ASCII-to-ASCII mapping
    }

    //  (Private API)
    //  in ASCIIModulator, -appendBits appends ASCII bits
    override func appendBits(_ code: Int32, ascii: Int32) {
        var code = code
        shifted = false
        var tempProducer = producer
        stream[Int(tempProducer)] = startBit
        stream[Int(tempProducer)].character = ascii
        tempProducer = (tempProducer + 1) & CMSTREAMMASK
        for _ in 0..<Int(bitsPerCharacter) {
            stream[Int(tempProducer)] = dataBit[Int(code & 1)]
            tempProducer = (tempProducer + 1) & CMSTREAMMASK
            code >>= 1  // next bit of ASCII character
        }
        stream[Int(tempProducer)] = stopBit
        tempProducer = (tempProducer + 1) & CMSTREAMMASK
        producer = tempProducer
    }

    //  (Private API)
    //  append diddle (0x7f or 0xff)
    override func appendDiddle(_ flag: Int32) {
        var diddle: Int32 = 0xff
        lock.lock()
        shifted = false
        var tempProducer = producer
        stream[Int(tempProducer)] = startBit
        stream[Int(tempProducer)].character = flag
        tempProducer = (tempProducer + 1) & CMSTREAMMASK
        for _ in 0..<Int(bitsPerCharacter) {
            stream[Int(tempProducer)] = dataBit[Int(diddle & 1)]
            tempProducer = (tempProducer + 1) & CMSTREAMMASK
            diddle >>= 1  // next bit of diddle character
        }
        stream[Int(tempProducer)] = stopBit
        tempProducer = (tempProducer + 1) & CMSTREAMMASK
        producer = tempProducer
        lock.unlock()
    }

    //  append a single ascii character
    @objc(appendASCII:)
    override func appendASCII(_ ascii: Int32) {
        var ascii = unmap(ascii)    // this will unmap any phi into zero and also map '\n' into '\r'
        var echo: Int32
        var code: Int32

        if ascii <= 26 {
            //  control characters
            switch Int32(UInt8(ascii: "a")) + ascii - 1 {
            case Int32(UInt8(ascii: "e")):
                appendDiddle(0)
                appendDiddle(ascii)
                return
            case Int32(UInt8(ascii: "z")):
                appendDiddle(ascii)
                return
            default:
                break
            }
        }
        echo = ascii

        switch ascii {
        case Int32(UInt8(ascii: "|")):
            /* long mark character */
            appendLongMark()
            return
        default:
            if ascii == Int32(UInt8(ascii: "\n")) {
                //  transmit newline from textview as CR
                ascii = Int32(UInt8(ascii: "\r"))
                echo = 0
            }
            code = mapping[Int(ascii)]      // ASCII to ASCII map
        }
        if code != 0 {
            lock.lock()
            appendBits(code & 0xff, ascii: echo)    //  send 8 bit ASCII and let appendBits shorten it if needed to 7 bits
            if ascii == Int32(UInt8(ascii: "\r")) {
                //  send \n from text view as cr/lf pair
                appendBits(mapping[Int(UInt8(ascii: "\n"))] & 0x1f, ascii: Int32(UInt8(ascii: "\n")))
            }
            lock.unlock()
        }
    }
}
