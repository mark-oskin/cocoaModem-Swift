//
//  HellModulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/29/06.
//  Swift port of HellModulator.m.
//
//  Hellschreiber modulator (Feld Hell AM and FM Hell).  Subclass of MSKGenerator.
//  Works in a pull fashion: characters are pushed in with -appendASCII: (expanded
//  from the font bitmap into per-pixel ToneStream entries) and audio is fetched
//  with -getBufferWithIdleFill:length:, then bandpass filtered.
//
//  The font header (index[128]/fontData) is a still-Objective-C C struct reached
//  through the bridging header.  Its index[] table is read directly from struct
//  memory (offset 36) so the original pointer arithmetic -- including the
//  historical ascii&0x1ff over-read -- is reproduced exactly.
//

import Cocoa

private let kCMPi: Double = 3.141592653589793

//  modeMenu tags HELLFELD/HELLFM245/HELLFM105 are module-scope constants
//  declared in Hellschreiber.swift.

//  offset of HellschreiberFontHeader.index within the struct
//  (short version; short size; char name[32]; short index[128]; uchar* fontData)
private let kFontIndexOffset = 36

//  output pixel stream (was ToneStream in HellModulator.h)
struct ToneStream {
    var gray: Int32 = 0                         //  gray value
    var eof: Bool = false
    var echo: UnsafeMutablePointer<UInt8>? = nil    //  full duplex echo, nil or pointer to 14 pixels
}

//  ring buffer character stream (was CharacterStream in HellModulator.h)
struct CharacterStream {
    var columns: Int32 = 0
    var eof: Bool = false
    var pixmap: UnsafeMutablePointer<UInt8>? = nil  //  pointer to start of bitmaps
}

private let kHellRingMask: Int32 = 0x1fff       //  RINGMASK

@objc(HellModulator)
class HellModulator: MSKGenerator {

    private var carrier: Float = 0
    private var fmCarrier: Float = 0
    private var bitValue: Float = 0
    private var qBitValue: Float = 0
    private var qBitPhase: Int32 = 0
    private var sidebandState: Bool = false
    //  bit buffer
    private var charLock: NSLock!
    private var bitIndex: Int32 = 0
    private var bitLimit: Int32 = 0
    private var charProducer: Int32 = 0
    private var charConsumer: Int32 = 0
    private var ring = [CharacterStream](repeating: CharacterStream(), count: Int(kHellRingMask) + 1)
    private var bitBuffer = [ToneStream](repeating: ToneStream(), count: 512)   //  up to 512 pixels per character
    private var toneStreamIndex: Int32 = 0
    private var terminatedFlag: Bool = false
    private var cw: Bool = false
    private var modulationMode: Int32 = 0
    private var deviation: Float = 0

    private weak var modem: Hellschreiber?
    private var transmitBPF: UnsafeMutablePointer<CMFIR>?
    private var fir: UnsafeMutablePointer<Float>?
    private var bpfBuf = [Float](repeating: 0, count: 512)

    private var diddle: Bool = false
    private let idleColumn = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
    private let diddleCharacter = UnsafeMutablePointer<UInt8>.allocate(capacity: 48)

    private var font: UnsafeMutablePointer<HellschreiberFontHeader>?

    override init() {
        idleColumn.initialize(repeating: 0, count: 16)
        diddleCharacter.initialize(repeating: 0, count: 48)
        super.init()
        bitValue = 0
        qBitValue = 0
        qBitPhase = 0
        modem = nil
        font = nil
        cw = false
        diddle = false
        sidebandState = false

        //  set up transmit BPF
        carrier = 0
        fmCarrier = 0
        fir = nil
        transmitBPF = nil
        setFrequency(1000.0)
        //  finish init
        for i in 0..<16 {
            idleColumn[i] = 0
            diddleCharacter[i] = 0
            diddleCharacter[i + 16] = 0
            diddleCharacter[i + 32] = 0
        }
        diddleCharacter[22] = 0xf0
        diddleCharacter[23] = 0xf0
        charLock = NSLock()
        resetModulator()
    }

