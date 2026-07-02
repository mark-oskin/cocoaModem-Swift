//
//  MFSKModulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/17/07.
//  Swift port of MFSKModulator.m.
//
//  MFSK16 modulator (also the base class for DominoEX).  Subclass of NewNCO.
//  Chain:  ascii -> Varicode -> FEC -> interleave -> 1-of-16 -> tone.
//
//  Audio is fetched with -getBufferWithIdleFill:length:.  The phase accumulator
//  and sin() come from the inherited NewNCO / CMNCO engine (wrapping / guarded
//  index math lives there).
//

import Cocoa

private let RINGMASK: Int32 = 0xfff

private let NOTTERMINATING: Int32 = 0
private let TERMINATESTARTED: Int32 = 1
private let TERMINATETAIL: Int32 = 2
private let TERMINATED: Int32 = 5

//  QuadBits used by FEC (was a C struct in MFSKFEC.h; only used internally here,
//  so a Swift struct with an indexable bit[4] is used)
struct QuadBits {
    var bit: [Float] = [0, 0, 0, 0]     // bit[0] = MSB, bit[3] = LSB
}

//  ring buffer element (was MFSKStream in MFSKModulator.h)
struct MFSKStream {
    var value: Int32 = 0                //  bit polarity for MFSK16 and nibble for DominoEX
    var character: Int32 = 0            //  either 0 or an ASCII character
    var secondaryCharacter: Int32 = 0
}

private let randBitsStrings = ["00000", "0000", "000", "00"]

//  Concatenated deinterleaver strides/sizes (IZ8BLY Diagonal Interleaver)
private let interleaveStride: [Int32] = [5, 5, 9, 13, 17, 21, 25, 29, 33, 37, 41]
private let interleaveSize: [Int32] = [16, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160]

private let grayEncode: [Int32] = [
    0x0, 0x1, 0x3, 0x2,
    0x7, 0x6, 0x4, 0x5,
    0xf, 0xe, 0xc, 0xd,
    0x8, 0x9, 0xb, 0xa
]

private func cString(_ p: UnsafePointer<CChar>?) -> [CChar] {
    guard let p = p else { return [0] }
    var out = [CChar]()
    var i = 0
    while p[i] != 0 { out.append(p[i]); i += 1 }
    out.append(0)
    return out
}

@objc(MFSKModulator)
class MFSKModulator: NewNCO {

    weak var modem: MFSK?
    var varicode: MFSKVaricode!
    var fec: ConvolutionCode!

    var carrier: Float = 0
    //  data ring
    var bitLock: NSLock!
    var ring = [MFSKStream](repeating: MFSKStream(), count: Int(RINGMASK) + 1)
    var bitProducer: Int32 = 0
    var bitConsumer: Int32 = 0
    var idleSequenceState: Int32 = 0
    var terminateCount: Int32 = 0
    var terminateState: Int32 = 0
    var characterRing = [Int32](repeating: 0, count: 64)
    var characterRingIndex: Int32 = 0
    //  interleaver
    var interleaverStages: Int32 = 0
    var interleaverIndex: Int32 = 0
    var interleaverRegister = [Float](repeating: 0, count: 160)
    var useFEC: Bool = false
    //  modulation
    var baudDDA: Double = 0
    var currentFFTBin: Int32 = 0
    var idleFrequency: Float = 0
    var sideband: Float = 0
    var transmitBPF: UnsafeMutablePointer<CMFIR>?
    //  test tone
    var cw: Bool = false

    override init() {
        super.init()
        //  establish baud rate and carrier generator
        bitTheta = 100000.0
        baudDDA = 15.625 * kPeriod / kCMFs
        scale = 0.9
        cw = false

        transmitBPF = nil

        bitLock = NSLock()
        varicode = MFSKVaricode()
        fec = ConvolutionCode(constraintLength: 7, generator: 0x6d, generatorB: 0x4f)
        interleaverStages = 10          // 10 stages for MFSK16, 4 stages default for DominoEX

        sideband = 1.0                  //  -1 for LSB, +1.0 for USB
        setFrequency(10.0)              // default to 10 Hz carrier
        resetModulator()
    }

    @objc(setInterleaverStages:)
    func setInterleaverStages(_ stages: Int32) {
        var stages = stages
        if stages < 4 { stages = 4 } else if stages > 10 { stages = 10 }
        interleaverStages = stages
    }

