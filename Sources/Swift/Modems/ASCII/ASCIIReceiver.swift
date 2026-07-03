//
//  ASCIIReceiver.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/28/10.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of ASCIIReceiver.m.  Subclass of RTTYReceiver set up for 110 baud
//  ASCII (Baudot -> ASCII) reception.  Accesses the RTTYReceiver base ivars by
//  their exact names.
//

import Cocoa

@objc(ASCIIReceiver)
class ASCIIReceiver: RTTYReceiver {

    @objc(initReceiver:)
    init(receiver index: Int32) {
        let defaultTones = CMTonePair(mark: 2125.0, space: 2295.0, baud: 110.0)

        super.init()

        uniqueID = index
        receiveView = nil
        squelch = nil
        currentTonePair = defaultTones
        enabled = false
        slashZero = false
        sidebandState = false
        demodulatorModeMatrix = nil
        bandwidthMatrix = nil
        appleScript = nil
        usos = true

        //  local CMDataStream
        cmData.pointee.samplingRate = 11025.0
        cmData.pointee.samples = 512
        cmData.pointee.components = 1
        cmData.pointee.channels = 1
        data = cmData
        newData = NSConditionLock(condition: kNoData)
        Thread.detachNewThreadSelector(#selector(receiveThread(_:)), toTarget: self, with: self)
        clickBufferLock = nil

        rttyAuralMonitor = RTTYAuralMonitor()

        demodulator = ASCIIDemodulator(fromReceiver: self)

        bandpassFilter = CMFilterBank()
        matchedFilter = CMFilterBank()

        //  create bandpass filter bank for 110 baud
        bpf[0] = demodulator.makeFilter(275.0)
        bpf[1] = demodulator.makeFilter(500.0)
        bpf[2] = demodulator.makeFilter(830.0)
        bpf[3] = demodulator.makeFilter(1160.0)
        bpf[4] = demodulator.makeFilter(1200.0)
        bandpassFilter.installFilter(bpf[0])
        bandpassFilter.installFilter(bpf[1])
        bandpassFilter.installFilter(bpf[2])
        bandpassFilter.installFilter(bpf[3])
        bandpassFilter.installFilter(bpf[4])
        bandpassFilter.selectFilter(1)
        demodulator.useBandpassFilter(bandpassFilter)

        //  create matched filter bank
        matchedFilter.installFilter(RTTYSingleFilter(tone: 0, baud: 110.0))                  //  Mark-only
        matchedFilter.installFilter(RTTYSingleFilter(tone: 1, baud: 110.0))                  //  Space-only
        matchedFilter.installFilter(RTTYMPFilter(bitWidth: 0.35, baud: 110.0))               //  MP+
        matchedFilter.installFilter(RTTYMPFilter(bitWidth: 0.70, baud: 110.0))               //  MP-
        matchedFilter.installFilter(RTTYMatchedFilter(defaultFilterWithBaudRate: 110.0))     //  MS  v0.32

        matchedFilter.selectFilter(4)
        demodulator.useMatchedFilter(matchedFilter)
    }
}
