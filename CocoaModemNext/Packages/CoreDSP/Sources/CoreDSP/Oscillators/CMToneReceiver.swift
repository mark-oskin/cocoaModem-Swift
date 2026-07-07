import Foundation
//
//  CMToneReceiver.swift
//  CoreModem
//
//  Created by Kok Chen on 11/03/05
//	Ported from cocoaModem, original file dated 7/29/05.
//
//  Swift port of CMToneReceiver.m.  CMToneReceiver is a CMTappedPipe subclass
//  and the base of the tone-frequency receivers (PSK / FAX / Hell / RTTY).  The
//  whole CMPipe tree converts to Swift together; base ivars (outputClient,
//  staticStream, data, isPipelined, tapClient) are accessed as inherited stored
//  properties by their original names.
//


class CMToneReceiver: CMTappedPipe {

    //  ---- ivars (exact original names; internal so subclasses in the module see them) ----
    //  original ivar "receiverEnabled" renamed: PSKDemodulator exposes a
    //  -receiverEnabled *method* (called as receiverEnabled() by Swift PSKHub),
    //  which would collide with a stored property of the same name.
    internal var receiverEnabledFlag: Bool = false
    internal var frequencyLocked: Bool = false
    internal var lockProcessStarted: Bool = false
    internal var acquire: Int32 = 0                 //  afc acquisition

    internal var vco: CMPCO!
    //  ivar receiveFrequency doubles as the -receiveFrequency / -setReceiveFrequency: accessors
    var receiveFrequency: Float = 10

    internal var goertzelWindow: UnsafeMutablePointer<Float>!

    override init() {
        super.init()

        //  set up VCO at tone's frequency
        receiveFrequency = 10               // for now
        vco = CMPCO()
        vco.setCarrier(receiveFrequency)

        receiverEnabledFlag = false
        frequencyLocked = false
        lockProcessStarted = false
        acquire = 0
        goertzelWindow = CMMakeBlackmanWindow(256)
    }

    //  return power at frequency using Goertzel algorithm (256 samples)
    func goertzel(_ x: UnsafeMutablePointer<Float>, freq center: Float) -> Float {
        var d0: Float = 0, d1: Float = 0, d2: Float
        let s = Float(cos(2.0 * CMPi * 16.0 / CMFs * Double(center)))

        for i in 0..<256 {
            d2 = d1
            d1 = d0
            d0 = 2 * s * d1 - d2 + goertzelWindow[i] * x[i]
        }
        return d0 * d0 + d1 * d1 - 2 * s * d0 * d1
    }

    func goertzel(_ x: UnsafeMutablePointer<Float>, imag y: UnsafeMutablePointer<Float>, freq center: Float) -> Float {
        return goertzel(x, freq: center) + goertzel(y, freq: center)
    }

    func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        receiverEnabledFlag = true
        frequencyLocked = false
        lockProcessStarted = false          // acquisition phase
        acquire = 1

        receiveFrequency = freq
        if vco != nil { vco.setCarrier(freq) }
    }

    func enableReceiver(_ state: Bool) {
        receiverEnabledFlag = state
    }

    func isEnabled() -> Bool {
        return receiverEnabledFlag
    }
}
