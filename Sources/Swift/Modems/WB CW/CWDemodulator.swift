//
//  CWDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/2/06.
//  Swift port of CWDemodulator.m.
//
//  CW (Morse) demodulator.  Subclass of CMFSKDemodulator.  The C used a private
//  CWDemodPipelineStages struct (layout-compatible with CMFSKPipeline but typed
//  for CWMixer / CWMatchedFilter / MorseDecoder).  Here the shared Swift
//  CMFSKPipeline holds the stages (base-typed) and this class casts to the CW
//  concrete types at the call sites.  isRTTY is NO, there is no bandpass filter
//  and no ATC.
//

import Cocoa

@objc(CWDemodulator)
class CWDemodulator: CMFSKDemodulator {

    override init() {
        super.init()
    }

    @objc(initPipelineStages:decoder:bandwidth:)
    func initPipelineStages(_ pair: UnsafeMutablePointer<CMTonePair>!, decoder: MorseDecoder!, bandwidth: Float) {
        isRTTY = false
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
        mixer.setAural(false)
        // -- matched filter, change baud rate to match tone pair
        let matchedFilter = CWMatchedFilter(defaultFilterWithBaudRate: 100.0)
        p.matchedFilter = matchedFilter
        p.originalMatchedFilter = matchedFilter
        //  -- Morse decoder, sends data back to -receivedCharacter: of self
        p.decoder = decoder
        //  unused CW plug-ins
        p.atc = nil
    }

    @objc(setLatency:)
    func setLatency(_ value: Int32) {
        (pipeline?.matchedFilter as? CWMatchedFilter)?.setLatency(value)
    }

    @objc(setCWBandwidth:)
    func setCWBandwidth(_ bandwidth: Float) {
        //  use constant 250 Hz filter for automatic decoding
        (pipeline?.mixer as? CWMixer)?.setCWBandwidth(300.0)
    }

    @objc(useMatchedFilter:)
    override func useMatchedFilter(_ mf: CMPipe!) {
        //  matched filter bank not used in CW mode
    }

    @objc(initFromReceiver:)
    override init(fromReceiver rcvr: RTTYReceiver?) {
        super.init()
        receiver = rcvr
        delegate = nil
        let dec = MorseDecoder(demodulator: self)
        var defaultTonePair = CMTonePair(mark: 1500.0, space: 0.0, baud: 45.45)
        initPipelineStages(&defaultTonePair, decoder: dec, bandwidth: 100.0)
    }

    deinit {
        setClient(nil)
    }

    //  overide base class to change AudioPipe pipeline (assume source is normalized baud rate)
    //		self = CWDemodulator (importData:)
    //		. mixer
    //		. "matched filter"
    //		. MorseDecoder
    //		. self (receivedCharacter:)
    @objc(setupDemodulatorChain)
    override func setupDemodulatorChain() {
        let mf = pipeline?.matchedFilter as? CWMatchedFilter
        //  connect AudioPipes
        mf?.setDecoder(pipeline?.decoder as? MorseDecoder, receiver: receiver as? CWReceiver)
        mf?.setClient(pipeline?.decoder)
        pipeline?.mixer?.setClient(pipeline?.matchedFilter)
        (pipeline?.mixer as? CWMixer)?.setReceiver(receiver as? CWReceiver)
    }

    @objc(newClick:)
    func newClick(_ delta: Float) {
        (pipeline?.matchedFilter as? CWMatchedFilter)?.newClick(delta)
    }

    @objc(changeCodeSpeedTo:)
    func changeCodeSpeed(to speed: Int32) {
        (pipeline?.matchedFilter as? CWMatchedFilter)?.changeCodeSpeed(to: speed)
    }

    @objc(changeSquelchTo:fastQSB:slowQSB:)
    func changeSquelch(to squelch: Float, fastQSB fast: Float, slowQSB slow: Float) {
        (pipeline?.matchedFilter as? CWMatchedFilter)?.setSquelch(squelch, fastQSB: fast, slowQSB: slow)
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        //  send data through the processing chain starting at the mixer
        pipeline?.mixer?.importData(pipe)
    }

    //  return a nil.
    //  the BPF is no longer used in the CW mode
    @objc(makeFilter:)
    override func makeFilter(_ width: Float) -> CMBandpassFilter? {
        return nil
    }
}
