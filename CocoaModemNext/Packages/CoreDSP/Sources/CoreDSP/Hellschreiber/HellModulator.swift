//
//  HellModulator.swift
//  CoreDSP
//
//  Swift port of HellModulator.swift (originally HellModulator.m). Hellschreiber
//  modulator (Feld Hell AM and FM Hell). Subclass of MSKGenerator. Works in a
//  pull fashion: characters are pushed in with appendASCII(_:) (expanded from
//  the font pixel table into per-column ToneStream entries) and audio is
//  fetched with getBufferWithIdleFill(_:length:), then bandpass filtered.
//
//  DSP-critical and preserved verbatim from the original: the AM/FM sample
//  generation in nextSample(), the transmit bandpass filter design in
//  createTransmitBPF(_:), and all ring-buffer/bit-buffer index arithmetic
//  (masking, wraparound) in the pixel-stream plumbing.
//
//  Modernized (not a 1:1 memory layout port, per this transplant's brief --
//  DSP behavior preserved, incidental C plumbing is not): the original ring
//  buffer entries pointed into a raw C font bitmap reached through a bridging
//  header (`UnsafeMutablePointer<UInt8>` into a HellschreiberFontHeader's
//  fontData); here CharacterStream/ToneStream carry plain Swift
//  `[UInt8]`/`[[UInt8]]` column data produced by HellFont.columns(for:), so
//  there is no unsafe pointer navigation into font memory. The modem/echo
//  delegate (`Hellschreiber?` via Objective-C duck typing) becomes a proper
//  Swift protocol, HellModulatorDelegate, with default no-op implementations.
//

import Foundation

//  mode tags (were #defined in Hellschreiber.h / re-declared at module scope
//  in the old Hellschreiber.swift coordinator; every Hell file in this module
//  needs to see them, so they live here, module-internal).
let HELLFELD: Int32 = 0
let HELLFM245: Int32 = 1
let HELLFM105: Int32 = 2

protocol HellModulatorDelegate: AnyObject {
    /// Echo of a transmitted column (28 half-pixels, full duplex tap) -- lets a
    /// UI show what was just sent. `index` is 1 for TX echo (mirrors the
    /// original's `addColumn(_:index:xScale:)` convention where 0 = receive).
    func hellTransmittedColumn(_ column: [Float], index: Int32)
}

extension HellModulatorDelegate {
    func hellTransmittedColumn(_ column: [Float], index: Int32) {}
}

//  output pixel stream (was ToneStream in HellModulator.h)
private struct ToneStream {
    var gray: Int32 = 0                 //  gray value
    var eof: Bool = false
    var echo: [UInt8]? = nil            //  full duplex echo, nil or the 14-pixel source column
}

//  ring buffer character stream (was CharacterStream in HellModulator.h)
private struct CharacterStream {
    var pixmap: [[UInt8]] = []          //  one 14-gray-value array per column
    var eof: Bool = false
}

