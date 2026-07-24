//
//  DestClient.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/1/06.
//  Swift port of DestClient.m.  DestClient stays a subclass of CMTappedPipe
//  (now also Swift in the converted CMPipe tree).  It is the common base of
//  ModemConfig, AuralMonitor, ModemAuralMonitor and the various monitors; the
//  two entry points below are overridden by those subclasses.
//

import Cocoa

@objc(DestClient)
class DestClient: CMTappedPipe {

    //  override by class instance (e.g. ModemConfig / AuralMonitor)
    @objc(setOutputScale:)
    func setOutputScale(_ value: Float) {
        // override from ModemConfig.m
    }

    //  ResamplingPipe callback
    @objc(needData:samples:)
    func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples n: Int32) -> Int32 {
        // override from ModemConfig.m
        return 0
    }

    //  stereo ResamplingPipe callback (overridden by AuralMonitor; called by PushedStereoDest)
    @objc(needData:samples:channels:)
    func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples n: Int32, channels ch: Int32) -> Int32 {
        return 0
    }
}
