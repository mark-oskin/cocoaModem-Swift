//
//  CWModulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/5/07.
//  Swift port of CWModulator.m.
//
//  Wideband CW (Morse) modulator.  Subclass of RTTYModulator.  A ring of Morse
//  elements (ring[4096]) is filled by -appendASCII: (from the ASCII->Morse table
//  "ascii") and keyed through a Blackman-window rise/fall filter into the CMPCO
//  carrier oscillator.
//
//  NOTE: one Morse element at 50 wpm is approx 264 samples at 11025 s/s.
//
//  The Morse code table was a char*[16384] of C string literals in the original;
//  it is kept here as an array of null-terminated [CChar] (Swift owns the
//  storage, so no strdup/leak).  A float->int truncation in the element-duration
//  arithmetic is done with the guarded cmPhaseTrunc so a bad speed value cannot
//  trap.
//

import Cocoa

//  Morse element (was MorseElementType in CWModulator.h)
struct MorseElementType {
    var ascii: Int32 = 0
    var state: Int32 = 0
    var duration: Int32 = 0
}

private func cstr(_ s: String) -> [CChar] {
    return Array(s.utf8CString)
}

@objc(CWModulator)
class CWModulator: RTTYModulator {

    private var vco: CMPCO!
    private var carrierFreq: Float = 0
    private var gain: Float = 0

    //  test tone
    private var testTone: CMPCO!
    private var testFreq: Float = 0
    private var toneIndex: Int32 = 0

    private var waveshape: UnsafeMutablePointer<CMFIR>?
    private var speed: Float = 0
    private var weight: Float = 0
    private var ratio: Float = 0
    private var farnsworth: Float = 0

    //  morse element
    private var tick: Int32 = 0
    private var cwState: Int32 = 0
    private var ringProducer: Int32 = 0
    private var ringConsumer: Int32 = 0
    private var ring = [MorseElementType](repeating: MorseElementType(), count: 4096)

    private var transmitHoldoff: Int32 = 0

    private var interElement: Int32 = 0
    private var dit: Int32 = 0
    private var dash: Int32 = 0
    private var interCharacter: Int32 = 0
    private var interWord: Int32 = 0
    //  Morse
    private var ascii = [[CChar]](repeating: [0], count: 16384)