    //  setup carrier for self (NCO object)
    func setDDAFrequency(_ freq: Float) {
        carrier = Float(Double(freq) * kPeriod / kCMFs)
    }

    //  base (idle) frequency of the MFSK signal
    @objc(setFrequency:)
    func setFrequency(_ freq: Float) {
        idleFrequency = freq
        setDDAFrequency(freq)

        if let bpf = transmitBPF {
            transmitBPF = nil
            CMDeleteFIR(bpf)
        }
        let side = Float(15.625 * 2.8)
        let delta = Float(15.625 * 15 + Double(side))

        if sideband > 0 {
            transmitBPF = CMFIRBandpassFilter(freq - side, freq + delta, Float(kCMFs), 1024)
        } else {
            transmitBPF = CMFIRBandpassFilter(freq - delta, freq + side, Float(kCMFs), 1024)
        }
    }

    // set sideband state -- LSB = NO
    @objc(setSidebandState:)
    func setSidebandState(_ state: Bool) {
        sideband = state ? 1.0 : (-1.0)
        setFrequency(idleFrequency)
    }

    //  called from config to transmit a pure carrier
    @objc(setCW:)
    func setCW(_ state: Bool) {
        cw = state
    }

    @objc(setUseFEC:)
    func setUseFEC(_ state: Bool) {
        //  do nothing in MFSK16
    }

    //  Note: caller must apply lock to bitLock
    @objc(insertValue:withCharacter:secondary:)
    func insertValue(_ value: Int32, withCharacter ch: Int32, secondary secondaryCh: Int32) {
        ring[Int(bitProducer)].character = ch
        ring[Int(bitProducer)].secondaryCharacter = secondaryCh
        ring[Int(bitProducer)].value = value
        bitProducer += 1
        bitProducer &= RINGMASK
    }

    //  insert bit for MFSK16 and nibble for DominoEX
    @objc(lockAndInsertValue:withCharacter:secondary:)
    func lockAndInsertValue(_ value: Int32, withCharacter ch: Int32, secondary secondaryCh: Int32) {
        bitLock.lock()
        insertValue(value, withCharacter: ch, secondary: secondaryCh)
        bitLock.unlock()
    }

    //  (Private API)  insert bits into the ring buffer
    @objc(insertPrimaryASCIIIntoFECBuffer:fromCharacter:)
    func insertPrimaryASCIIIntoFECBuffer(_ ascii: Int32, fromCharacter ch: Int32) {
        bitLock.lock()
        idleSequenceState = 0
        guard let bits = varicode.encode(ascii) else { bitLock.unlock(); return }
        let length = Int(strlen(bits))
        let zero = CChar(UInt8(ascii: "0"))

        for i in 0..<length {
            let b = bits[i]
            insertValue((b == zero || b == 0) ? 0 : 1, withCharacter: (i == 0) ? ch : 0, secondary: 0)
        }
        bitLock.unlock()
    }

    @objc(insertPrimaryFECVaricodeFor:fromCharacter:)
    func insertPrimaryFECVaricode(for ascii: Int32, fromCharacter echo: Int32) {
        insertPrimaryASCIIIntoFECBuffer(ascii, fromCharacter: echo)
    }

    //  in MFSK16, this is the same as insert primary varicode
    @objc(insertSecondaryFECVaricodeFor:fromCharacter:)
    func insertSecondaryFECVaricode(for ascii: Int32, fromCharacter echo: Int32) {
        insertPrimaryFECVaricode(for: ascii, fromCharacter: echo)
    }

