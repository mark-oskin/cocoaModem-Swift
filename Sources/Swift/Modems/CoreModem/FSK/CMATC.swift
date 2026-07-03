//
//  CMATC.swift
//  CoreModem
//
//  Created by Kok Chen on 10/25/05
//	(ported from cocoaModem, original file dated Fri Jul 16 2004)
//
//  Swift port of CMATC.m -- Multiple Automatic Threshold Correction.
//  ATC is patterned after Marvin Frerking, "Digital Signal Processing in
//  Communication Systems," Chapman & Hall 1993, ISBN 0-442-01616-6.
//
//  Decode-critical.  The C structs (CMATCStream, CMATCCase, CMDataStream) carry
//  fixed C arrays that must be addressed with raw pointer arithmetic, so they are
//  heap-allocated (UnsafeMutablePointer) and freed in deinit.  Because
//  CMATCStream.data is the first field of the struct, a pointer to a CMATCStream
//  is also a pointer to its data[0]; agcData()/inputData()/dataPtr() rely on that.
//  The agc streams are allocated with one extra leading element so the original
//  code's data[offset-1] / data[-2] look-backs (when offset == 0) stay in bounds.
//

import Cocoa
import Accelerate

@objc(CMATC)
class CMATC: CMTappedPipe {

    //  ---- bitsynced data stream (CMDataStream *data == &bitStream) ----
    internal let bitStreamPtr = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
    internal let syncedData = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    internal var bitStream: CMDataStream {
        get { bitStreamPtr.pointee }
        set { bitStreamPtr.pointee = newValue }
    }

    internal var bitTime: Float = 0
    internal var startBit: Int32 = 0
    internal var stopBit: Int32 = 0
    internal var characterAdvance: Int32 = 0
    internal var bitn: Int32 = 0
    //  bit position and transition position in samples (Fs/8)
    internal var bitPos = [Int32](repeating: 0, count: 10)
    internal var transitionPos = [Int32](repeating: 0, count: 10)
    internal var offset: Int32 = 0
    internal var bitsPerCharacter: Int32 = 0
    internal var invert: Bool = false

    internal var input: UnsafeMutablePointer<CMATCStream>!     //  input data
    private var agcBase: UnsafeMutablePointer<CMATCStream>!    //  agc[-1] .. agc[2]
    internal var agc: UnsafeMutablePointer<CMATCStream>!       //  agc[0..2] (== agcBase + 1)
    internal var atcCase: UnsafeMutablePointer<CMATCCase>!     //  atcCase[0..5]

    //  multi-ATC params
    internal var equalizerQuanta: Int32 = 0
    internal var squelch: Float = 0

    //  scope tap
    internal var atcBuffer: CMPipe!

    //  ---- pointer helpers (data[] is the first field of CMATCStream) ----
    internal func dataPtr(_ s: UnsafeMutablePointer<CMATCStream>) -> UnsafeMutablePointer<CMATCPair> {
        return UnsafeMutableRawPointer(s).assumingMemoryBound(to: CMATCPair.self)
    }
    internal var inputData: UnsafeMutablePointer<CMATCPair> { return dataPtr(input) }
    internal func agcData(_ i: Int) -> UnsafeMutablePointer<CMATCPair> { return dataPtr(agc + i) }
    //  bits[] is the 4th int field of CMATCCase (after startingIndex, endingIndex, eq)
    internal func caseBits(_ n: Int) -> UnsafeMutablePointer<Int32> {
        return UnsafeMutableRawPointer(atcCase + n).assumingMemoryBound(to: Int32.self).advanced(by: 3)
    }

