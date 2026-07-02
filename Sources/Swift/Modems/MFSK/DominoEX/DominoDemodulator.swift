//
//  DominoDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 6/23/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of DominoDemodulator.m.
//

import Cocoa
import Accelerate

//  SubBin was a C struct in DominoDemodulator.h.  It is used only inside the
//  Swift demodulator tree (DominoDemodulator / DominoHalfRateDemodulator), so it
//  is a Swift value type here.  subbin[] is held in an UnsafeMutablePointer so a
//  SubBin* can be passed around exactly as the C did.
struct SubBin {
    var bin = [Int16](repeating: 0, count: 8)       //  max bin index (0-31) for each of the 16 sub-bins
    var code = [Int16](repeating: 0, count: 8)       //  IFSK decoded (iFSKDecodeVector[current][mostRecent])
    var notDecoded: Bool = false
    var mostRecentBin: Int32 = 0                      //  most recent bin without regard to Varicode boundary
    var nextRecentBin: Int32 = 0                      //  next most recent bin without regard to Varicode boundary
    var energy: Float = 0                             //  accumulated energy
    var index: Int32 = 0
    var terminatingCode: Int32 = 0
}

//  note: 256 is error code
private let secondaryFECDecodeTable: [Int32] = [
    //          0    1    2    3    4    5    6    7    8    9
    /*  0 */    0,   32,  33,  34,  95,  36,  37,  38,  0,   39,
    /*  1 */    0,   41,  42,  40,  48,  49,  50,  51,  52,  53,   //  note flip of /r and /n
    /*  2 */    0,   0,   0,   0,   43,  44,  45,  46,  47,  58,
    /*  3 */    59,  60,  0,   0,   0,   0,   0,   0,   0,   0,
    /*  4 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /*  5 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /*  6 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /*  7 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /*  8 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /*  9 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 10 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 11 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 12 */    0,   0,   0,   0,   0,   0,   0,   65,  66,  67,
    /* 13 */    68,  69,  70,  71,  72,  73,  74,  75,  76,  77,
    /* 14 */    78,  79,  80,  81,  82,  83,  84,  85,  86,  87,
    /* 15 */    88,  89,  90,  61,  62,  63,  64,  91,  92,  93,
    /* 16 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 17 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 18 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 19 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 20 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 21 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 22 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 23 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 24 */    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    /* 25 */    0,   0,   0,   0,   0,   0
]

private let deinterleaveStride: [Int32] = [5, 5, 9, 13, 17, 21, 25, 29, 33, 37, 41]
private let deinterleaveSize: [Int32] = [16, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160]

