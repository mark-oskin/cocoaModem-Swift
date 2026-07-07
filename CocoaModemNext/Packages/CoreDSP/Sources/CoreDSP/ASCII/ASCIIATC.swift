//
//  ASCIIATC.swift
//  CoreDSP
//
//  Multiple Automatic Threshold Correction (bit synchronizer + async
//  start/stop-bit framer).  This is the decode-critical heart of the ASCII
//  demodulator: it AGC-compensates the mark/space matched-filter output at
//  three time constants, scans for start-bit transitions, decodes each
//  candidate character six different ways (two sample offsets x three
//  equalizer hypotheses), and majority-votes the result.  Faithful transplant
//  of CMATC's algorithm
//  (Sources/Swift/Modems/CoreModem/FSK/CMATC.swift), patterned after Marvin
//  Frerking, "Digital Signal Processing in Communication Systems," Chapman &
//  Hall 1993.
//
//  The original C bridged three fixed-size structs through a header
//  (CMATCTypes.h: CMATCPair/CMATCStream/CMATCCase) and exploited "CMATCStream's
//  data[] array is its first field" pointer-aliasing to reinterpret a
//  CMATCStream* as a CMATCPair*.  That trick only existed for C-struct-layout
//  reasons; here the same three AGC streams (each 768 ASCIIATCPair samples
//  plus its own attack/decay/markAGC/spaceAGC) are just parallel Swift arrays
//  -- same math, no raw-pointer-layout aliasing.
//

import Foundation
import Accelerate

final class ASCIIATC: CMTappedPipe {

    //  ---- bit-synced output stream (one decoded N-bit code per detected character) ----
    private let bitStreamPtr: UnsafeMutablePointer<CMDataStream> = {
        let p = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        p.initialize(to: CMDataStream())
        return p
    }()
    private let syncedData = UnsafeMutablePointer<Float>.allocate(capacity: 256)

    private var bitTime: Float = 0
    private var startBitOffset: Int32 = 0
    private var stopBitOffset: Int32 = 0
    private var characterAdvance: Int32 = 0
    private var bitn: Int32 = 0
    //  bit position and transition position, in samples at Fs/8
    private var bitPos = [Int32](repeating: 0, count: 10)
    private var transitionPos = [Int32](repeating: 0, count: 10)
    private var offset: Int32 = 256
    private(set) var bitsPerCharacter: Int32 = 7
    var invert: Bool = false
    private var currentBaudRate: Float = 110.0

    //  ---- three AGC-compensated views of the same input, each 768 samples ----
    private let input: UnsafeMutablePointer<ASCIIATCPair> = {
        let p = UnsafeMutablePointer<ASCIIATCPair>.allocate(capacity: 768)
        p.initialize(repeating: ASCIIATCPair(), count: 768)
        return p
    }()
    private let agc: [UnsafeMutablePointer<ASCIIATCPair>] = (0..<3).map { _ in
        let p = UnsafeMutablePointer<ASCIIATCPair>.allocate(capacity: 768)
        p.initialize(repeating: ASCIIATCPair(), count: 768)
        return p
    }
    private var agcAttack: [Float] = [0, 0, 0]
    private var agcDecay: [Float] = [0, 0, 0]
    private var agcMarkAGC: [Float] = [0, 0, 0]
    private var agcSpaceAGC: [Float] = [0, 0, 0]

    private struct ATCCase {
        var startingIndex: Int32
        var endingIndex: Int32
        var eq: Int32
        var bits = [Int32](repeating: 0, count: 8)
        var weight: Int32 = 0
    }
    private var atcCase: [ATCCase] = []

    //  multi-ATC params
    private var equalizerQuanta: Int32 = 0
    private var squelch: Float = 0

    override init() {
        super.init()
        data = bitStreamPtr
        bitStreamPtr.pointee.array = syncedData
        bitStreamPtr.pointee.samples = 256
        bitStreamPtr.pointee.components = 1
        bitStreamPtr.pointee.channels = 1

        bitsPerCharacter = 7
        setBitSampling(baudRate: 110.0)

        invert = false
        offset = 256
        setEqualize(0)

        //  alpha^n = 1/2.71828, where n is in steps of Fs/8
        let g = 8.0 / kCMFs
        agcAttack[0] = Float(exp(-g / 0.0005)); agcDecay[0] = Float(exp(-g / 0.120))    // 0.5 ms attack / 120 ms decay
        agcAttack[1] = Float(exp(-g / 0.001));  agcDecay[1] = Float(exp(-g / 0.200))    // 1 ms attack / 200 ms decay
        agcAttack[2] = Float(exp(-g / 0.002));  agcDecay[2] = Float(exp(-g / 0.600))    // 2 ms attack / 600 ms decay

        atcCase = [
            ATCCase(startingIndex: 0, endingIndex: 1, eq: 0),
            ATCCase(startingIndex: 1, endingIndex: 2, eq: 0),
            ATCCase(startingIndex: 0, endingIndex: 1, eq: 1),
            ATCCase(startingIndex: 1, endingIndex: 2, eq: -1),
            ATCCase(startingIndex: 0, endingIndex: 1, eq: 2),
            ATCCase(startingIndex: 1, endingIndex: 2, eq: -2),
        ]
    }