    private func initMorse() {
        for i in 0..<16384 { ascii[i] = [0] }

        func set(_ c: Unicode.Scalar, _ s: String) { ascii[Int(c.value)] = cstr(s) }

        set(" ", " ")       // interword == 4 inter-element (+3 intercharacter)
        set("a", ".-");   set("b", "-...");  set("c", "-.-.");  set("d", "-..")
        set("e", ".");    set("f", "..-.");  set("g", "--.");   set("h", "....")
        set("i", "..");   set("j", ".---");  set("k", "-.-");   set("l", ".-..")
        set("m", "--");   set("n", "-.");    set("o", "---");   set("p", ".--.")
        set("q", "--.-"); set("r", ".-.");   set("s", "...");   set("t", "-")
        set("u", "..-");  set("v", "...-");  set("w", ".--");   set("x", "-..-")
        set("y", "-.--"); set("z", "--..")
        for i in Int(UInt8(ascii: "a"))...Int(UInt8(ascii: "z")) { ascii[i - Int(UInt8(ascii: "a")) + Int(UInt8(ascii: "A"))] = ascii[i] }
        set("0", "-----"); set("1", ".----"); set("2", "..---"); set("3", "...--"); set("4", "....-")
        set("5", "....."); set("6", "-...."); set("7", "--..."); set("8", "---.."); set("9", "----.")

        set(".", ".-.-.-"); set(",", "--..--"); set("?", "..--..")
        ascii[0x22] = cstr(".-..-.")
        let dotdot = cstr("..")
        ascii[Int(UInt8(ascii: "#"))] = dotdot; ascii[Int(UInt8(ascii: "%"))] = dotdot
        ascii[Int(UInt8(ascii: "&"))] = dotdot; ascii[Int(UInt8(ascii: "*"))] = dotdot
        set("$", "...-..-")
        ascii[0x27] = cstr(".----.")
        set("(", "-.--."); set(")", "-.--.-"); set("+", ".-.-."); set("-", "-....-"); set("/", "-..-.")
        set(":", "-.--."); set(";", ".-.-"); set("<", ".-.-."); set("=", "-...-"); set(">", "...-.-")
        set("@", ".--.-.")

        //  optional user overrides from ~/Library/Application Support/cocoaModem/Morse.txt
        let path = ("~/Library/Application Support/cocoaModem/Morse.txt" as NSString).expandingTildeInPath
        if let contents = try? String(contentsOfFile: path, encoding: .isoLatin1) {
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
                if tokens.count < 2 { break }
                guard let index = Int(tokens[0]) else { break }
                let string = String(tokens[1])
                if index <= 0 || index > 16383 || string.isEmpty { break }
                ascii[index] = cstr(string)
            }
        }
    }

    override init() {
        super.init()
        waveshape = BlackmanWindow(131, 300)        //  width 131 = approx 5 ms rise and fall times
        vco = CMPCO()
        vco.setCarrier(750.0)
        testTone = CMPCO()
        testTone.setCarrier(700.0)
        speed = 25.0
        weight = 0.5
        ratio = 3.0
        farnsworth = 1.0
        transmitHoldoff = 0
        ook = 0                                     //  v0.85
        setGain(1.0)
        setSpeed(speed)
        initMorse()
        tick = 0
        cwState = 0
        ringProducer = 0
        ringConsumer = 0
    }

    //  set test tone frequency
    @objc(setTestFrequency:)
    func setTestFrequency(_ v: Float) {
        testTone.setCarrier(v)
    }

    //  set gain (e.g., from equalizer)
    @objc(setGain:)
    func setGain(_ v: Float) {
        gain = v
    }

    //  set VCO amplitude from the output attenuator slider
    @objc(setOutputScale:)
    override func setOutputScale(_ value: Float) {
        //  v0.88 equalized to PSK peak level and allow 2 dB boost
        let boost = modem?.outputBoost() ?? 0.0
        let scaled = Float(Double(value) * (0.902 * Double(boost)))
        vco.setOutputScale(scaled)
        testTone.setOutputScale(scaled)
    }

    //  v0.85
    @objc(setModulationMode:)
    func setModulationMode(_ index: Int32) {
        ook = (index != 0) ? 1 : 0
        if ook != 0 {
            vco.setCarrier(2500.0)
        } else {
            vco.setCarrier(carrierFreq)
        }
    }

    @objc(setRisetime:weight:ratio:farnsworth:)
    func setRisetime(_ t: Float, weight w: Float, ratio r: Float, farnsworth f: Float) {
        var length = cmPhaseTrunc(131.0 * Double(t) / 5.0)
        //  limit change to 1.9 ms to 10.3 ms
        if length < 50 { length = 50 } else if length > 270 { length = 270 }
        adjustBlackmanWindow(waveshape, length)

        weight = w
        if weight < 0.1 { weight = 0.1 } else if weight > 0.9 { weight = 0.9 }

        ratio = r
        if ratio < 2.0 { ratio = 2.0 } else if ratio > 4.0 { ratio = 4.0 }

        var f = f
        if f > 1.0 { f = 1.0 } else if f < 0.2 { f = 0.2 }
        farnsworth = 1.0 / f

        //  recompute element durations
        setSpeed(speed)
    }

    //  use basic speed to compute the elements
    @objc(setSpeed:)
    func setSpeed(_ inSpeed: Float) {
        speed = inSpeed
        let basicElement = cmPhaseTrunc(264.0 * 50.0 / Double(speed))

        interElement = cmPhaseTrunc(2.0 * Double(1 - weight) * Double(basicElement))
        dit = cmPhaseTrunc(2.0 * Double(weight) * Double(basicElement))
        dash = cmPhaseTrunc(Double(ratio * Float(dit)))
        interCharacter = cmPhaseTrunc(Double(Float(3 &* basicElement) * farnsworth))     // farnsworth is between 1.0 (normal) and 5.0
        interWord = cmPhaseTrunc(Double(Float(7 &* basicElement) * farnsworth))
    }

    @objc(setCarrier:)
    func setCarrier(_ freq: Float) {
        carrierFreq = freq
        vco.setCarrier((ook != 0) ? 2500.0 : freq)
    }

    @objc(appendASCII:)
    override func appendASCII(_ ch: Int32) {
        var shortSpace = false

        // ignore opt u, i, `, e, n (e.g., umlaut prefix)
        let firstByte: CChar = (ch >= 0 && ch < 16384) ? ascii[Int(ch)][0] : 0
        if firstByte == 0 {
            //  no user Morse.txt encoding
            if (ch == 168) || (ch == 710) || (ch == 96) || (ch == 180) || (ch == 732) { return }
        }

        var i = ringProducer
        if ch == Int32(UInt8(ascii: " ")) || ch == 5 {
            ring[Int(i)].ascii = ch                             //  v0.37 insert EndOfTransmit as a space with a character 5 (^E)
            ring[Int(i)].duration = interWord - interCharacter
            ring[Int(i)].state = 0
            ringProducer = (i + 1) & 0xfff
            return
        }

        let seq = (ch == 0xd8) ? ascii[Int(UInt8(ascii: "0"))] : ascii[Int(ch & 0x3fff)]
        var p = 0
        if seq[p] == 0 { return }

        var first = true
        //  sanity check, limit to 16 elements
        var j: Int32 = 0
        while true {
            j += 1
            if !(j <= 16) { break }
            ring[Int(i)].ascii = first ? ch : 0
            first = false
            let e = seq[p]; p += 1
            switch e {
            case CChar(UInt8(ascii: ".")):
                ring[Int(i)].duration = dit
                shortSpace = false
            case CChar(UInt8(ascii: "*")):
                ring[Int(i)].duration = (dit &* 3) / 2
                shortSpace = false
            case CChar(UInt8(ascii: "-")):
                ring[Int(i)].duration = dash
                shortSpace = false
            case CChar(UInt8(ascii: "=")):
                ring[Int(i)].duration = (dash &* 3) / 2
                shortSpace = false
            case CChar(UInt8(ascii: "|")):
                ring[Int(i)].duration = interElement
                ring[Int(i)].ascii = 0
                ring[Int(i)].state = 0
                shortSpace = true
                j -= 1                                          // space does not count as an element
            default:
                break
            }
            if !shortSpace {
                ring[Int(i)].state = 1
                i = (i + 1) & 0xfff
                ring[Int(i)].ascii = 0
                ring[Int(i)].duration = interElement
                ring[Int(i)].state = 0
            }
            if seq[p] <= 0 { break }
            i = (i + 1) & 0xfff
        }
        //  change last inter-element to inter-character
        ring[Int(i)].duration = interCharacter
        ringProducer = (i + 1) & 0xfff
    }

    //  Wait for the character stream to flush through
    //  ... and send an end-of-message when we have finished flushing
    @objc(insertEndOfTransmit)
    func insertEndOfTransmit() {
        appendASCII(5)                                          //  v0.37 send 5 into modulator
    }

    // send transmitted character to modem to echo in the exchange view
    @objc(transmittedCharacter:)
    override func transmittedCharacter(_ character: Int32) {
        if let modem = modem, character != 0 {
            modem.transmittedCharacter(character)               //  send to CW modem that the character has been transmitted
        }
    }

    @objc(holdOff:)
    func holdOff(_ milliseconds: Int32) {
        transmitHoldoff = cmPhaseTrunc(Double(milliseconds) * (11025.0 / 1000.0))    //  convert from milliseconds to samples
    }

    @objc(bufferEmpty)
    func bufferEmpty() -> Bool {
        return (ringProducer == ringConsumer && tick <= 0)
    }

    @objc(needData:samples:)
    func needData(_ outbuf: UnsafeMutablePointer<Float>, samples: Int32) -> Int32 {
        //  assume outputSamplingRate = 11025, outputChannels = 1
        assert(samples <= 512)
        var keyedBuf = [Float](repeating: 0, count: 512)

        switch toneIndex {
        case 0:
            if vco != nil {
                keyedBuf.withUnsafeMutableBufferPointer { kb in
                    for i in 0..<Int(samples) {
                        let x: Float
                        let xook: Float
                        if transmitHoldoff > 0 {
                            xook = 0
                            x = CMSimpleFilter(waveshape, xook) * gain
                            transmitHoldoff -= 1
                            if let wbcw = modem as? WBCW { wbcw.keepBreakinAlive(100) }
                        } else {
                            if tick <= 0 {
                                //  check if there are more elements in the ring
                                cwState = 0
                                if ringProducer != ringConsumer {
                                    cwState = ring[Int(ringConsumer)].state
                                    tick = ring[Int(ringConsumer)].duration
                                    let pp = ring[Int(ringConsumer)].ascii
                                    if pp == 5 || pp > 10 { transmittedCharacter(pp) }  // v0.37 echo ^E to end stream
                                    if pp == 5 {
                                        // v0.37 skip over the ^E
                                        return
                                    }
                                    ringConsumer = (ringConsumer + 1) & 0xfff
                                    if let wbcw = modem as? WBCW { wbcw.keepBreakinAlive(tick / 11) }  //  each tick is about 0.09 ms
                                }
                            } else {
                                tick -= 1
                            }
                            xook = (cwState != 0) ? 1.0 : 0.0
                            x = CMSimpleFilter(waveshape, xook) * gain
                        }
                        kb[i] = x
                        let sel: Double = (ook != 0) ? Double(xook) : (Double(x) * 0.78)
                        outbuf[i] = Float(sel * vco.nextSample())               //  v0.88 drop non-ook by 1.28
                    }
                    //  for aural monitor
                    (modem as? WBCW)?.sendSidetoneBuffer(kb.baseAddress)
                }
                return 1
            }
        case 1:
            if testTone != nil {
                for i in 0..<512 {
                    outbuf[i] = Float(testTone.nextSample() * Double(CMSimpleFilter(waveshape, 1.0)) * Double(gain) * 1.1)   //  incorporate waveshape's gain
                }
                return 1
            }
        default:
            break
        }
        for i in 0..<512 { outbuf[i] = 0 }

        return 1 // output channels
    }

    @objc(selectTestTone:)
    func selectTestTone(_ index: Int32) {
        toneIndex = index
    }

    //  called when flushing
    @objc(clearOutput)
    override func clearOutput() {
        ringConsumer = ringProducer
        tick = 0
    }
}
