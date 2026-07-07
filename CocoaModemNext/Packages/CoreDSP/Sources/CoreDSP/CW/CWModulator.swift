//
//  CWModulator.swift
//  CoreDSP
//
//  Swift port of the old app's CWModulator.swift (Wideband CW / Morse
//  modulator). The original subclassed RTTYModulator (rig-control / PTT /
//  output-equalizer plumbing that lives outside CoreDSP's scope, and isn't
//  ported elsewhere in this codebase either); here it is a self-contained
//  internal class. Dropped along with RTTYModulator: the OOK keying-mode
//  switch, the built-in test-tone generator, the output-attenuator/equalizer
//  boost, and the "keepBreakinAlive" call into the old WBCW rig-control
//  coordinator (all rig-hardware / UI features, not DSP). Everything else --
//  the ring of Morse elements, the Blackman-window keying waveshape, and the
//  dit/dash/element timing arithmetic -- is transplanted as-is, including the
//  wrapping (&+, &*) integer arithmetic.
//
//  NOTE: one Morse element at 50 wpm is approx 264 samples at 11025 s/s.
//

import Foundation

//  Morse element queued in the ring (was MorseElementType in CWModulator.h)
private struct CWMorseElement {
    var ascii: Int32 = 0
    var state: Int32 = 0
    var duration: Int32 = 0
}

protocol CWModulatorDelegate: AnyObject {
    /// Echo of a character as it is actually keyed out (mirrors the original's
    /// -transmittedCharacter: callback into the modem, e.g. to highlight sent
    /// text in a UI); ^E (5) marks the end-of-transmit marker.
    func cwTransmittedCharacter(_ ascii: Int32)
}

extension CWModulatorDelegate {
    func cwTransmittedCharacter(_ ascii: Int32) {}
}

final class CWModulator {

    weak var delegate: CWModulatorDelegate?

    private let vco = CMPCO()
    private var gain: Float = 1.0

    private var waveshape: UnsafeMutablePointer<CMFIR>!
    private var speed: Float = 25.0
    private var weight: Float = 0.5
    private var ratio: Float = 3.0
    private var farnsworth: Float = 1.0

    //  morse element ring
    private var tick: Int32 = 0
    private var cwState: Int32 = 0
    private var ringProducer: Int32 = 0
    private var ringConsumer: Int32 = 0
    private var ring = [CWMorseElement](repeating: CWMorseElement(), count: 4096)

    private var transmitHoldoff: Int32 = 0

    private var interElement: Int32 = 0
    private var dit: Int32 = 0
    private var dash: Int32 = 0
    private var interCharacter: Int32 = 0
    private var interWord: Int32 = 0

    init() {
        waveshape = BlackmanWindow(131, 300)   //  width 131 = approx 5 ms rise and fall times
        vco.setCarrier(750.0)
        vco.setOutputScale(1.0)
        setSpeed(speed)
    }

    func setGain(_ v: Float) { gain = v }

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
    func setSpeed(_ inSpeed: Float) {
        speed = inSpeed
        let basicElement = cmPhaseTrunc(264.0 * 50.0 / Double(speed))

        interElement = cmPhaseTrunc(2.0 * Double(1 - weight) * Double(basicElement))
        dit = cmPhaseTrunc(2.0 * Double(weight) * Double(basicElement))
        dash = cmPhaseTrunc(Double(ratio * Float(dit)))
        interCharacter = cmPhaseTrunc(Double(Float(3 &* basicElement) * farnsworth))   // farnsworth is between 1.0 (normal) and 5.0
        interWord = cmPhaseTrunc(Double(Float(7 &* basicElement) * farnsworth))
    }

    func setCarrier(_ freq: Float) {
        vco.setCarrier(freq)
    }

    func appendASCII(_ ch: Int32) {
        var shortSpace = false

        var i = ringProducer
        if ch == Int32(UInt8(ascii: " ")) || ch == 5 {
            ring[Int(i)].ascii = ch     //  v0.37 insert EndOfTransmit as a space with a character 5 (^E)
            ring[Int(i)].duration = interWord - interCharacter
            ring[Int(i)].state = 0
            ringProducer = (i &+ 1) & 0xfff
            return
        }

        //  slashed-zero call-sign glyph (0xd8) maps to '0', matching the original
        let lookupCh = (ch == 0xd8) ? Int32(UInt8(ascii: "0")) : ch
        guard lookupCh >= 0, lookupCh < 128, let sequence = CWMorseEncodeTable.table[UInt8(lookupCh)], !sequence.isEmpty else { return }
        let seq = Array(sequence.utf8)
        var p = 0

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
            case UInt8(ascii: "."):
                ring[Int(i)].duration = dit
                shortSpace = false
            case UInt8(ascii: "*"):
                ring[Int(i)].duration = (dit &* 3) / 2
                shortSpace = false
            case UInt8(ascii: "-"):
                ring[Int(i)].duration = dash
                shortSpace = false
            case UInt8(ascii: "="):
                ring[Int(i)].duration = (dash &* 3) / 2
                shortSpace = false
            case UInt8(ascii: "|"):
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
                i = (i &+ 1) & 0xfff
                ring[Int(i)].ascii = 0
                ring[Int(i)].duration = interElement
                ring[Int(i)].state = 0
            }
            if p >= seq.count { break }
            i = (i &+ 1) & 0xfff
        }
        //  change last inter-element to inter-character
        ring[Int(i)].duration = interCharacter
        ringProducer = (i &+ 1) & 0xfff
    }

    //  Wait for the character stream to flush through, marking an end-of-message.
    func insertEndOfTransmit() {
        appendASCII(5)   //  v0.37 send 5 into modulator
    }

    func holdOff(_ milliseconds: Int32) {
        transmitHoldoff = cmPhaseTrunc(Double(milliseconds) * (CMFs / 1000.0))   //  convert from milliseconds to samples
    }

    func bufferEmpty() -> Bool {
        return ringProducer == ringConsumer && tick <= 0
    }

    /// Fill `outbuf` with `samples` (<= 512) of keyed CW audio.
    func produceSamples(_ outbuf: UnsafeMutablePointer<Float>, samples: Int32) {
        assert(samples <= 512)
        for i in 0..<Int(samples) {
            let x: Float
            let xook: Float
            if transmitHoldoff > 0 {
                xook = 0
                x = CMSimpleFilter(waveshape, xook) * gain
                transmitHoldoff -= 1
            } else {
                if tick <= 0 {
                    //  check if there are more elements in the ring
                    cwState = 0
                    if ringProducer != ringConsumer {
                        cwState = ring[Int(ringConsumer)].state
                        tick = ring[Int(ringConsumer)].duration
                        let pp = ring[Int(ringConsumer)].ascii
                        if pp == 5 || pp > 10 { delegate?.cwTransmittedCharacter(pp) }   // v0.37 echo ^E to end stream
                        ringConsumer = (ringConsumer &+ 1) & 0xfff
                        if pp == 5 {
                            //  v0.37 skip over the ^E -- unlike the original (which
                            //  aborted the whole buffer here, leaving the remainder
                            //  of `outbuf` unwritten), emit silence for this sample
                            //  and keep filling the rest of the requested buffer.
                            outbuf[i] = 0
                            continue
                        }
                    }
                } else {
                    tick -= 1
                }
                xook = (cwState != 0) ? 1.0 : 0.0
                x = CMSimpleFilter(waveshape, xook) * gain
            }
            outbuf[i] = Float(Double(x) * 0.78 * vco.nextSample())
        }
    }

    //  called when flushing
    func clearOutput() {
        ringConsumer = ringProducer
        tick = 0
    }
}