    @objc override init() {
        input = UnsafeMutablePointer<CMATCStream>.allocate(capacity: 1)
        input.initialize(to: CMATCStream())
        agcBase = UnsafeMutablePointer<CMATCStream>.allocate(capacity: 4)
        agcBase.initialize(repeating: CMATCStream(), count: 4)
        agc = agcBase + 1
        atcCase = UnsafeMutablePointer<CMATCCase>.allocate(capacity: 6)
        atcCase.initialize(repeating: CMATCCase(), count: 6)

        super.init()

        //  set up bitsync type DataStream (data == &bitStream)
        data = bitStreamPtr
        bitStreamPtr.pointee.array = syncedData
        bitStreamPtr.pointee.samples = 256
        bitStreamPtr.pointee.components = 1
        bitStreamPtr.pointee.channels = 1

        bitsPerCharacter = 5
        setBitSampling(fromBaudRate: 45.45)

        //  note: stopBit must be < 500
        invert = false
        offset = 256

        setEqualize(0)
        memset(inputData, 0, MemoryLayout<CMATCPair>.size * 768)
        for i in 0..<3 {
            memset(agcData(i), 0, MemoryLayout<CMATCPair>.size * 768)
            (agc + i).pointee.markAGC = 0
            (agc + i).pointee.spaceAGC = 0
        }
        //  alpha^n = 1/2.71828, where n is in steps of Fs/8
        let g = 8.0 / CMFs
        (agc + 0).pointee.attack = Float(exp(-g / 0.0005))      //  0.5 ms attack
        (agc + 0).pointee.decay  = Float(exp(-g / 0.120))       //  120 ms decay
        (agc + 1).pointee.attack = Float(exp(-g / 0.001))       //  1 ms attack
        (agc + 1).pointee.decay  = Float(exp(-g / 0.200))       //  200 ms decay
        (agc + 2).pointee.attack = Float(exp(-g / 0.002))       //  2 ms attack
        (agc + 2).pointee.decay  = Float(exp(-g / 0.600))       //  600 ms decay

        (atcCase + 0).pointee.startingIndex = 0; (atcCase + 0).pointee.endingIndex = 1; (atcCase + 0).pointee.eq = 0
        (atcCase + 1).pointee.startingIndex = 1; (atcCase + 1).pointee.endingIndex = 2; (atcCase + 1).pointee.eq = 0
        (atcCase + 2).pointee.startingIndex = 0; (atcCase + 2).pointee.endingIndex = 1; (atcCase + 2).pointee.eq = 1
        (atcCase + 3).pointee.startingIndex = 1; (atcCase + 3).pointee.endingIndex = 2; (atcCase + 3).pointee.eq = -1
        (atcCase + 4).pointee.startingIndex = 0; (atcCase + 4).pointee.endingIndex = 1; (atcCase + 4).pointee.eq = 2
        (atcCase + 5).pointee.startingIndex = 1; (atcCase + 5).pointee.endingIndex = 2; (atcCase + 5).pointee.eq = -2
        atcBuffer = CMATCBuffer()
    }

    deinit {
        input.deallocate()
        agcBase.deallocate()
        atcCase.deallocate()
        bitStreamPtr.deallocate()
        syncedData.deallocate()
    }

    @objc(atcWaveformBuffer)
    func atcWaveformBuffer() -> CMPipe! {
        return atcBuffer
    }

    @objc(setBitsPerCharacter:)
    func setBitsPerCharacter(_ bits: Int32) {
        var b = bits
        if b < 4 { b = 4 } else if b > 8 { b = 8 }
        bitsPerCharacter = b
    }

    @objc(setBitSamplingFromBaudRate:)
    func setBitSampling(fromBaudRate baudrate: Float) {
        bitStreamPtr.pointee.samplingRate = baudrate

        bitTime = Float(CMFs / Double(baudrate * 8))
        bitn = Int32(bitTime)
        startBit = Int32(bitTime * 0.5)                             // mid of start bit
        stopBit = Int32(bitTime * Float(bitsPerCharacter + 2))      // mid of stop bit (1.5 stop bits)
        characterAdvance = Int32(bitTime * Float(bitsPerCharacter + 2) - 6)   // v0.83

        //  compute for up to 8 bit case
        for i in 0..<10 {
            bitPos[i] = Int32((Double(i) + 1.5) * Double(bitTime))
            transitionPos[i] = Int32((Double(i) + 1.0) * Double(bitTime))
        }
    }

    @objc(setEqualize:)
    func setEqualize(_ mode: Int32) {
        switch mode {
        case 1:
            equalizerQuanta = Int32((0.006 * CMFs) / 8)     // 6 msec
        case 2:
            equalizerQuanta = Int32((0.008 * CMFs) / 8)     // 8 msec
        default:
            equalizerQuanta = Int32((0.004 * CMFs) / 8)     // 4 msec
        }
    }

    @objc(setInvert:)
    func setInvert(_ isInvert: DarwinBoolean) {
        invert = isInvert.boolValue
    }

    @objc(setSquelch:)
    func setSquelch(_ value: Float) {
        //  squelch threshold (value = 0.0 == maximal squelching)
        squelch = 1.0 - value
    }

    /* local */
    //  output N-bit character for each decoded character, and also the bitsynced waveform
    @objc(exportCharacter:buffer:)
    func exportCharacter(_ ch: Int32, buffer pair: UnsafeMutablePointer<CMATCPair>) {
        bitStreamPtr.pointee.userData = Int(ch)

        //  copy synced waveform and normalize
        var norm: Float = 0.01
        for i in 0..<256 {
            let v = pair[i].mark - pair[i].space
            syncedData[i] = v
            let av = abs(v)
            if av > norm { norm = av }
        }
        norm = 0.5 / norm
        vDSP_vsmul(syncedData, 1, &norm, syncedData, 1, 256)

        exportData()
    }