    deinit {
        if let fir = fir { free(fir) }
        if let bpf = transmitBPF { CMDeleteFIR(bpf) }
        idleColumn.deallocate()
        diddleCharacter.deallocate()
    }

    @objc(setSidebandState:)
    func setSidebandState(_ state: Bool) {
        sidebandState = state
    }

    @objc(createTransmitBPF:)
    func createTransmitBPF(_ freq: Float) {
        var bw: Float
        let center: Float

        if modulationMode == HELLFELD {
            //  FeldHell
            center = freq
            bw = 115.0                          // v0.33
        } else {
            // FM Hell
            if modulationMode == HELLFM105 {
                var c = freq + 105.0 * 0.25 + 10
                if sidebandState { c -= 105.0 * 0.5 }
                center = c
                bw = 70.0
            } else {
                var c = freq + 245.0 * 0.25
                if sidebandState { c -= 245.0 * 0.5 }
                center = c
                bw = 100.0
            }
        }

        let n: Float = 1024
        let f = Float(0.5 * Double(center) * Double(n) / kCMFs)
        let w = Float(Double(bw) * Double(n) / kCMFs)

        if let fir = fir { free(fir) }
        fir = malloc(Int(n) * MemoryLayout<Float>.stride)?.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        let nInt = Int(n)
        for i in 0..<nInt {
            let t = n / 2
            let x = (Float(i) - t) / t
            let baseband = Float(CMModifiedBlackmanWindow(Int32(i), Int32(n)) * CMSinc(Int32(i), Int32(n), Double(w)))
            sum += baseband
            fir![i] = Float(Double(baseband) * Foundation.cos(2.0 * kCMPi * Double(f) * Double(x)))
        }
        let scaleW: Float = 2 / sum
        for i in 0..<nInt { fir![i] *= scaleW }

        if let bpf = transmitBPF { CMDeleteFIR(bpf) }
        transmitBPF = CMFIRFilter(fir, Int32(n))
    }

    func setFont(_ newfont: UnsafeMutablePointer<HellschreiberFontHeader>?) {
        font = newfont
    }

    @objc(setDiddle:)
    func setDiddle(_ state: Bool) {
        diddle = state
    }

    @objc(frequency)
    func frequencyValue() -> Float {
        return Float(Double(carrier) * kCMFs / kPeriod)
    }

    private func setFMCarrier() {
        var c = carrier
        if sidebandState == true {
            let freq = frequencyValue()
            if modulationMode == HELLFM105 {
                c = Float((Double(freq) - 105.0 * 0.5) * kPeriod / kCMFs)
            } else if modulationMode == HELLFM245 {
                c = Float((Double(freq) - 245.0 * 0.5) * kPeriod / kCMFs)
            }
        }
        fmCarrier = c
        deviation = Float(((modulationMode == HELLFM105) ? 52.5 : 122.5) * kPeriod / kCMFs)
    }

    //  setup carrier for self (NCO object)
    @objc(setFrequency:)
    func setFrequency(_ freq: Float) {
        let oldFreq = frequencyValue()

        carrier = Float(Double(freq) * kPeriod / kCMFs)
        setFMCarrier()
        let diff = abs(oldFreq - freq)
        if diff > 5.0 { createTransmitBPF(freq) }
    }

    @objc(setMode:)
    func setMode(_ mode: Int32) {
        modulationMode = mode

        setFMCarrier()
        setBaudRate((modulationMode == HELLFM105) ? 105.0 : 245.0)
        createTransmitBPF(Float(Double(carrier) * kCMFs / kPeriod))
        // v0.33
        bitValue = 0
        qBitValue = 0
        qBitPhase = 0
    }