//  ascii to privar.  Copied verbatim from DominoVaricode.h (a Swift value; the
//  original was a `static unsigned short []` in a header not in the bridging file).
//  NOTE: codes such as 0,c,8 appear as value 0xc8, uniquely decodable since the MSB is set.
private let ASCIITOPRIVAR: [UInt16] = [
    //          0       1       2       3       4       5       6       7       8       9
    /*  0 */    0x1f9,  0x1fa,  0x1fb,  0x1fc,  0x1fd,  0x1fe,  0x1ff,  0x288,  0x2c,   0x289,
    /*  1 */    0x28a,  0x28b,  0x28c,  0x2d,   0x28d,  0x28e,  0x28f,  0x298,  0x299,  0x29a,
    /*  2 */    0x29b,  0x29c,  0x29d,  0x29e,  0x29f,  0x2a8,  0x2a9,  0x2aa,  0x2ab,  0x2ac,
    /*  3 */    0x2ad,  0x2ae,  0x0,    0x7b,   0x08e,  0x0ab,  0x09a,  0x099,  0x08f,  0x7a,
    /*  4 */    0x08c,  0x08b,  0x09d,  0x088,  0x2b,   0x7e,   0x7d,   0x089,  0x3f,   0x4a,
    /*  5 */    0x4f,   0x59,   0x68,   0x5c,   0x5e,   0x6c,   0x6b,   0x6e,   0x08a,  0x08d,
    /*  6 */    0x0a8,  0x7f,   0x09f,  0x7c,   0x098,  0x39,   0x4e,   0x3c,   0x3e,   0x38,
    /*  7 */    0x4c,   0x58,   0x5a,   0x3a,   0x78,   0x6a,   0x4b,   0x48,   0x4d,   0x3b,
    /*  8 */    0x49,   0x6f,   0x3d,   0x2f,   0x2e,   0x5b,   0x6d,   0x5d,   0x5f,   0x69,
    /*  9 */    0x79,   0x0ae,  0x0a9,  0x0af,  0x0aa,  0x09c,  0x09b,  0x4,    0x1b,   0x0c,
    /* 10 */    0x0b,   0x1,    0x0f,   0x19,   0x0a,   0x5,    0x2a,   0x1e,   0x09,   0x0e,
    /* 11 */    0x6,    0x3,    0x18,   0x28,   0x7,    0x08,   0x2,    0x0d,   0x1d,   0x1c,
    /* 12 */    0x1f,   0x1a,   0x29,   0x0ac,  0x09e,  0x0ad,  0x0b8,  0x2af,  0x2b8,  0x2b9,
    /* 13 */    0x2ba,  0x2bb,  0x2bc,  0x2bd,  0x2be,  0x2bf,  0x2c8,  0x2c9,  0x2ca,  0x2cb,
    /* 14 */    0x2cc,  0x2cd,  0x2ce,  0x2cf,  0x2d8,  0x2d9,  0x2da,  0x2db,  0x2dc,  0x2dd,
    /* 15 */    0x2de,  0x2df,  0x2e8,  0x2e9,  0x2ea,  0x2eb,  0x2ec,  0x2ed,  0x2ee,  0x2ef,
    /* 16 */    0x0b9,  0x0ba,  0x0bb,  0x0bc,  0x0bd,  0x0be,  0x0bf,  0x0c8,  0x0c9,  0x0ca,
    /* 17 */    0x0cb,  0x0cc,  0x0cd,  0x0ce,  0x0cf,  0x0d8,  0x0d9,  0x0da,  0x0db,  0x0dc,
    /* 18 */    0x0dd,  0x0de,  0x0df,  0x0e8,  0x0e9,  0x0ea,  0x0eb,  0x0ec,  0x0ed,  0x0ee,
    /* 19 */    0x0ef,  0x0f8,  0x0f9,  0x0fa,  0x0fb,  0x0fc,  0x0fd,  0x0fe,  0x0ff,  0x188,
    /* 20 */    0x189,  0x18a,  0x18b,  0x18c,  0x18d,  0x18e,  0x18f,  0x198,  0x199,  0x19a,
    /* 21 */    0x19b,  0x19c,  0x19d,  0x19e,  0x19f,  0x1a8,  0x1a9,  0x1aa,  0x1ab,  0x1ac,
    /* 22 */    0x1ad,  0x1ae,  0x1af,  0x1b8,  0x1b9,  0x1ba,  0x1bb,  0x1bc,  0x1bd,  0x1be,
    /* 23 */    0x1bf,  0x1c8,  0x1c9,  0x1ca,  0x1cb,  0x1cc,  0x1cd,  0x1ce,  0x1cf,  0x1d8,
    /* 24 */    0x1d9,  0x1da,  0x1db,  0x1dc,  0x1dd,  0x1de,  0x1df,  0x1e8,  0x1e9,  0x1ea,
    /* 25 */    0x1eb,  0x1ec,  0x1ed,  0x1ee,  0x1ef,  0x1f8
]

