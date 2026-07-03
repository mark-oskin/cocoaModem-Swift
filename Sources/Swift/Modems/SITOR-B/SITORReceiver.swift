//
//  SITORReceiver.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/6/06.
//  Swift port of SITORReceiver.m.
//
//  Subclass of RTTYReceiver for SITOR-B (100 baud).  Uses -initSuperReceiver:
//  (which only does the base [super init], i.e. no click buffer / receive thread
//  / cmData) and builds its own filter banks.  Base ivars are accessed by their
//  exact RTTYReceiver names.
//

import Cocoa

@objc(SITORReceiver)
class SITORReceiver: RTTYReceiver {

    @objc(initReceiver:modem:)
    override init(receiver index: Int32, modem: Modem!) {
        let defaultTones = CMTonePair(mark: 2125.0, space: 2295.0, baud: 100.0)
        var mf: CMFSKMatchedFilter!
        let baudrate: Float = 100.0

        super.init(superReceiver: index)

        uniqueID = index
        app = modem.application()               //  v0.96d
        receiveView = nil
        squelch = nil
        currentTonePair = defaultTones
        enabled = false
        slashZero = false
        sidebandState = false
        appleScript = nil
        usos = true

        //  v0.79 bugfix -- was calling init instead of initFromReceiver
        demodulator = SITORDemodulator(fromReceiver: self)

        bandpassFilter = CMFilterBank()
        matchedFilter = CMFilterBank()

        //  create bandpass filter bank
        bpf[0] = demodulator.makeFilter(300.0)
        bpf[1] = demodulator.makeFilter(425.0)
        bpf[2] = demodulator.makeFilter(600.0)
        bpf[3] = demodulator.makeFilter(725.0)
        bpf[4] = demodulator.makeFilter(1000.0)
        bandpassFilter.installFilter(bpf[0])
        bandpassFilter.installFilter(bpf[1])
        bandpassFilter.installFilter(bpf[2])
        bandpassFilter.installFilter(bpf[3])
        bandpassFilter.installFilter(bpf[4])
        bandpassFilter.selectFilter(1)
        demodulator.useBandpassFilter(bandpassFilter)

        //  create matched filter bank
        mf = RTTYSingleFilter(tone: 0, baud: baudrate)
        mf.setDataRate(baudrate)
        matchedFilter.installFilter(mf)             //  Mark-only

        mf = RTTYSingleFilter(tone: 1, baud: baudrate)
        mf.setDataRate(baudrate)
        matchedFilter.installFilter(mf)             //  Space-only

        mf = RTTYMPFilter(bitWidth: 0.35, baud: baudrate)
        mf.setDataRate(baudrate)
        matchedFilter.installFilter(mf)             //  MP+

        mf = RTTYMPFilter(bitWidth: 0.70, baud: baudrate)
        mf.setDataRate(baudrate)
        matchedFilter.installFilter(mf)             //  MP-

        mf = CMFSKMatchedFilter(defaultFilterWithBaudRate: baudrate)
        mf.setDataRate(baudrate)
        matchedFilter.installFilter(mf)             //  MS

        matchedFilter.selectFilter(4)
        demodulator.useMatchedFilter(matchedFilter)
    }

    @objc(setControl:)
    func setControl(_ control: SITORRxControl!) {
        if demodulator != nil { (demodulator as? SITORDemodulator)?.setControl(control) }
    }

    //  test
    @objc(setSquelchValue:)
    override func setSquelchValue(_ value: Float) {
        if squelch != nil {
            squelch.floatValue = value
            demodulator.setSquelch(value)
        }
    }
}