    /* local */
    //  expand a column of bitmap data into a stream structure
    private func insertBitColumn(_ pixel: UnsafeMutablePointer<UInt8>?, length: Int32, eof: Bool, into start: Int) -> Int {
        if modulationMode == HELLFM105 {
            //  create 6 column tall fuzzy font version
            for i in 0..<6 {
                let p = (Int32(pixel![i * 2]) + Int32(pixel![i * 2 + 1])) / 2
                bitBuffer[start + i].eof = eof
                bitBuffer[start + i].echo = (i == 0 || eof == true) ? pixel : nil
                bitBuffer[start + i].gray = p
            }
            return 6
        }

        for i in 0..<Int(length) {
            bitBuffer[start + i].eof = eof
            bitBuffer[start + i].echo = (i == 0 || eof) ? pixel : nil
            bitBuffer[start + i].gray = Int32(pixel![i])
        }
        return Int(length)
    }

    /* local */
    //  expand a ring buffer entry (per character) into columns of bitmap stream structures
    private func expandCharacter(_ character: CharacterStream) {
        var dst = 0
        bitIndex = 0
        bitLimit = 0
        if character.eof {
            let bits = insertBitColumn(idleColumn, length: 14, eof: true, into: dst)
            dst += bits
            bitLimit += Int32(bits)
        } else {
            var body = character.pixmap
            // limit to 30 columns (size of ToneStream buffer)
            var columns = character.columns
            if columns > 30 { columns = 30 }
            for _ in 0..<Int(columns) {
                let bits = insertBitColumn(body, length: 14, eof: false, into: dst)
                dst += bits
                bitLimit += Int32(bits)
                body = body?.advanced(by: 16)   //  font bitmap arranged in 16 pixel tall columns
            }
        }
    }

    //  insert character into ring buffer
    private func insertCharacter(_ pixmap: UnsafeMutablePointer<UInt8>?, columns width: Int32, eof: Bool) {
        charLock.lock()
        var k = charProducer
        ring[Int(k)].pixmap = pixmap
        ring[Int(k)].columns = width
        ring[Int(k)].eof = eof
        k = (k + 1) & kHellRingMask
        charProducer = k
        charLock.unlock()
    }

    @objc(flushTransmitBuffer)
    func flushTransmitBuffer() {
        charLock.lock()
        charConsumer = charProducer
        charLock.unlock()
    }

    @objc(insertEndOfTransmit)
    func insertEndOfTransmit() {
        //  insert eof in the stream column to indicate that the end of transmit stream is reached
        insertCharacter(idleColumn, columns: 1, eof: true)
    }

    @objc(appendASCII:)
    func appendASCII(_ ascii: Int32) {
        var ascii = ascii
        guard let font = font else { return }

        // undo slashed zero
        if ascii == 0xd8 || ascii == 0xf8 { ascii = Int32(UInt8(ascii: "0")) }

        let base = UnsafeRawPointer(font)
        let offset = Int(base.load(fromByteOffset: kFontIndexOffset + (Int(ascii) & 0x1ff) * 2, as: Int16.self))
        var body = font.pointee.fontData?.advanced(by: offset)
        let columns = Int32(body![1])
        if columns <= 12 {
            // only allow fonts of up to 12 columns
            body = body?.advanced(by: 2)
            insertCharacter(body, columns: columns, eof: false)
        }
    }

    private func insertDiddle() {
        var bits = insertBitColumn(diddleCharacter, length: 14, eof: false, into: 0)
        bits += insertBitColumn(diddleCharacter.advanced(by: 16), length: 14, eof: false, into: bits)
        bits += insertBitColumn(diddleCharacter.advanced(by: 32), length: 14, eof: false, into: bits)
        bitIndex = 0
        bitLimit = Int32(bits)
    }

    //  insert idle into the stream
    @objc(insertShortIdle)
    func insertShortIdle() {
        bitLimit = Int32(insertBitColumn(idleColumn, length: 14, eof: false, into: 0))
        bitIndex = 0
    }

