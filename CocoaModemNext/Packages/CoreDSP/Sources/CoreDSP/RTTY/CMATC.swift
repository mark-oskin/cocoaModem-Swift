//
//  CMATC.swift
//  CoreDSP
//
//  Multiple Automatic Threshold Correction -- the character/bit-sync decode
//  stage of the RTTY receive chain. Patterned after Marvin Frerking, "Digital
//  Signal Processing in Communication Systems," Chapman & Hall 1993,
//  ISBN 0-442-01616-6.
//
//  Decode-critical: this is a faithful transplant of the arithmetic (AGC
//  attack/decay time constants, the 6-case equalizer search in
//  checkForCharacter, the bit-position/transition-position tables, the
//  start/stop-bit matched-filter estimate). What changed vs. the old app's own
//  Swift port (Sources/Swift/Modems/CoreModem/FSK/CMATC.swift) is *only* the
//  storage representation: the original re-used raw C structs (CMATCStream
//  with an embedded `data[768]` array, addressed via `dataPtr`/`agcData`
//  pointer-cast helpers that relied on `data` being the first struct field) --
//  a bridging-header trick with no equivalent need in pure Swift. Here each
//  AGC stream is a small class (CMATCStreamBox) owning its own 768-slot
//  CMATCPair buffer directly, so `agcData(i)` is simply `agc[i].data`. Every
//  number crunched is identical; only the pointer plumbing got simpler.
//
//  Dropped relative to the original: the scope-tap "atcBuffer" (CMATCBuffer)
//  wiring -- a waveform-display helper untouched by the decode path -- and the
//  NSSound bell beep (no audio-alert concept in this headless module).
//

import Foundation
import Accelerate

/// One 768-sample sliding buffer of mark/space amplitude pairs, plus the AGC
/// attack/decay state associated with it (was `CMATCStream` in CMATCTypes.h).
final class CMATCStreamBox {
    let data: UnsafeMutablePointer<CMATCPair>
    var attack: Float = 0
    var decay: Float = 0
    var markAGC: Float = 0
    var spaceAGC: Float = 0

    init(capacity: Int = 768) {
        data = UnsafeMutablePointer<CMATCPair>.allocate(capacity: capacity)
        data.initialize(repeating: CMATCPair(), count: capacity)
    }

    deinit { data.deallocate() }
}

final class CMATC: CMTappedPipe {

    let syncedData = UnsafeMutablePointer<Float>.allocate(capacity: 256)

    var bitTime: Float = 0
    var startBit: Int32 = 0
    var stopBit: Int32 = 0
    var characterAdvance: Int32 = 0
    var bitn: Int32 = 0
    //  bit position and transition position in samples (Fs/8)
    var bitPos = [Int32](repeating: 0, count: 10)
    var transitionPos = [Int32](repeating: 0, count: 10)
    var offset: Int32 = 0
    var bitsPerCharacter: Int32 = 0
    var invert: Bool = false

    let input = CMATCStreamBox()          //  input data
    let agc = [CMATCStreamBox(), CMATCStreamBox(), CMATCStreamBox()]
    var atcCase = [CMATCCase](repeating: CMATCCase(), count: 6)

    //  multi-ATC params
    var equalizerQuanta: Int32 = 0
    var squelch: Float = 0

    override init() {
        super.init()

        bitsPerCharacter = 5
        setBitSampling(fromBaudRate: 45.45)

        //  note: stopBit must be < 500
        invert = false
        offset = 256

        setEqualize(0)

        data.pointee.array = syncedData
        data.pointee.samples = 256
        data.pointee.components = 1
        data.pointee.channels = 1

        //  alpha^n = 1/2.71828, where n is in steps of Fs/8
        let g = 8.0 / CMFs
        agc[0].attack = Float(exp(-g / 0.0005))      //  0.5 ms attack
        agc[0].decay  = Float(exp(-g / 0.120))       //  120 ms decay
        agc[1].attack = Float(exp(-g / 0.001))       //  1 ms attack
        agc[1].decay  = Float(exp(-g / 0.200))       //  200 ms decay
        agc[2].attack = Float(exp(-g / 0.002))       //  2 ms attack
        agc[2].decay  = Float(exp(-g / 0.600))       //  600 ms decay

        atcCase[0] = CMATCCase(startingIndex: 0, endingIndex: 1, eq: 0)
        atcCase[1] = CMATCCase(startingIndex: 1, endingIndex: 2, eq: 0)
        atcCase[2] = CMATCCase(startingIndex: 0, endingIndex: 1, eq: 1)
        atcCase[3] = CMATCCase(startingIndex: 1, endingIndex: 2, eq: -1)
        atcCase[4] = CMATCCase(startingIndex: 0, endingIndex: 1, eq: 2)
        atcCase[5] = CMATCCase(startingIndex: 1, endingIndex: 2, eq: -2)
    }

    deinit {
        syncedData.deallocate()
    }

    func setBitsPerCharacter(_ bits: Int32) {
        var b = bits
        if b < 4 { b = 4 } else if b > 8 { b = 8 }
        bitsPerCharacter = b
    }