    //  Fetch next data bit modulation from the ring buffer.
    func getNextFECBit() -> Int32 {
        if terminateState == TERMINATED { return 0 }

        if bitConsumer == bitProducer {
            if terminateState == NOTTERMINATING {
                //  Insert idle bits (depends on idleSequenceState)
                bitLock.lock()
                var idle: [CChar]
                switch idleSequenceState {
                case 0:
                    //  insert 0x75c (ASCII NULL)
                    idle = cString(varicode.encode(0))
                    idleSequenceState = 1
                case 1:
                    //  insert four zeros, to keep under constraint length of convolutional code
                    idle = Array((randBitsStrings[Int(arc4random_uniform(4))]).utf8CString)
                    idleSequenceState = 0
                default:
                    //  should not get here, but kick it back to NULL
                    idle = cString(varicode.encode(0))
                    idleSequenceState = 1
                }
                var p = 0
                let zero = CChar(UInt8(ascii: "0"))
                while idle[p] != 0 {
                    insertValue((idle[p] == zero) ? 0 : 1, withCharacter: 0, secondary: 0)
                    p += 1
                }
                bitLock.unlock()
            } else {
                switch terminateState {
                case TERMINATESTARTED:
                    //  a ^E was seen earlier.  Send 5 nulls before going to the next state
                    terminateCount += 1
                    if terminateCount < 5 { insertPrimaryFECVaricode(for: 0, fromCharacter: 0) }
                    else {
                        terminateState = TERMINATETAIL
                        terminateCount = 0
                        insertValue(0, withCharacter: 0, secondary: 0)
                    }
                case TERMINATETAIL:
                    //  terminate state has entered the carrier tail state
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
        var newCharacter = ring[Int(bitConsumer)].character
        var newBit = ring[Int(bitConsumer)].value
        bitConsumer += 1
        bitConsumer &= RINGMASK

        //  check for end-of-message that the client has inserted
        switch newCharacter {
        case 5 /* ^E */:
            //  check first to make sure there are no more macros
            if bitConsumer == bitProducer {
                //  Character buffer is truly empty, initiate a terminate sequence
                terminateState = TERMINATESTARTED
                terminateCount = 0
                insertPrimaryASCIIIntoFECBuffer(0, fromCharacter: 0)
                newCharacter = ring[Int(bitConsumer)].character
                newBit = ring[Int(bitConsumer)].value
                bitConsumer += 1
                bitConsumer &= RINGMASK
                //  tell user we have entered the terminating sequence
                modem?.changeTransmitLight(2)
            } else {
                //  continue transmitting
                return getNextFECBit()
            }
        default:
            break
        }
        //  save character for echo back in fillBuffer, delayed by 128 characters
        if characterRing[Int(characterRingIndex)] != 0 { modem?.transmittedCharacter(characterRing[Int(characterRingIndex)]) }
        characterRing[Int(characterRingIndex)] = newCharacter
        characterRingIndex = (characterRingIndex + 1) & 0x3f

        return (newBit == 0) ? 0 : 1
    }

    //  DominoEX interleaver (10 stage for MFSK16, 4 stage default for DominoEX)
    func interleave(_ p: QuadBits) -> QuadBits {
        var quad = QuadBits()
        let mod = interleaveSize[Int(interleaverStages)]
        //  insert new bits into register
        for i in 0..<4 {
            interleaverRegister[Int((interleaverIndex + Int32(i) * interleaveStride[Int(interleaverStages)]) % mod)] = p.bit[i]
        }
        //  fetch the four deinterleaved bits before overwriting some with the new data
        for i in 0..<4 {
            quad.bit[i] = interleaverRegister[Int(interleaverIndex + Int32(i))]
        }
        //  increment the pointer for the next QuadBits set
        interleaverIndex = (interleaverIndex + 4) % mod

        return quad
    }

    //  get next FEC encoded dibit
    private func getNextFECEncodedDibit() -> Int32 {
        let bit = getNextFECBit()
        //  Replace the stream bit by the convolutional code's dibit.
        return fec.encodeIntoDibit(bit)
    }

    //  get next interleaved QuadBits by getting two FEC encoded Dibits
    private func getNextInterleavedQuadBits() -> QuadBits {
        var q = QuadBits()
        var dibit = getNextFECEncodedDibit()
        q.bit[0] = (dibit & 0x2) != 0 ? 1.0 : 0.0
        q.bit[1] = (dibit & 0x1) != 0 ? 1.0 : 0.0
        dibit = getNextFECEncodedDibit()
        q.bit[2] = (dibit & 0x2) != 0 ? 1.0 : 0.0
        q.bit[3] = (dibit & 0x1) != 0 ? 1.0 : 0.0

        return interleave(q)
    }

    //  Note: MFSK16 needs to gray code the result from here
    func getNextFECIndex() -> Int32 {
        let q = getNextInterleavedQuadBits()

        if terminateState == TERMINATETAIL && terminateCount > 30 { return 0 }  //  ignore interleaver for the end

        var b: Int32 = (q.bit[0] > 0.5) ? 8 : 0
        b += (q.bit[1] > 0.5) ? 4 : 0
        b += (q.bit[2] > 0.5) ? 2 : 0
        b += (q.bit[3] > 0.5) ? 1 : 0

        return b
    }

    @objc(appendEOM)
    func appendEOM() {
        insertPrimaryASCIIIntoFECBuffer(Int32(UInt8(ascii: " ")), fromCharacter: Int32(UInt8(ascii: " ")))

        bitLock.lock()
        idleSequenceState = 0
        insertValue(0, withCharacter: 5, secondary: 0)
        bitLock.unlock()
    }

    @objc(appendASCII:)
    func appendASCII(_ ascii: Int32) {
        // ignore opt u, i, `, e, n (e.g., umlaut prefix)
        if (ascii == 168) || (ascii == 710) || (ascii == 96) || (ascii == 180) || (ascii == 732) { return }

        switch ascii {
        case 0x5: // %[rx]
            appendEOM()
            return
        case 0x6: // %[tx]
            //  if macros are appended when we are terminating, abort the terminating sequence
            if terminateState == TERMINATESTARTED || terminateState == TERMINATETAIL {
                terminateState = NOTTERMINATING
                modem?.changeTransmitLight(1)
            }
            return
        default:
            if terminateState == NOTTERMINATING {
                var ascii = ascii
                //  make sure zero is not transmitted as phi
                if ascii == 0xd8 || ascii == 0xf8 { ascii = Int32(UInt8(ascii: "0")) }
                insertPrimaryASCIIIntoFECBuffer(ascii, fromCharacter: ascii)
            }
        }
    }

    func appendString(_ string: UnsafePointer<CChar>) {
        var p = string
        while p.pointee != 0 {
            appendASCII(Int32(p.pointee))
            p += 1
        }
    }

    //  Fetch next audio sample
    func nextAudioSample() -> Float {
        if terminateState == TERMINATED {
            return (transmitBPF != nil) ? CMSimpleFilter(transmitBPF, 0.0) : 0.0
        }
        if cw { return Float(Double(sin(Double(carrier))) * 0.9) }       // test CW tone

        //  check if the next symbol is needed
        if modulation(baudDDA) {
            let fftBin = grayEncode[Int(getNextFECIndex())]
            setDDAFrequency(Float(Double(idleFrequency) + 15.625 * Double(sideband) * Double(fftBin)))
        }
        let v = Float(Double(sin(Double(carrier))) * 0.9)

        return (transmitBPF != nil) ? CMSimpleFilter(transmitBPF, v) : v
    }

    @objc(getBufferWithIdleFill:length:)
    func getBufferWithIdleFill(_ buf: UnsafeMutablePointer<Float>, length samples: Int32) {
        if idleFrequency < 20.0 {
            for i in 0..<Int(samples) { buf[i] = 0.0 }
            return
        }
        for i in 0..<Int(samples) { buf[i] = nextAudioSample() }
    }

    @objc(setScale:)
    func setScale(_ value: Float) {
        // set the NCO amplitude with scale value
        setOutputScale(value)
    }

    @objc(terminated)
    func terminated() -> Bool {
        return (terminateState == TERMINATED)
    }

    @objc(flushOutput)
    func flushOutput() {
        bitLock.lock()
        bitProducer = 0
        bitConsumer = 0
        //  start with 15 symbol periods (approx 1 second) of idle carrier
        for _ in 0..<30 { insertValue(0, withCharacter: 0, secondary: 0) }
        idleSequenceState = 0
        bitLock.unlock()
    }

    @objc(resetModulator)
    func resetModulator() {
        flushOutput()
        terminateState = NOTTERMINATING
        terminateCount = 0
        //  flush transmit BPF
        if transmitBPF != nil { for _ in 0..<160 { _ = CMSimpleFilter(transmitBPF, 0.0) } }
        //  reset interleaver
        interleaverIndex = 0
        for i in 0..<160 { interleaverRegister[i] = 0 }
        //  reset character ring
        characterRingIndex = 0
        for i in 0..<64 { characterRing[i] = 0 }
        //  reset vco phase
        resetPhase()
    }

    @objc(setModemClient:)
    func setModemClient(_ client: MFSK?) {
        modem = client
    }
}