    deinit {
        input.deallocate()
        agc.forEach { $0.deallocate() }
        bitStreamPtr.deallocate()
        syncedData.deallocate()
    }

    // MARK: - Configuration

    func setBitsPerCharacter(_ bits: Int32) {
        var b = bits
        if b < 4 { b = 4 } else if b > 8 { b = 8 }
        bitsPerCharacter = b
        setBitSampling(baudRate: currentBaudRate)
    }

    func setBitSampling(baudRate: Float) {
        currentBaudRate = baudRate
        bitStreamPtr.pointee.samplingRate = baudRate

        bitTime = Float(kCMFs / Double(baudRate * 8))
        bitn = Int32(bitTime)
        startBitOffset = Int32(bitTime * 0.5)                              // mid of start bit
        stopBitOffset = Int32(bitTime * Float(bitsPerCharacter + 2))       // mid of stop bit (1.5 stop bits)
        characterAdvance = Int32(bitTime * Float(bitsPerCharacter + 2) - 6)

        for i in 0..<10 {
            bitPos[i] = Int32((Double(i) + 1.5) * Double(bitTime))
            transitionPos[i] = Int32((Double(i) + 1.0) * Double(bitTime))
        }
    }

    func setEqualize(_ mode: Int32) {
        switch mode {
        case 1: equalizerQuanta = Int32((0.006 * kCMFs) / 8)     // 6 msec
        case 2: equalizerQuanta = Int32((0.008 * kCMFs) / 8)     // 8 msec
        default: equalizerQuanta = Int32((0.004 * kCMFs) / 8)    // 4 msec
        }
    }

    func setInvert(_ isInvert: Bool) {
        invert = isInvert
    }

    func setSquelch(_ value: Float) {
        //  squelch threshold (value = 0.0 == maximal squelching)
        squelch = 1.0 - value
    }

    // MARK: - Decode-critical algorithm

