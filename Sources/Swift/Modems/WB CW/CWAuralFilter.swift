//
//  CWAuralFilter.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/11/07.
//  Swift port of CWAuralFilter.m.
//
//  CW aural (listen-through) filter.  Subclass of CWDemodulator.  Only the CW
//  mixer stage is used -- there is no matched filter and no Morse decoder.
//

import Cocoa

@objc(CWAuralFilter)
class CWAuralFilter: CWDemodulator {

    //  NOTE: the aural filter does not have a morse decoder pipeline
    @objc(initPipelineStages:decoder:bandwidth:)
    override func initPipelineStages(_ pair: UnsafeMutablePointer<CMTonePair>!, decoder: MorseDecoder!, bandwidth: Float) {
        tonePair = pair.pointee
        let p = CMFSKPipeline()
        pipeline = p
        // -- bandpass filter (none)
        p.bandpassFilter = nil
        p.originalBandpassFilter = nil
        //  -- CW mixer (mixes signal to I&Q baseband)
        let mixer = CWMixer()
        p.mixer = mixer
        mixer.setTonePair(&tonePair)
        mixer.setAural(true)
        //  unused plug-ins aural filter
        p.decoder = nil
        p.atc = nil
        p.matchedFilter = nil
        p.originalMatchedFilter = nil
    }

    @objc(setCWBandwidth:)
    override func setCWBandwidth(_ bandwidth: Float) {
        (pipeline?.mixer as? CWMixer)?.setCWBandwidth(bandwidth)
    }

    @objc(initFromReceiver:)
    override init(fromReceiver rcvr: RTTYReceiver?) {
        super.init()
        receiver = rcvr
        delegate = nil
        var defaultTonePair = CMTonePair(mark: 1500.0, space: 0.0, baud: 45.45)
        initPipelineStages(&defaultTonePair, decoder: nil, bandwidth: 100.0)
    }

    deinit {
        setClient(nil)
    }

    //  overide base class to change AudioPipe pipeline (assume source is normalized baud rate)
    //		self = CWDemodulator (importData:)
    //		. mixer
    //		. aural monitor
    @objc(setupDemodulatorChain)
    override func setupDemodulatorChain() {
        //  connect AudioPipes (only mixer is used)
        (pipeline?.mixer as? CWMixer)?.setReceiver(receiver as? CWReceiver)
    }
}
