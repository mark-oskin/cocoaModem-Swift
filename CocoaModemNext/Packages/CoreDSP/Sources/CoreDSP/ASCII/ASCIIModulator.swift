//
//  ASCIIModulator.swift
//  CoreDSP
//
//  7/8-bit async-serial ASCII FSK modulator (default 110 baud, 2 stop bits).
//  Faithful transplant of the DSP-critical parts of ASCIIModulator.m's Swift
//  port (Sources/Swift/Modems/ASCII/ASCIIModulator.swift) plus the ring-buffer
//  bit-stream machinery it inherited from CMFSKModulator/RTTYModulatorBase
//  (Sources/Swift/Modems/CoreModem/FSK/CMFSKModulator.swift and
//  Sources/Swift/Modems/RTTY/RTTYModulatorBase.swift).
//
//  Unlike RTTY's 5-bit Baudot, ASCII characters are sent as an identity
//  ASCII-to-ASCII map (no LTRS/FIGS shift state), so the whole
//  CMFSKModulator -> RTTYModulatorBase -> RTTYModulator -> ASCIIModulator
//  class chain (which existed mostly to share Baudot-shift and OOK/two-tone
//  test-tone plumbing that ASCII never used) is collapsed into this single
//  class, subclassing CMNCO directly exactly as CMFSKModulator did.  The
//  actual bit-framing algorithm (ring buffer of start/data/stop "bits", each
//  tagged with a phase-increment duration and consumed one audio sample at a
//  time by getBufferWithDiddleFill) is preserved exactly.
//

import Foundation

//  unmap phi (two different Mac-encoding codepoints the old app treated as a
//  legacy "phi means zero" typo) to '0'; mask everything else to 7 bits.
private func asciiUnmapPhi(_ d: Int32) -> Int32 {
    if d == 216 || d == 175 { return Int32(UInt8(ascii: "0")) }
    return d & 0x7f
}

//  65536-entry ring buffer mask (was CMSTREAMMASK in CMFSKModulator.h).
private let asciiStreamMask: Int32 = 0xffff

public protocol ASCIIModulatorDelegate: AnyObject {
    /// Echo of a character as its start bit is actually clocked out to audio.
    func asciiTransmittedCharacter(_ ch: Int32)
}

public extension ASCIIModulatorDelegate {
    func asciiTransmittedCharacter(_ ch: Int32) {}
}

final class ASCIIModulator: CMNCO {

    weak var delegate: ASCIIModulatorDelegate?

    private var tonePair = ASCIITonePair(mark: 0, space: 0, baud: 0)
    private var markDelta: Double = 0      //  phase-increment/sample for the mark tone
    private var spaceDelta: Double = 0     //  phase-increment/sample for the space tone
    private var bitDDA: Double = 0         //  phase-increment/sample corresponding to one bit period
    private var currentBitDDA: Double = 0
    private var stopDDA: Double = 0
    private var stopDuration: Float = 2.0

    private var stopBit = ASCIIBinaryStream()
    private var startBit = ASCIIBinaryStream()
    private var dataBit = [ASCIIBinaryStream](repeating: ASCIIBinaryStream(), count: 2)
    private var stream = [ASCIIBinaryStream](repeating: ASCIIBinaryStream(), count: Int(asciiStreamMask) + 1)

    private(set) var bitsPerCharacter: Int32 = 7

    override init() {
        super.init()
        producer = 0
        consumer = 0
        setTonePair(mark: 2125.0, space: 2295.0, baud: 110.0)
        setStopBits(2.0)
    }

    // MARK: - Configuration

    func setTonePair(mark: Double, space: Double, baud: Double) {
        tonePair = ASCIITonePair(mark: mark, space: space, baud: baud)
        markDelta = mark * kPeriod / kCMFs
        spaceDelta = space * kPeriod / kCMFs
        bitDDA = baud * kPeriod / kCMFs

        current = markDelta
        currentBitDDA = bitDDA

        startBit = ASCIIBinaryStream(polarity: 0, dda: bitDDA, character: 0)
        dataBit[0] = ASCIIBinaryStream(polarity: 0, dda: bitDDA, character: 0)
        dataBit[1] = ASCIIBinaryStream(polarity: 1, dda: bitDDA, character: 0)
        setStopBits(stopDuration)
    }