//  ascii to secvar
private let ASCIITOSECVAR: [UInt16] = [
    //          0       1       2       3       4       5       6       7       8       9
    /*  0 */    0x6f9,  0x6fa,  0x6fb,  0x6fc,  0x6fd,  0x6fe,  0x6ff,  0x788,  0x4ac,  0x789,
    /*  1 */    0x78a,  0x78b,  0x78c,  0x4ad,  0x78d,  0x78e,  0x78f,  0x798,  0x799,  0x79a,
    /*  2 */    0x79b,  0x79c,  0x79d,  0x79e,  0x79f,  0x7a8,  0x7a9,  0x7aa,  0x7ab,  0x7ac,
    /*  3 */    0x7ad,  0x7ae,  0x388,  0x4fb,  0x58e,  0x5ab,  0x59a,  0x599,  0x58f,  0x4fa,
    /*  4 */    0x58c,  0x58b,  0x59d,  0x588,  0x4ab,  0x4fe,  0x4fd,  0x589,  0x4bf,  0x4ca,
    /*  5 */    0x4cf,  0x4d9,  0x4e8,  0x4dc,  0x4de,  0x4ec,  0x4eb,  0x4ee,  0x58a,  0x58d,
    /*  6 */    0x5a8,  0x4ff,  0x59f,  0x4fc,  0x598,  0x4b9,  0x4ce,  0x4bc,  0x4be,  0x4b8,
    /*  7 */    0x4cc,  0x4d8,  0x4da,  0x4ba,  0x4f8,  0x4ea,  0x4cb,  0x4c8,  0x4cd,  0x4bb,
    /*  8 */    0x4c9,  0x4ef,  0x4bd,  0x4af,  0x4ae,  0x4db,  0x4ed,  0x4dd,  0x4df,  0x4e9,
    /*  9 */    0x4f9,  0x5ae,  0x5a9,  0x5af,  0x5aa,  0x59c,  0x59b,  0x38c,  0x49b,  0x48c,
    /* 10 */    0x48b,  0x389,  0x48f,  0x499,  0x48a,  0x38d,  0x4aa,  0x49e,  0x489,  0x48e,
    /* 11 */    0x38e,  0x38b,  0x498,  0x4a8,  0x38f,  0x488,  0x38a,  0x48d,  0x49d,  0x49c,
    /* 12 */    0x49f,  0x49a,  0x4a9,  0x5ac,  0x59e,  0x5ad,  0x5b8,  0x7af,  0x7b8,  0x7b9,
    /* 13 */    0x7ba,  0x7bb,  0x7bc,  0x7bd,  0x7be,  0x7bf,  0x7c8,  0x7c9,  0x7ca,  0x7cb,
    /* 14 */    0x7cc,  0x7cd,  0x7ce,  0x7cf,  0x7d8,  0x7d9,  0x7da,  0x7db,  0x7dc,  0x7dd,
    /* 15 */    0x7de,  0x7df,  0x7e8,  0x7e9,  0x7ea,  0x7eb,  0x7ec,  0x7ed,  0x7ee,  0x7ef,
    /* 16 */    0x5b9,  0x5ba,  0x5bb,  0x5bc,  0x5bd,  0x5be,  0x5bf,  0x5c8,  0x5c9,  0x5ca,
    /* 17 */    0x5cb,  0x5cc,  0x5cd,  0x5ce,  0x5cf,  0x5d8,  0x5d9,  0x5da,  0x5db,  0x5dc,
    /* 18 */    0x5dd,  0x5de,  0x5df,  0x5e8,  0x5e9,  0x5ea,  0x5eb,  0x5ec,  0x5ed,  0x5ee,
    /* 19 */    0x5ef,  0x5f8,  0x5f9,  0x5fa,  0x5fb,  0x5fc,  0x5fd,  0x5fe,  0x5ff,  0x688,
    /* 20 */    0x689,  0x68a,  0x68b,  0x68c,  0x68d,  0x68e,  0x68f,  0x698,  0x699,  0x69a,
    /* 21 */    0x69b,  0x69c,  0x69d,  0x69e,  0x69f,  0x6a8,  0x6a9,  0x6aa,  0x6ab,  0x6ac,
    /* 22 */    0x6ad,  0x6ae,  0x6af,  0x6b8,  0x6b9,  0x6ba,  0x6bb,  0x6bc,  0x6bd,  0x6be,
    /* 23 */    0x6bf,  0x6c8,  0x6c9,  0x6ca,  0x6cb,  0x6cc,  0x6cd,  0x6ce,  0x6cf,  0x6d8,
    /* 24 */    0x6d9,  0x6da,  0x6db,  0x6dc,  0x6dd,  0x6de,  0x6df,  0x6e8,  0x6e9,  0x6ea,
    /* 25 */    0x6eb,  0x6ec,  0x6ed,  0x6ee,  0x6ef,  0x6f8
]

@objc(DominoDemodulator)
class DominoDemodulator: MFSKDemodulator {

    var subbin: UnsafeMutablePointer<SubBin>!               //  [16]
    var iFSKDecodeVector: UnsafeMutablePointer<Int32>!      //  [32][32] DFSK transition map (flattened)
    var accumulatedCodes: Int32 = 0
    private var privar: UnsafeMutablePointer<UInt8>!        //  [4096] primary varicode
    private var secvar: UnsafeMutablePointer<UInt8>!        //  [4096] secondary varicode
    private var holdoff: Int32 = 0                          //  hold off after clicking
    private var matchedFilter = [Float](repeating: 0, count: 16)
    var ssnr: Float = 1.0