    //  decode the characters, applying a common shift and a differential shift (equalizer)
    @objc(decodeCharacterFrom:eq:into:)
    func decodeCharacterFrom(_ pair: UnsafeMutablePointer<CMATCPair>, eq: Int32, into decode: UnsafeMutablePointer<Int32>) {
        for i in 0..<Int(bitsPerCharacter) {
            let index = Int(bitPos[i])
            let p = pair[index]
            let q = pair[index + Int(eq)]
            if p.mark > 0 && q.space < 0 { decode[i] += 1 }
            else if p.mark < 0 && q.space > 0 { decode[i] -= 1 }
            decode[i] += (p.mark > q.space) ? 1 : -1
        }
    }

    @objc(scanForBadTransitions:)
    func scanForBadTransitions(_ s0: UnsafeMutablePointer<CMATCPair>) -> Int32 {
        var s = s0 + 16
        var count: Int32 = 0
        var start = startBitMatch(s, startBit, 0); s += 1
        for i in 0..<Int(stopBit - startBit) {
            let prevStart = start
            start = startBitMatch(s, startBit, 0); s += 1
            if (prevStart > 0 && start < 0) || (prevStart < 0 && start > 0) {
                var v = Float(i - 16) / bitTime
                let k = Int(v + 0.5)
                v = v - Float(k)
                if v < -0.35 || v > 0.35 { count += 1 }
            }
        }
        return count
    }

    @objc(checkForCharacter)
    func checkForCharacter() {
        var bits = [Int32](repeating: 0, count: 8)

        offset -= 256
        if offset > 384 { return }

        while true {
            var ref = agcData(0) + Int(offset - 1)
            var edge = startBitMatch(ref, startBit, 0)
            //  scan for start bit in the first AGC stream
            var i = Int(offset)
            while i < 280 {
                ref = agcData(0) + i
                let prevEdge = edge
                edge = startBitMatch(ref, startBit, 0)

                if prevEdge > 0 && edge <= 0 {
                    //  try only if there are not too many (noisy) transitions
                    if transitions(ref, bitn, bitsPerCharacter) < 4 {
                        //  conservative check on the stop bit
                        if ref[Int(stopBit)].mark > 0 || ref[Int(stopBit)].space < 0 {

                            var atc = [UnsafeMutablePointer<CMATCPair>](repeating: ref, count: 3)
                            atc[0] = ref
                            atc[1] = agcData(1) + i
                            atc[2] = agcData(2) + i

                            let startIndex = i
                            var weight: Int32 = 0

                            for n in 0..<6 {
                                let a = atcCase + n
                                let abits = caseBits(n)
                                for k in 0..<Int(bitsPerCharacter) { abits[k] = 0 }
                                for k in Int(a.pointee.startingIndex)...Int(a.pointee.endingIndex) {
                                    decodeCharacterFrom(atc[k], eq: a.pointee.eq * equalizerQuanta, into: abits)
                                }
                                a.pointee.weight = bitWeight(abits, bitsPerCharacter)
                                if a.pointee.weight > weight { weight = a.pointee.weight }
                            }

                            //  create final bit accumulators from the "best" decodings
                            for k in 0..<Int(bitsPerCharacter) { bits[k] = 0 }
                            for n in 0..<6 {
                                let abits = caseBits(n)
                                for k in 0..<Int(bitsPerCharacter) { bits[k] += abits[k] }
                            }

                            //  find character to print from the different set ups
                            let result = bits.withUnsafeMutableBufferPointer { threshold($0.baseAddress!, bitsPerCharacter) }
                            //  find how many cases agree
                            var agree: Int32 = 0
                            for n in 0..<6 {
                                if (result ^ threshold(caseBits(n), bitsPerCharacter)) == 0 { agree += 1 }
                            }
                            if result > 0 {
                                if Float(weight) >= (16 * squelch) && (Float(agree) > 5 * squelch) {
                                    let noiseThreshold = Int32(Double(scanForBadTransitions(agcData(0) + i)) * (4.0 / Double(bitsPerCharacter)))
                                    if Double(noiseThreshold) <= (1.05 - Double(squelch)) * 8 {
                                        exportCharacter(result, buffer: ref)
                                    }
                                }
                                i = startIndex + Int(characterAdvance)
                            } else {
                                i += Int(bitn)
                            }
                            break
                        }
                    }
                }
                i += 1
            }
            offset = Int32(i)
            if offset >= 280 { return }
        }
    }