    //  Stop bits (defaulted to 2.0 by init, matching ASCIIModulator.initSetup).
    func setStopBits(_ stopBits: Float) {
        guard stopBits >= 0.99 && stopBits <= 2.01 else { return }
        stopDuration = stopBits
        stopDDA = bitDDA / Double(stopDuration)
        stopBit = ASCIIBinaryStream(polarity: 1, dda: stopDDA, character: 0)
    }

    func setBitsPerCharacter(_ bits: Int32) {
        bitsPerCharacter = min(8, max(7, bits))
    }

    // MARK: - Bit-stream ring buffer (producer/consumer inherited from CMNCO)

    //  append a long mark tone (11 bits long, with no start bit) -- used as a
    //  TX lead-in ('|' maps to this, matching ASCIIModulator.appendASCII).
    func appendLongMark() {
        stream[Int(producer)] = stopBit
        stream[Int(producer)].dda /= 11.0
        producer = (producer + 1) & asciiStreamMask
    }

    //  append diddle (idle-fill or control-character marker): a start bit
    //  tagged with `flag`, all-mark data bits, a stop bit.
    private func appendDiddle(_ flag: Int32) {
        var diddle: Int32 = 0xff
        lock.lock()
        var tempProducer = producer
        stream[Int(tempProducer)] = startBit
        stream[Int(tempProducer)].character = flag
        tempProducer = (tempProducer + 1) & asciiStreamMask
        for _ in 0..<Int(bitsPerCharacter) {
            stream[Int(tempProducer)] = dataBit[Int(diddle & 1)]
            tempProducer = (tempProducer + 1) & asciiStreamMask
            diddle >>= 1
        }
        stream[Int(tempProducer)] = stopBit
        tempProducer = (tempProducer + 1) & asciiStreamMask
        producer = tempProducer
        lock.unlock()
    }

    //  append bitsPerCharacter bits of `code`, framed with a start and stop bit.
    private func appendBits(_ code: Int32, ascii: Int32) {
        var code = code
        var tempProducer = producer
        stream[Int(tempProducer)] = startBit
        stream[Int(tempProducer)].character = ascii
        tempProducer = (tempProducer + 1) & asciiStreamMask
        for _ in 0..<Int(bitsPerCharacter) {
            stream[Int(tempProducer)] = dataBit[Int(code & 1)]
            tempProducer = (tempProducer + 1) & asciiStreamMask
            code >>= 1
        }
        stream[Int(tempProducer)] = stopBit
        tempProducer = (tempProducer + 1) & asciiStreamMask
        producer = tempProducer
    }

    //  append a single ASCII character (identity ASCII-to-ASCII map -- no
    //  Baudot letters/figures shift state).
    func appendASCII(_ asciiIn: Int32) {
        var ascii = asciiUnmapPhi(asciiIn)
        var echo: Int32

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

        if ascii == Int32(UInt8(ascii: "|")) {
            //  long mark character
            appendLongMark()
            return
        }
        if ascii == Int32(UInt8(ascii: "\n")) {
            //  transmit newline from textview as CR
            ascii = Int32(UInt8(ascii: "\r"))
            echo = 0
        }
        let code = ascii     //  ASCII-to-ASCII identity map

        if code != 0 {
            lock.lock()
            appendBits(code & 0xff, ascii: echo)     //  send 8 bits; appendBits shortens to bitsPerCharacter
            if ascii == Int32(UInt8(ascii: "\r")) {
                //  send \n from text view as cr/lf pair
                appendBits(Int32(UInt8(ascii: "\n")) & 0x1f, ascii: Int32(UInt8(ascii: "\n")))
            }
            lock.unlock()
        }
    }

    //  consume from the current buffer; add diddle if there is no more bits to
    //  consume (keeps outputting valid FSK idle instead of dead carrier).
    func getBufferWithDiddleFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        for i in 0..<Int(samples) {
            buf[i] = sin(current)
            if modulation(currentBitDDA) {
                consumer = (consumer + 1) & asciiStreamMask
                if consumer == producer { appendDiddle(0) }
                let bit = stream[Int(consumer)]
                currentBitDDA = bit.dda
                current = (bit.polarity == 0) ? spaceDelta : markDelta
                if bit.character != 0 { delegate?.asciiTransmittedCharacter(bit.character) }
            }
        }
    }

    func lengthOfActiveStream() -> Int32 {
        var n = producer - consumer
        if n < 0 { n += asciiStreamMask + 1 }
        return n
    }

    func clearOutput() {
        if consumer < (producer - 1) { consumer = producer - 1 }
    }
}