    //  for indicator
    private var avgSpectrum: UnsafeMutablePointer<Float>!   //  [512]
    //  modem offset
    private var previousModemOffset: Float = -1
    //  for statistics
    private var baudRate: Float = 0

    //  (Private API)
    @objc(initAsDomino:) init(asDomino mode: Int32) {
        subbin = UnsafeMutablePointer<SubBin>.allocate(capacity: 16)
        for i in 0..<16 { (subbin + i).initialize(to: SubBin()) }
        iFSKDecodeVector = UnsafeMutablePointer<Int32>.allocate(capacity: 32 * 32)
        iFSKDecodeVector.initialize(repeating: 0, count: 32 * 32)
        privar = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        privar.initialize(repeating: 0, count: 4096)
        secvar = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        secvar.initialize(repeating: 0, count: 4096)
        avgSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        avgSpectrum.initialize(repeating: 0, count: 512)

        super.init()

        m = 18
        afcState = 1
        previousModemOffset = -1
        interleaverStages = 4               //  default to 4 stages
        useFEC = false
        ssnr = 1.0

        decodeLag = 21
        fec.setTrellisDepth(decodeLag)

        switch mode {
        case DOMINOEX22: baudRate = 21.533
        case DOMINOEX16: baudRate = 15.625
        case DOMINOEX11: baudRate = 10.766
        case DOMINOEX8:  baudRate = 7.8125
        case DOMINOEX5:  baudRate = 5.3833
        case DOMINOEX4:  baudRate = 3.90625
        default: break
        }
        makeIFSKCode()
        holdoff = -1000
        //  primary varicode (privar already zeroed)
        for i in 0..<256 {
            let p = Int(ASCIITOPRIVAR[i] & 0xfff)
            if privar[p] != 0 {
                print("primary varicode error \(String(format: "%x", p)), mapped already to \(privar[p]) attempt to map again to \(i)")
            }
            if p != 0 { privar[p] = UInt8(truncatingIfNeeded: i) }
        }
        privar[0] = UInt8(ascii: " ")
        //  secondary Varicode
        for i in 0..<256 {
            let p = Int(ASCIITOSECVAR[i] & 0xfff)
            if secvar[p] != 0 {
                print("secondary varicode error \(String(format: "%x", p)), mapped already to \(secvar[p]) attempt to map again to \(i)")
            }
            if p != 0 { secvar[p] = UInt8(truncatingIfNeeded: i) }
        }
        avgSpectrum.update(repeating: 0, count: 512)
    }

    //  Full Rate DominoEX
    @objc(initAsMode:) convenience init(asMode mode: Int32) {
        self.init(asDomino: mode)
        //  clock recovery (32 bins)
        clockExtractFFT = FFTForward(5, false /*window*/)
        //  N clock cycles of extraction kernel (each cycle is 32 samples)
        clockExtractionCycles = 15
        prevClock = 0.0
        clockExtractFilter = CMFIRLowpassFilter(4, 500, clockExtractionCycles * 32)
        let n = Int(clockExtractionCycles * 32)
        for i in 0..<n {
            let v = Float(-cos(Double(i) * 3.1415926535 / 16.0))
            clockExtractFilter.pointee.kernel[i] = v
            clockExtractKernel[i] = v
        }
        waterfallClicked()
        resetDemodulatorState()
    }

    deinit {
        subbin.deinitialize(count: 16)
        subbin.deallocate()
        iFSKDecodeVector.deallocate()
        privar.deallocate()
        secvar.deallocate()
        avgSpectrum.deallocate()
    }

    //  note: 256 is error code
    private func makeIFSKCode() {
        for index in 0..<32 {
            for previous in 0..<32 {
                var delta = index - previous - 2
                if delta < 0 { delta += 18 }
                iFSKDecodeVector[index * 32 + previous] = Int32((delta < 0 || delta > 16) ? 256 : delta)
            }
        }
        for i in 0..<16 {
            let s = subbin + i
            s.pointee.mostRecentBin = 0
            s.pointee.nextRecentBin = 0
            s.pointee.energy = 0
            s.pointee.code[0] = 0
            s.pointee.bin[0] = 0
        }
        accumulatedCodes = 0
    }

    override func setUseFEC(_ state: DarwinBoolean) {
        useFEC = state.boolValue
    }