    //  output N-bit character for each decoded character, and also the bit-synced waveform
    private func exportCharacter(_ ch: Int32, buffer pair: UnsafeMutablePointer<ASCIIATCPair>) {
        bitStreamPtr.pointee.userData = Int(ch)

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
    private func decodeCharacterFrom(_ pair: UnsafeMutablePointer<ASCIIATCPair>, eq: Int32, into decode: inout [Int32]) {
        for i in 0..<Int(bitsPerCharacter) {
            let index = Int(bitPos[i])
            let p = pair[index]
            let q = pair[index + Int(eq)]
            if p.mark > 0 && q.space < 0 { decode[i] += 1 }
            else if p.mark < 0 && q.space > 0 { decode[i] -= 1 }
            decode[i] += (p.mark > q.space) ? 1 : -1
        }
    }

    private func scanForBadTransitions(_ s0: UnsafeMutablePointer<ASCIIATCPair>) -> Int32 {
        var s = s0 + 16
        var count: Int32 = 0
        var start = startBitMatch(s, startBitOffset, 0); s += 1
        for i in 0..<Int(stopBitOffset - startBitOffset) {
            let prevStart = start
            start = startBitMatch(s, startBitOffset, 0); s += 1
            if (prevStart > 0 && start < 0) || (prevStart < 0 && start > 0) {
                var v = Float(i - 16) / bitTime
                let k = Int(v + 0.5)
                v = v - Float(k)
                if v < -0.35 || v > 0.35 { count += 1 }
            }
        }
        return count
    }

    private func checkForCharacter() {
        var bits = [Int32](repeating: 0, count: 8)

        offset -= 256
        if offset > 384 { return }

        while true {
            var ref = agc[0] + Int(offset - 1)
            var edge = startBitMatch(ref, startBitOffset, 0)
            var i = Int(offset)
            while i < 280 {
                ref = agc[0] + i
                let prevEdge = edge
                edge = startBitMatch(ref, startBitOffset, 0)

                if prevEdge > 0 && edge <= 0 {
                    //  try only if there are not too many (noisy) transitions
                    if transitions(ref, bitn, bitsPerCharacter) < 4 {
                        //  conservative check on the stop bit
                        if ref[Int(stopBitOffset)].mark > 0 || ref[Int(stopBitOffset)].space < 0 {

                            let atc = [ref, agc[1] + i, agc[2] + i]
                            let startIndex = i
                            var weight: Int32 = 0

                            for n in 0..<6 {
                                var localBits = [Int32](repeating: 0, count: 8)
                                for k in Int(atcCase[n].startingIndex)...Int(atcCase[n].endingIndex) {
                                    decodeCharacterFrom(atc[k], eq: atcCase[n].eq * equalizerQuanta, into: &localBits)
                                }
                                atcCase[n].bits = localBits
                                atcCase[n].weight = bitWeight(localBits, bitsPerCharacter)
                                if atcCase[n].weight > weight { weight = atcCase[n].weight }
                            }

                            //  create final bit accumulators from the "best" decodings
                            for k in 0..<Int(bitsPerCharacter) { bits[k] = 0 }
                            for n in 0..<6 {
                                for k in 0..<Int(bitsPerCharacter) { bits[k] += atcCase[n].bits[k] }
                            }

                            //  find character to print from the different set ups
                            let result = threshold(bits, bitsPerCharacter)
                            //  find how many cases agree
                            var agree: Int32 = 0
                            for n in 0..<6 {
                                if (result ^ threshold(atcCase[n].bits, bitsPerCharacter)) == 0 { agree += 1 }
                            }
                            if result > 0 {
                                if Float(weight) >= (16 * squelch) && (Float(agree) > 5 * squelch) {
                                    let noiseThreshold = Int32(Double(scanForBadTransitions(agc[0] + i)) * (4.0 / Double(bitsPerCharacter)))
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
    //  new data is stuffed into the end of a 768-sample delay line.
    override func importData(_ pipe: CMPipe!) {
        guard let stream = pipe.stream(), let arr = stream.pointee.array else { return }
        bitStreamPtr.pointee.sourceID = stream.pointee.sourceID
        var samples = Int(stream.pointee.samples)
        if samples > 256 { samples = 256 }

        //  invert M/S polarity here.
        var m: UnsafeMutablePointer<Float>
        var s: UnsafeMutablePointer<Float>
        if invert {
            s = arr
            m = arr + samples
        } else {
            m = arr
            s = arr + samples
        }

        //  copy input data into tail of buffer
        var p = input + 512
        for _ in 0..<256 {
            p.pointee.mark = m.pointee; m += 1
            p.pointee.space = s.pointee; s += 1
            p += 1
        }

        updateAGC(0)
        updateAGC(1)
        updateAGC(2)

        checkForCharacter()

        //  move tail to head of buffers
        let size = MemoryLayout<ASCIIATCPair>.size * 512
        memcpy(input, input + 256, size)
        for i in 0..<3 { memcpy(agc[i], agc[i] + 256, size) }
    }

    //  computed AGC-compensated data (look ahead 22ms)
    private func updateAGC(_ idx: Int) {
        let att = agcAttack[idx]
        let dec = agcDecay[idx]
        let out = agc[idx]

        var din = input + (384 + 100)
        var dout = out + (384 - 1)
        var m = agcMarkAGC[idx]
        var s = agcSpaceAGC[idx]
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
        agcMarkAGC[idx] = m
        agcSpaceAGC[idx] = s
    }
}

//  ---- file-scope helpers (matched the C statics in CMATC.m) ----

//  find extra transitions in start and N (default 5) data bits
//  NOTE: the C original was `for (i = 0; i < n; i++)`, which silently does
//  nothing when n <= 0; at high baud rates (e.g. ASCII's 110 baud, vs RTTY's
//  45.45) bitn can drop below 16 in this Fs/8-decimated domain, making n
//  negative. Swift's `0..<n` Range traps on a negative bound where C's loop
//  would not, so this is guarded exactly like CMNCO's own cmPhaseTrunc guards
//  elsewhere in this codebase (preserve the semantics, not the trap).
private func transitions(_ pair0: UnsafeMutablePointer<ASCIIATCPair>, _ bitn: Int32, _ bitsPerCharacter: Int32) -> Int32 {
    var pair = pair0 + 8
    let n = Int(bitn) - 16
    var count: Int32 = 0

    for _ in 0..<Int(bitsPerCharacter + 1) {
        var p = pair
        var u = p.pointee.mark - p.pointee.space
        if n > 0 {
        for _ in 0..<n {
            p += 1
            let v = p.pointee.mark - p.pointee.space
            if (u > 0 && v <= 0) || (u < 0 && v >= 0) { count += 1 }
            u = v
        }
        }
        pair += Int(bitn)
    }
    return count
}

//  threshold each bit and return N-bit code
private func threshold(_ bits: [Int32], _ bitsPerCharacter: Int32) -> Int32 {
    var result: Int32 = 0
    var i = Int(bitsPerCharacter) - 1
    while i >= 0 {
        result *= 2
        if bits[i] > 0 { result += 1 }
        i -= 1
    }
    return result
}

private func bitWeight(_ bits: [Int32], _ bitsPerCharacter: Int32) -> Int32 {
    var result: Int32 = 0
    for i in 0..<Int(bitsPerCharacter) { result += abs(bits[i]) }
    return result
}

//  matched filter estimate of a stop/start bit transition (abs(t-t0) match)
private func startBitMatch(_ p: UnsafeMutablePointer<ASCIIATCPair>, _ halfBit: Int32, _ eq: Int32) -> Float {
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
