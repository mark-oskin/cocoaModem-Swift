//
//  ModemAuralMonitor.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/12/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of ModemAuralMonitor.m.  Common base of PSKAuralMonitor and
//  RTTYAuralMonitor (both in this batch); a subclass of DestClient.  The DDA
//  (direct digital synthesis) helpers use the shared mssin/lssin/mscos/lscos
//  extern tables (CoreModem.h, in the bridging header).  The four CMFIR* pairs
//  are kept as EXACT-named internal arrays that subclasses index directly.
//

import Cocoa

//  channel indices (kept as free constants, matching the #defines)
let AURALRECEIVE: Int32    = 0
let AURALTRANSMIT: Int32   = 1
let AURALBACKGROUND: Int32 = 2
let AURALMASTER: Int32     = 3

@objc(ModemAuralMonitor)
class ModemAuralMonitor: DestClient {

    @objc var auralMonitor: AuralMonitor!
    @objc var muted: Bool = false
    var masterGain: Float = 0
    @objc var demodulatorIsActive: Bool = false

    //  CMFIR *xxx[2] -- subclasses index these directly by name
    var rxLowpassIFilter: [UnsafeMutablePointer<CMFIR>?] = [nil, nil]
    var rxLowpassQFilter: [UnsafeMutablePointer<CMFIR>?] = [nil, nil]
    var txLowpassIFilter: [UnsafeMutablePointer<CMFIR>?] = [nil, nil]
    var txLowpassQFilter: [UnsafeMutablePointer<CMFIR>?] = [nil, nil]

    var clickBufferActive: Bool = false       //  v0.88
    @objc var resampleClickBuffer: Bool = false      //  v0.88

    override init() {
        super.init()
        auralMonitor = (NSApp.delegate as? AppDelegate)?.auralMonitor() as? AuralMonitor
        muted = true
        masterGain = 1.0
        clickBufferActive = false       //  v0.88
        resampleClickBuffer = false
    }

    //  v0.88 set from modems to indicate the click buffer is active (buffer rates higher than real time)
    @objc(setClickBufferActive:)
    func setClickBufferActive(_ state: Bool) {
        clickBufferActive = state
    }

    @objc(setClickBufferResampling:)
    func setClickBufferResampling(_ state: Bool) {
        resampleClickBuffer = state
    }

    //  v0.88
    @objc func clickBufferBusy() -> Bool {
        return clickBufferActive
    }

    //  v0.88
    @objc func performClickBufferResampling() -> Bool {
        return resampleClickBuffer
    }

    //  theta is scaled so that 0 represents 0 degrees and a full 16 bit number represents 2.pi degrees
    @objc(setDDA:freq:)
    func setDDA(_ dda: UnsafeMutablePointer<CMDDA>, freq: Float) {
        dda.pointee.freq = freq
        dda.pointee.deltaTheta = (262144.0) * Double(freq) / CMFs
        dda.pointee.theta = 0.0
        dda.pointee.cost = 1.0
        dda.pointee.sint = 0.0
    }

    //  update sine and cosine to the next time sample; return sine
    @objc(updateDDA:)
    func updateDDA(_ dda: UnsafeMutablePointer<CMDDA>) -> CMAnalyticPair {
        dda.pointee.theta += dda.pointee.deltaTheta
        var th = dda.pointee.theta
        if th > 262144.0 {
            th -= 262144.0
            dda.pointee.theta = th
        }
        let t = Int(th)
        let mst = (t >> 10)
        let lst = t & 0x3ff

        //  v0.76 performance tune
        let sina = Double(mssin[mst])
        let cosa = Double(mscos[mst])
        let sinb = Double(lssin[lst])
        let cosb = Double(lscos[lst])
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        dda.pointee.sint = sina * cosb + cosa * sinb
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        dda.pointee.cost = cosa * cosb - sina * sinb

        var p = CMAnalyticPair()
        p.re = Float(dda.pointee.cost)
        p.im = Float(dda.pointee.sint)
        return p
    }
}