    //  (Private API)
    private func newIFSKVaricode(_ s: UnsafeMutablePointer<SubBin>, length: Int32) {
        if length < 0 { return }

        var decoded: Int32 = 0
        for i in 0..<Int(length) {
            decoded = decoded &* 16 &+ Int32(s.pointee.code[i])
            if s.pointee.code[i] > 16 { break }
        }

        decoded &= 0xfff

        //  found nibble that is start of Varicode, flush accumulated Varicode so far
        if cnr > squelchThreshold * 4 {
            if holdoff > 1000 { holdoff = 1000 }
            let prev = holdoff
            holdoff += 1
            if prev >= 0 {
                let primary = privar[Int(decoded)]
                if primary != 0 {
                    if previousChar != 0x0d || Int32(primary) != 0x0a {   //  '\r' / '\n'
                        var cc = Int32(primary)
                        if primary == 0x0d { cc = 0x0a }
                        modem?.displayPrimary(cc)
                    }
                    previousChar = Int32(primary)
                } else {
                    let secondary = secvar[Int(decoded)]
                    if secondary != 0 { modem?.displaySecondary(Int32(secondary)) }
                }
            }
        }
    }

    //  (Private API)
    private func newSubBin() {
        for i in 0..<16 {
            let s = subbin + i
            s.pointee.energy *= 0.7
            s.pointee.code[0] = s.pointee.code[Int(accumulatedCodes)]
            s.pointee.bin[0] = s.pointee.bin[Int(accumulatedCodes)]
        }
        accumulatedCodes = 0                //  reset to first nibble
    }

    //  With FEC: send subbin information to FEC.
    //  Without FEC: accumulate nibbles for Nibble based Varicode.
    func processSubbin(_ subbinWithLargestEnergy: Int32) {
        if useFEC {
            var preInterleave = QuadBits()

            //  identified the subbin that contains the largest energy; send to FEC
            let s = subbin + Int(subbinWithLargestEnergy)
            accumulatedCodes = 0            //  no accumulation needed in FEC mode
            var code = Int32(s.pointee.code[Int(accumulatedCodes)])

            //  adjust confidence factor for soft decoding if code is obviously wrong
            var snr: Float
            if softDecode {
                if s.pointee.notDecoded {
                    code = 0
                    snr = 0.5
                } else {
                    snr = ssnr
                    if snr < 0.5 { snr = 0.5 } else if snr > 1 { snr = 1 }   //  sanity check
                }
            } else {
                snr = 1.0
            }

            //  use s/(s+n) ratio for soft decoding; snr must be above 0.5 to decode
            preInterleave.bit[0] = (code & 0x8) != 0 ? snr : 1 - snr
            preInterleave.bit[1] = (code & 0x4) != 0 ? snr : 1 - snr
            preInterleave.bit[2] = (code & 0x2) != 0 ? snr : 1 - snr
            preInterleave.bit[3] = (code & 0x1) != 0 ? snr : 1 - snr
            let postInterleave = deinterleave(preInterleave)
            convolutionDecodeMSB(postInterleave.bit[0], lsb: postInterleave.bit[1])   //  decode first two bits
            convolutionDecodeMSB(postInterleave.bit[2], lsb: postInterleave.bit[3])   //  decode next two bits
        } else {
            //  see if the largest-energy sub-bin has a "start bit"
            let s = subbin + Int(subbinWithLargestEnergy)
            let code = Int32(s.pointee.code[Int(accumulatedCodes)])

            s.pointee.index = subbinWithLargestEnergy
            s.pointee.terminatingCode = code

            if code < 8 {
                newIFSKVaricode(s, length: accumulatedCodes)
                newSubBin()
            }
            if accumulatedCodes >= 3 {
                //  code length exceeded DominoEX specs, flush it
                newIFSKVaricode(s, length: accumulatedCodes)
                newSubBin()
            }
            accumulatedCodes = (accumulatedCodes + 1) % 8
        }
    }

