//
//  SITORDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/6/06.
//
//  Swift port of SITORDemodulator.m.  SITORDemodulator remains a subclass of
//  the Objective-C class CMFSKDemodulator (CMFSKDemodulator stays Objective-C;
//  its header is in the bridging header).
//
//  Replaces the RTTY ATC and Baudot decoder with the SITOR-B bit sync and
//  Moore decoder.
//

import Cocoa

@objc(SITORDemodulator)
class SITORDemodulator: CMFSKDemodulator {

    private var mooreDecoder: MooreDecoder?

    override func initPipelineStages(_ defaultTonePair: UnsafeMutablePointer<CMTonePair>!,
                                     decoder: CMBaudotDecoder!,
                                     atc: CMPipe!,
                                     bandwidth: Float) {
        var sitorTonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 100.0)

        //  The incoming `decoder` and `atc` were alloc'd by the base
        //  -initFromReceiver: and are discarded here (the original -[release]d
        //  them; under ARC they are simply replaced).
        let md = MooreDecoder(demodulator: self)
        mooreDecoder = md
        let bitSync = SITORBitSync()
        bitSync.setMooreDecoder(md)
        super.initPipelineStages(&sitorTonePair, decoder: md, atc: bitSync, bandwidth: 425.0)
    }

    @objc(setControl:)
    func setControl(_ control: AnyObject?) {
        mooreDecoder?.setControl(control)
    }

    @objc(setErrorPrint:)
    func setErrorPrint(_ state: DarwinBoolean) {
        mooreDecoder?.setErrorPrint(state)
    }
}