    //  Fetch next pixel modulation from the ring buffer.
    private func getNextPixel() -> Float {
        if terminatedFlag { return 0 }

        //  check if any more bits left in bitBuffer[]
        if bitIndex >= bitLimit {
            //  no more bits
            if charConsumer == charProducer {
                //  no more characters left, send idle column(s)
                if diddle { insertDiddle() } else { insertShortIdle() }
            } else {
                //  fetch next character into bit buffer
                let character = ring[Int(charConsumer)]
                if character.eof {
                    //  at the end of message or a series of messages
                    terminatedFlag = true
                    return 0.0
                }
                expandCharacter(character)
                charConsumer = (charConsumer + 1) & kHellRingMask
            }
        }

        if bitIndex >= bitLimit {
            // in case insert fails, just send a quiet pixel
            return 0.0
        }

        //  fetch data from next bit
        let echo = bitBuffer[Int(bitIndex)].echo
        let pix = bitBuffer[Int(bitIndex)].gray
        bitIndex += 1
        bitIndex &= 0xff                        //  sanity limit

        //  echo all transmitted columns
        if let echo = echo { transmittedColumn(echo) }

        //  actual pixel value
        return Float(Double(pix & 0xff) / 255.0)
    }

    @objc(terminated)
    func terminated() -> Bool {
        return terminatedFlag
    }

    //  called from config to transmit a pure carrier
    @objc(setCW:)
    func setCW(_ state: Bool) {
        cw = state
    }

    //  (local) Hellschreiber modulator
    private func nextSample() -> Float {
        if terminatedFlag { return 0.0 }

        if cw { return Float(Double(sin(Double(carrier))) * 0.9) }       // test CW tone

        let output: Float
        if modulationMode == HELLFM105 || modulationMode == HELLFM245 {

            //  find when we need to fetch next bit
            if advanceBitSample() {
                var v = getNextPixel()
                if sidebandState { v = 1.0 - v }
                if qBitPhase == 0 { bitValue = v } else { qBitValue = v }
                qBitPhase = (qBitPhase + 1) & 0x1
            }
            var t = sinForModulation()
            let mSin = t * t
            t = cosForModulation()
            let mCos = t * t
            let modulation = (bitValue * mCos + qBitValue * mSin) * deviation   //  instantaneous deviation
            /* FM */
            output = Float(Double(sin(Double(fmCarrier + modulation))) * 0.9)
        } else {
            if advanceBitSample() { bitValue = getNextPixel() }
            /* AM */
            output = Float(Double(bitValue * sin(Double(carrier))) * 0.9)        // feld hell
        }
        return output
    }

    @objc(getBufferWithIdleFill:length:)
    func getBufferWithIdleFill(_ outbuf: UnsafeMutablePointer<Float>, length samples: Int32) {
        assert(samples <= 512)
        bpfBuf.withUnsafeMutableBufferPointer { bb in
            for i in 0..<Int(samples) { bb[i] = nextSample() }
            //  apply bandpass filter and save into output
            CMPerformFIR(transmitBPF, bb.baseAddress, samples, outbuf)
        }
    }

    @objc(resetModulator)
    func resetModulator() {
        bitIndex = 0
        bitLimit = 0
        charLock.lock()
        charProducer = 0
        charConsumer = 0
        charLock.unlock()
        terminatedFlag = false
    }

    @objc(setModemClient:)
    func setModemClient(_ client: Hellschreiber?) {
        modem = client
    }

    @objc(transmittedColumn:)
    func transmittedColumn(_ column: UnsafeMutablePointer<UInt8>) {
        var pix = [Float](repeating: 0, count: 28)

        if let modem = modem {
            if modulationMode == HELLFM105 {
                for i in 0..<6 {
                    var v = Float(Double(Int32(column[i * 2]) + Int32(column[i * 2 + 1])) / 510.0)
                    if v < 0 { v = 0 } else if v > 1.0 { v = 1.0 }
                    pix[i * 2] = v; pix[i * 2 + 1] = v; pix[i * 2 + 14] = v; pix[i * 2 + 15] = v
                }
            } else {
                for i in 0..<12 {
                    let v = Float(Double(column[i]) / 255.0)
                    pix[i] = v; pix[i + 14] = v
                }
            }
            pix[12] = 0; pix[13] = 0; pix[26] = 0; pix[27] = 0
            pix.withUnsafeMutableBufferPointer { p in
                modem.addColumn(p.baseAddress, index: 1, xScale: 2)
            }
        }
    }
}