    //  NOTE: sampling rate here is Fs/8 (about 1378 s/s), 256 samples per frame.
    //  new data is stuffed into the end of a 768-sample delay line
    override func importData(_ pipe: CMPipe!) {
        let stream = pipe.stream()
        bitStreamPtr.pointee.sourceID = stream!.pointee.sourceID
        var samples = Int(stream!.pointee.samples)
        if samples > 256 { samples = 256 }

        //  invert M/S polarity here.
        var m: UnsafeMutablePointer<Float>
        var s: UnsafeMutablePointer<Float>
        if invert {
            s = stream!.pointee.array!
            m = stream!.pointee.array! + samples
        } else {
            m = stream!.pointee.array!
            s = stream!.pointee.array! + samples
        }

        //  copy input data into tail of buffer (split complex -> ATCpair)
        var p = inputData + 512
        for _ in 0..<256 {
            p.pointee.mark = m.pointee; m += 1
            p.pointee.space = s.pointee; s += 1
            p += 1
        }

        //  AGC streams
        updateAGC(input, agc + 0)
        updateAGC(input, agc + 1)
        updateAGC(input, agc + 2)

        checkForCharacter()

        (atcBuffer as? CMATCBuffer)?.atcData(agc + 2)

        //  move tail to head of buffers
        let size = MemoryLayout<CMATCPair>.size * 512
        memcpy(inputData, inputData + 256, size)
        for i in 0..<3 { memcpy(agcData(i), agcData(i) + 256, size) }
    }

    //  computed AGC compensated data (look ahead 22ms)
    internal func updateAGC(_ inp: UnsafeMutablePointer<CMATCStream>, _ out: UnsafeMutablePointer<CMATCStream>) {
        let att = out.pointee.attack
        let dec = out.pointee.decay

        var din = dataPtr(inp) + (384 + 100)
        var dout = dataPtr(out) + (384 - 1)
        var m = out.pointee.markAGC
        var s = out.pointee.spaceAGC
        dout += 1
        for _ in 384..<(384 + 256) {
            var v = din.pointee.mark
            m = ((v > m) ? att : dec) * (m - v) + v
            dout.pointee.mark = v - m * 0.5
            v = din.pointee.space
            s = ((v > s) ? att : dec) * (s - v) + v
            dout.pointee.space = v - s * 0.5
            din += 1
            dout += 1
        }
        out.pointee.markAGC = m
        out.pointee.spaceAGC = s
    }
}

//  ---- file-static helpers (matched the C statics in CMATC.m) ----

//  find extra transitions in start and N (default 5) data bits
private func transitions(_ pair0: UnsafeMutablePointer<CMATCPair>, _ bitn: Int32, _ bitsPerCharacter: Int32) -> Int32 {
    var pair = pair0 + 8
    let n = Int(bitn) - 16
    var count: Int32 = 0

    for _ in 0..<Int(bitsPerCharacter + 1) {
        var p = pair
        var u = p.pointee.mark - p.pointee.space
        for _ in 0..<n {
            p += 1
            let v = p.pointee.mark - p.pointee.space
            if (u > 0 && v <= 0) || (u < 0 && v >= 0) { count += 1 }
            u = v
        }
        pair += Int(bitn)
    }
    return count
}

//  threshold each bit and return N-bit code
private func threshold(_ bits: UnsafeMutablePointer<Int32>, _ bitsPerCharacter: Int32) -> Int32 {
    var result: Int32 = 0
    var i = Int(bitsPerCharacter) - 1
    while i >= 0 {
        result *= 2
        if bits[i] > 0 { result += 1 }
        i -= 1
    }
    return result
}

private func bitWeight(_ bits: UnsafeMutablePointer<Int32>, _ bitsPerCharacter: Int32) -> Int32 {
    var result: Int32 = 0
    for i in 0..<Int(bitsPerCharacter) { result += abs(bits[i]) }
    return result
}

//  matched filter estimate of a stop/start bit transition (abs(t-t0) match)
private func startBitMatch(_ p: UnsafeMutablePointer<CMATCPair>, _ halfBit: Int32, _ eq: Int32) -> Float {
    var u: Float = 0
    let q = p - 1
    let s = p + Int(eq)
    let t = s - 1
    let base = p.pointee.mark + -(s.pointee.space) + q.pointee.mark - t.pointee.space
    for i in 0..<Int(halfBit) {
        u += Float(i) * base
    }
    return u
}