    //  (Private API) Differential 18FSK decode.  Input is an array of 16x oversampled frequency bins.
    func ifskDecode(_ vector: UnsafeMutablePointer<Float>) {
        accumulatedCodes %= 8               //  sanity check

        //  find largest vector for each of the 16 sub-bins and energy
        var largestEnergy: Float = 0
        var subbinWithLargestEnergy: Int32 = 0
        var peakIndex = 0
        for bin in 0..<16 {
            let s = subbin + bin
            var maxv: Float = 0
            var avgv: Float = 0
            var index = 0
            var i = bin
            while i < 512 {
                let v = vector[i]
                avgv += v
                if v > maxv { maxv = v; index = i }
                i += 16
            }
            //  accumulate energy
            s.pointee.energy += maxv
            let v = s.pointee.energy
            if v > largestEnergy {
                largestEnergy = v
                subbinWithLargestEnergy = Int32(bin)
                peakIndex = index
            }
            let idx = ((index + 8) / 16) & 0x1f
            //  treat LSB differently
            let fecCode = iFSKDecodeVector[idx * 32 + Int(s.pointee.mostRecentBin)]
            s.pointee.code[Int(accumulatedCodes)] = Int16(truncatingIfNeeded: fecCode)
            s.pointee.notDecoded = (fecCode < 0 || fecCode > 15)
            s.pointee.nextRecentBin = s.pointee.mostRecentBin
            s.pointee.bin[Int(accumulatedCodes)] = Int16(truncatingIfNeeded: idx)
            s.pointee.mostRecentBin = Int32(s.pointee.bin[Int(accumulatedCodes)])
        }

        //  estimate carrier to noise ratio
        var avgv: Float = 0.0001
        var i = 64
        while i < 448 {
            avgv += vector[(peakIndex + i) % 512]
            i += 16
        }
        avgv /= 24

        let peak = vector[peakIndex]
        cnr = cnr * 0.92 + 0.08 * (peak / avgv)
        ssnr = ssnr * 0.92 + 0.08 * (peak / (peak + avgv))

        processSubbin(subbinWithLargestEnergy)
    }

    //  (Private API)
    private func updateIndicators(_ powerSpectrum: UnsafeMutablePointer<Float>, threshold: Float) {
        var binOffset = [Float](repeating: 0, count: 16)

        var minOffset = 0
        while minOffset < 510 { if avgSpectrum[minOffset] > threshold { break }; minOffset += 1 }
        var maxOffset = 510
        while maxOffset >= 0 { if avgSpectrum[maxOffset] > threshold { break }; maxOffset -= 1 }

        //  afcState = 0 no AFC; 1 perform AFC; 2 hold afc
        let diffOffset = mfskTruncInt(Double(maxOffset - minOffset) / 16.0 + 0.5)
        var offset: Int32 = 0
        if diffOffset == m {
            //  identified bins
            offset = Int32(minOffset) + 16 * 5
            //  use all bins of avgSpectrum to identify the bin offset
            for k in 0..<16 {
                var u: Float = 0
                var i = k
                while i < 512 { u += avgSpectrum[i]; i += 16 }
                binOffset[k] = u
            }
            //  now find max bin
            var u = binOffset[0]
            var binMax = 0
            for i in 1..<16 {
                if binOffset[i] > u { u = binOffset[i]; binMax = i }
            }
            //  use bin averages to adjust offset boundary
            var binBoundary = binMax - 8
            if binBoundary < 0 { binBoundary += 16 }
            var kk = Int(offset) / 16
            let ii = Int(offset) - kk * 16
            if ii < 4 && binBoundary > 12 { kk -= 1 } else if ii > 12 && binBoundary < 4 { kk += 1 }
            offset = Int32(kk * 16 + binBoundary)
        } else {
            offset = 0
        }

        if afcState == 1 && offset > 0 {
            //  move the RxFreq offset relative to where it was clicked (0 offset = clicked position)
            if Float(offset) != previousModemOffset {
                //  18 bins instead of 16 MFSK16 bins
                modem?.applyRxFreqOffset(Float(Double(offset) * 11.025 / 16.0 - (Double(CARRIEROFFSET) * 18.0 / 16.0)))
            }
        }
        //  output to tuning indicator
        if freqIndicator != nil {
            //  center display around 28 FSK channels
            freqIndicator?.newWideSpectrum(powerSpectrum + 32)
            if offset > 0 && Float(offset) != previousModemOffset {
                freqLabel?.setAbsoluteOffset(offset - 16 * 5 - 22)
            }
        }
        previousModemOffset = Float(offset)
    }