private let kHellRingMask: Int32 = 0x1fff       //  RINGMASK

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
    private var terminatedFlag: Bool = false
    private var cw: Bool = false
    private var modulationMode: Int32 = 0
    private var deviation: Float = 0

    weak var delegate: HellModulatorDelegate?
    private var transmitBPF: UnsafeMutablePointer<CMFIR>?
    private var fir: UnsafeMutablePointer<Float>?
    private var bpfBuf = [Float](repeating: 0, count: 512)

    private var diddle: Bool = false
    private let idleColumn = [UInt8](repeating: 0, count: 14)
    private let diddleColumns: [[UInt8]] = {
        //  a short recognizable "diddle" idle pattern (mid-gray bar), matching
        //  the intent of the original's `diddleCharacter` (a small filled block
        //  at rows 6/7 of a blank character) without needing raw font bytes.
        var col = [UInt8](repeating: 0, count: 14)
        col[6] = 0xf0
        col[7] = 0xf0
        return [col, col, col]
    }()

    override init() {
        super.init()
        bitValue = 0
        qBitValue = 0
        qBitPhase = 0
        cw = false
        diddle = false
        sidebandState = false

        //  set up transmit BPF
        carrier = 0
        fmCarrier = 0
        fir = nil
        transmitBPF = nil
        setFrequency(1000.0)
        charLock = NSLock()
        resetModulator()
    }

    deinit {
        if let fir = fir { free(fir) }
        if let bpf = transmitBPF { CMDeleteFIR(bpf) }
    }

    func setSidebandState(_ state: Bool) {
        sidebandState = state
    }

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
        let f = Float(0.5 * Double(center) * Double(n) / CMFs)
        let w = Float(Double(bw) * Double(n) / CMFs)

        if let fir = fir { free(fir) }
        fir = malloc(Int(n) * MemoryLayout<Float>.stride)?.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        let nInt = Int(n)
        for i in 0..<nInt {
            let t = n / 2
            let x = (Float(i) - t) / t
            let baseband = Float(CMModifiedBlackmanWindow(Int32(i), Int32(n)) * CMSinc(Int32(i), Int32(n), Double(w)))
            sum += baseband
            fir![i] = Float(Double(baseband) * Foundation.cos(2.0 * CMPi * Double(f) * Double(x)))
        }
        let scaleW: Float = 2 / sum
        for i in 0..<nInt { fir![i] *= scaleW }

        if let bpf = transmitBPF { CMDeleteFIR(bpf) }
        transmitBPF = CMFIRFilter(fir, Int32(n))
    }

    func setDiddle(_ state: Bool) {
        diddle = state
    }

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
    func setFrequency(_ freq: Float) {
        let oldFreq = frequencyValue()

        carrier = Float(Double(freq) * kPeriod / kCMFs)
        setFMCarrier()
        let diff = abs(oldFreq - freq)
        if diff > 5.0 { createTransmitBPF(freq) }
    }

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
    //  expand a column of pixel data into a stream structure; returns pixels written
    @discardableResult
    private func insertBitColumn(_ pixel: [UInt8], eof: Bool, into start: Int) -> Int {
        if modulationMode == HELLFM105 {
            //  create 6 column tall fuzzy font version
            for i in 0..<6 {
                let a = i * 2 < pixel.count ? Int32(pixel[i * 2]) : 0
                let b = i * 2 + 1 < pixel.count ? Int32(pixel[i * 2 + 1]) : 0
                let p = (a + b) / 2
                bitBuffer[start + i].eof = eof
                bitBuffer[start + i].echo = (i == 0 || eof) ? pixel : nil
                bitBuffer[start + i].gray = p
            }
            return 6
        }

        let length = min(pixel.count, 14)
        for i in 0..<length {
            bitBuffer[start + i].eof = eof
            bitBuffer[start + i].echo = (i == 0 || eof) ? pixel : nil
            bitBuffer[start + i].gray = Int32(pixel[i])
        }
        return length
    }

    /* local */
    //  expand a ring buffer entry (per character) into columns of pixel stream structures
    private func expandCharacter(_ character: CharacterStream) {
        var dst = 0
        bitIndex = 0
        bitLimit = 0
        if character.eof {
            let bits = insertBitColumn(idleColumn, eof: true, into: dst)
            dst += bits
            bitLimit += Int32(bits)
        } else {
            // limit to 30 columns (size of ToneStream buffer)
            let columns = character.pixmap.prefix(30)
            for column in columns {
                let bits = insertBitColumn(column, eof: false, into: dst)
                dst += bits
                bitLimit += Int32(bits)
            }
        }
    }

    //  insert character into ring buffer
    private func insertCharacter(_ pixmap: [[UInt8]], eof: Bool) {
        charLock.lock()
        var k = charProducer
        ring[Int(k)].pixmap = pixmap
        ring[Int(k)].eof = eof
        k = (k + 1) & kHellRingMask
        charProducer = k
        charLock.unlock()
    }

    func flushTransmitBuffer() {
        charLock.lock()
        charConsumer = charProducer
        charLock.unlock()
    }

    func insertEndOfTransmit() {
        //  insert eof in the stream column to indicate that the end of transmit stream is reached
        insertCharacter([idleColumn], eof: true)
    }

    func appendASCII(_ ascii: Int32) {
        var ascii = ascii

        // undo slashed zero
        if ascii == 0xd8 || ascii == 0xf8 { ascii = Int32(UInt8(ascii: "0")) }

        guard let scalar = Unicode.Scalar(UInt32(bitPattern: ascii)) else { return }
        let columns = HellFont.columns(for: Character(scalar))
        if columns.count <= 12 + 1 {   // +1 for the trailing inter-character spacing column
            insertCharacter(columns, eof: false)
        }
    }

    private func insertDiddle() {
        var bits = 0
        for column in diddleColumns {
            bits += insertBitColumn(column, eof: false, into: bits)
        }
        bitIndex = 0
        bitLimit = Int32(bits)
    }

    //  insert idle into the stream
    func insertShortIdle() {
        bitLimit = Int32(insertBitColumn(idleColumn, eof: false, into: 0))
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

    func terminated() -> Bool {
        return terminatedFlag
    }

    //  called from config to transmit a pure carrier
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

    func getBufferWithIdleFill(_ outbuf: UnsafeMutablePointer<Float>, length samples: Int32) {
        assert(samples <= 512)
        bpfBuf.withUnsafeMutableBufferPointer { bb in
            for i in 0..<Int(samples) { bb[i] = nextSample() }
            //  apply bandpass filter and save into output
            CMPerformFIR(transmitBPF, bb.baseAddress, samples, outbuf)
        }
    }

    func resetModulator() {
        bitIndex = 0
        bitLimit = 0
        charLock.lock()
        charProducer = 0
        charConsumer = 0
        charLock.unlock()
        terminatedFlag = false
    }

    func transmittedColumn(_ column: [UInt8]) {
        var pix = [Float](repeating: 0, count: 28)

        if modulationMode == HELLFM105 {
            for i in 0..<6 {
                let a = i * 2 < column.count ? Int32(column[i * 2]) : 0
                let b = i * 2 + 1 < column.count ? Int32(column[i * 2 + 1]) : 0
                var v = Float(Double(a + b) / 510.0)
                if v < 0 { v = 0 } else if v > 1.0 { v = 1.0 }
                pix[i * 2] = v; pix[i * 2 + 1] = v; pix[i * 2 + 14] = v; pix[i * 2 + 15] = v
            }
        } else {
            for i in 0..<12 {
                let g = i < column.count ? column[i] : 0
                let v = Float(Double(g) / 255.0)
                pix[i] = v; pix[i + 14] = v
            }
        }
        pix[12] = 0; pix[13] = 0; pix[26] = 0; pix[27] = 0
        delegate?.hellTransmittedColumn(pix, index: 1)
    }
}