    func setBitSampling(fromBaudRate baudrate: Float) {
        data.pointee.samplingRate = baudrate

        bitTime = Float(CMFs / Double(baudrate * 8))
        bitn = Int32(bitTime)
        startBit = Int32(bitTime * 0.5)                             // mid of start bit
        stopBit = Int32(bitTime * Float(bitsPerCharacter + 2))      // mid of stop bit (1.5 stop bits)
        characterAdvance = Int32(bitTime * Float(bitsPerCharacter + 2) - 6)

        //  compute for up to 8 bit case
        for i in 0..<10 {
            bitPos[i] = Int32((Double(i) + 1.5) * Double(bitTime))
            transitionPos[i] = Int32((Double(i) + 1.0) * Double(bitTime))
        }
    }

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

    func setInvert(_ isInvert: Bool) {
        invert = isInvert
    }

    func setSquelch(_ value: Float) {
        //  squelch threshold (value = 0.0 == maximal squelching)
        squelch = 1.0 - value
    }

    /* local */
    //  output N-bit character for each decoded character, and also the bitsynced waveform
    func exportCharacter(_ ch: Int32, buffer pair: UnsafeMutablePointer<CMATCPair>) {
        data.pointee.userData = Int(ch)

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
    func decodeCharacterFrom(_ pair: UnsafeMutablePointer<CMATCPair>, eq: Int32, into decode: inout [Int32]) {
        for i in 0..<Int(bitsPerCharacter) {
            let index = Int(bitPos[i])
            let p = pair[index]
            let q = pair[index + Int(eq)]
            if p.mark > 0 && q.space < 0 { decode[i] += 1 }
            else if p.mark < 0 && q.space > 0 { decode[i] -= 1 }
            decode[i] += (p.mark > q.space) ? 1 : -1
        }
    }

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

    func checkForCharacter() {
        var bits = [Int32](repeating: 0, count: 8)

        offset -= 256
        if offset > 384 { return }

        while true {
            var ref = agc[0].data + Int(offset - 1)
            var edge = startBitMatch(ref, startBit, 0)
            //  scan for start bit in the first AGC stream
            var i = Int(offset)
            while i < 280 {
                ref = agc[0].data + i
                let prevEdge = edge
                edge = startBitMatch(ref, startBit, 0)

                if prevEdge > 0 && edge <= 0 {
                    //  try only if there are not too many (noisy) transitions
                    if transitions(ref, bitn, bitsPerCharacter) < 4 {
                        //  conservative check on the stop bit
                        if ref[Int(stopBit)].mark > 0 || ref[Int(stopBit)].space < 0 {

                            let atc: [UnsafeMutablePointer<CMATCPair>] = [ref, agc[1].data + i, agc[2].data + i]

                            let startIndex = i
                            var weight: Int32 = 0

                            for n in 0..<6 {
                                let a = atcCase[n]
                                for k in 0..<Int(bitsPerCharacter) { atcCase[n].bits[k] = 0 }
                                for k in Int(a.startingIndex)...Int(a.endingIndex) {
                                    decodeCharacterFrom(atc[k], eq: a.eq * equalizerQuanta, into: &atcCase[n].bits)
                                }
                                atcCase[n].weight = bitWeight(atcCase[n].bits, bitsPerCharacter)
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
                                    let noiseThreshold = Int32(Double(scanForBadTransitions(agc[0].data + i)) * (4.0 / Double(bitsPerCharacter)))
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
        data.pointee.sourceID = stream!.pointee.sourceID
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
        var p = input.data + 512
        for _ in 0..<256 {
            p.pointee.mark = m.pointee; m += 1
            p.pointee.space = s.pointee; s += 1
            p += 1
        }

        //  AGC streams
        updateAGC(input, agc[0])
        updateAGC(input, agc[1])
        updateAGC(input, agc[2])

        checkForCharacter()

        //  move tail to head of buffers
        let size = MemoryLayout<CMATCPair>.size * 512
        memcpy(input.data, input.data + 256, size)
        for i in 0..<3 { memcpy(agc[i].data, agc[i].data + 256, size) }
    }

    //  computed AGC compensated data (look ahead 22ms)
    func updateAGC(_ inp: CMATCStreamBox, _ out: CMATCStreamBox) {
        let att = out.attack
        let dec = out.decay

        var din = inp.data + (384 + 100)
        var dout = out.data + (384 - 1)
        var m = out.markAGC
        var s = out.spaceAGC
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
        out.markAGC = m
        out.spaceAGC = s
    }
}

//  ---- file-private helpers (matched the C statics in CMATC.m) ----

//  find extra transitions in start and N (default 5) data bits
//  At higher baud rates (this codebase also has an ASCII mode sharing this same
//  algorithm at ~110 baud vs RTTY's 45.45) bitn can drop below 16 in this
//  Fs/8-decimated domain, making n negative. Swift's `0..<n` Range traps on a
//  negative bound where C's loop would not, so this is guarded exactly like
//  CMNCO's own cmPhaseTrunc guards elsewhere in this codebase (preserve the
//  semantics, not the trap) -- see ASCIIATC.swift's identical fix.
private func transitions(_ pair0: UnsafeMutablePointer<CMATCPair>, _ bitn: Int32, _ bitsPerCharacter: Int32) -> Int32 {
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