    //  Accepts a new vector of (length) 32 or 64 samples aligned to the symbol clock and creates the frequency alignment.
    //  Half rate DominoEX (8,5) call with 64 samples, regular rate (22,16,11,4) with 32 samples.
    override func afcVector(_ vector: UnsafeMutablePointer<DSPSplitComplex>, length: Int32) {
        let len = Int(length)
        let vi = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let vq = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let iOrderedSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 768)
        let qOrderedSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 768)
        let powerSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer {
            vi.deallocate(); vq.deallocate()
            iOrderedSpectrum.deallocate(); qOrderedSpectrum.deallocate(); powerSpectrum.deallocate()
        }

        //  Zero fill and apply a 512 point FFT.
        (vi + len).update(repeating: 0, count: 512 - len)
        (vq + len).update(repeating: 0, count: 512 - len)
        vi.update(from: vector.pointee.realp, count: len)
        vq.update(from: vector.pointee.imagp, count: len)

        var input = DSPSplitComplex(realp: vi, imagp: vq)
        var output = DSPSplitComplex(realp: iOrderedSpectrum + 256, imagp: qOrderedSpectrum + 256)   //  offset to order spectrum later
        CMPerformComplexFFT(afcFFT, &input, &output)

        //  Copy second half of FFT output to the beginning of the result (ordered spectrum 0..511).
        iOrderedSpectrum.update(from: iOrderedSpectrum + 512, count: 256)
        qOrderedSpectrum.update(from: qOrderedSpectrum + 512, count: 256)

        //  Convolve with a rectangular filter.
        var threshold: Float = 0
        for i in 0..<512 {
            var u: Float = 0
            if i < 512 - 9 {
                let p = iOrderedSpectrum + i
                let q = qOrderedSpectrum + i
                for k in 0..<9 { u += (p[k] * p[k] + q[k] * q[k]) }
            }
            powerSpectrum[i] = u

            //  fast charge slow discharge to obtain average spectrum
            if u > avgSpectrum[i] {
                u = avgSpectrum[i] * 0.2 + u * 0.8
            } else {
                u = avgSpectrum[i] * 0.98 + u * 0.02
            }
            avgSpectrum[i] = u
            if u > threshold { threshold = u }
        }
        //  go decode from the spectrum
        ifskDecode(powerSpectrum)
        updateIndicators(powerSpectrum, threshold: threshold * 0.3)
    }

    override func resetDemodulatorState() {
        iTime.update(repeating: 0, count: 2048)
        qTime.update(repeating: 0, count: 2048)
        ringIndex = 0
        //  clear clock extraction FIR pipe
        timeAperture.update(repeating: 0, count: 64)
        ssnr = 1.0

        for _ in 0..<32 { CMPerformFIR(clockExtractFilter, avgSpectrum, 32, timeAperture) }
    }

    override func waterfallClicked() {
        resetDemodulatorState()
        //  clear the average spectrum and symbol clock filter
        avgSpectrum.update(repeating: 0, count: 512)
        newSubBin()
        holdoff = -2
    }

    //  use fixed clock extraction for DominoEX
    override func setClockExtraction(_ cycles: Int32) {
    }

    //  --- FEC ---

    //  Accumulate bits into the bit register; flush to the Varicode decoder at end of character.
    override func varicodeDecode(_ bit: Int32) {
        decodedBits = (decodedBits &<< 1) | UInt32(bit & 1)
        let c0 = Int32(decodedBits & 0x7)
        if c0 == 0x1 {
            //  001 received.  00 is the stop bits of a code word and 1 is the start bit of the new code.
            decodedBits /= 2
            let c = varicode.decode(Int32(decodedBits))

            if c > 0, modem != nil {
                let secondary = secondaryFECDecodeTable[Int(c & 0xff)]
                if cnr > squelchThreshold * 2 {
                    if secondary != 0 { modem?.displaySecondary(secondary) } else if c != 0 { modem?.displayPrimary(c) }
                }
                previousChar = c
            }
            //  retain only the most recent non-zero bit
            decodedBits = 1
        }
    }

    //  Default to 4 stage deinterleaverStages
    override func deinterleave(_ p: QuadBits) -> QuadBits {
        var quad = QuadBits()

        let mod = Int(deinterleaveSize[Int(interleaverStages)])
        let stride = Int(deinterleaveStride[Int(interleaverStages)])
        //  fetch the four deinterleaved bits before overwriting some with the new data
        for i in 0..<4 { quad.bit[i] = interleaverRegister[(Int(interleaverIndex) + i * stride) % mod] }
        //  insert new bits into register
        for i in 0..<4 { interleaverRegister[Int(interleaverIndex) + i] = p.bit[i] }
        //  increment the pointer for the next QuadBits set
        interleaverIndex = (interleaverIndex + 4) % Int32(mod)

        return quad
    }
}
