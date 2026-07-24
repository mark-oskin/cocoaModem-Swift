//
//  CMFSKDemodulator.swift
//  CoreModem
//
//  Created by Kok Chen on 10/24/05.
//  Swift port of CMFSKDemodulator.m.
//
//  FSK (RTTY / ASCII / SITOR / CW base) demodulator.  Subclass of CMTappedPipe.
//
//  Port notes:
//   * The C held its pipeline stages in a malloc'd CMFSKPipeline (a void* cast
//     from `pipeline`).  Because that struct -- and every class that cast the
//     void* -- lives entirely inside this conversion batch, the malloc'd struct
//     is replaced by a Swift `CMFSKPipeline` object (ARC owns the stages; the
//     manual retain/release in -dealloc becomes ARC, and useBandpass/Matched
//     simply reassign).  CMFSKTypes.h (the C CMFSKPipeline) is now unused.
//   * The `atc` stage is duck-typed in the C: it is a CMATC for RTTY/ASCII but a
//     SITORBitSync for SITOR-B (both CMTappedPipe subclasses exposing the same
//     ATC selectors).  It is stored as CMTappedPipe and the ATC selectors are
//     reached through the @objc `ATCStage` protocol (empty retroactive
//     conformances below), matching the original Obj-C dynamic dispatch.
//   * `initSuper` (a bare `[super init]` helper) is dropped: subclasses now call
//     `super.init()` directly, which is exactly what it did.
//   * The ivars `receiver`, `isRTTY` and `delegate` collide with same-named
//     Obj-C accessor selectors, so the stored properties keep the names and the
//     accessors are `receiverObject()` / `isRTTYState()` / `delegateObject()`
//     with explicit @objc selectors.
//

import Cocoa

//  ATC-stage selectors shared by CMATC (Obj-C) and SITORBitSync (Swift).
@objc protocol ATCStage {
    @objc(setInvert:) func setInvert(_ isInvert: DarwinBoolean)
    @objc(setBitSamplingFromBaudRate:) func setBitSampling(fromBaudRate baudrate: Float)
    @objc(setEqualize:) func setEqualize(_ mode: Int32)
    @objc(setSquelch:) func setSquelch(_ value: Float)
    @objc(atcWaveformBuffer) func atcWaveformBuffer() -> CMPipe?
}

extension CMATC: ATCStage {}
extension SITORBitSync: ATCStage {}

//  Swift replacement for the malloc'd CMFSKPipeline (CMFSKTypes.h).
class CMFSKPipeline {
    //  The bandpass and matched stages are generic pipes in the original C
    //  (CMPipe*): RTTY/ASCII/SITOR install a CMFilterBank here, while the plain
    //  FSK path installs a CMBandpassFilter / CMFSKMatchedFilter.  All are
    //  CMTappedPipe subclasses and only pipe-level methods are used, so the
    //  fields must be CMTappedPipe — narrowing them crashed useBandpassFilter:.
    var bandpassFilter: CMTappedPipe?
    var originalBandpassFilter: CMTappedPipe?
    var mixer: CMPipe?                          //  CMFSKMixer (RTTY) or CWMixer (CW)
    var matchedFilter: CMTappedPipe?
    var originalMatchedFilter: CMTappedPipe?
    var atc: CMTappedPipe?                       //  CMATC or SITORBitSync
    var decoder: CMBaudotDecoder?
}

@objc(CMFSKDemodulator)
class CMFSKDemodulator: CMTappedPipe {

    weak var delegate: AnyObject?
    internal var tonePair = CMTonePair(mark: 0, space: 0, baud: 0)
    internal var pipeline: CMFSKPipeline!
    weak var receiver: RTTYReceiver?
    //  RTTY polarity
    internal var sidebandState: Bool = false
    internal var isRTTY: Bool = false

    override init() {
        super.init()
    }

    //  Initialize default filters
    @objc(initPipelineStages:decoder:atc:bandwidth:)
    func initPipelineStages(_ pair: UnsafeMutablePointer<CMTonePair>!, decoder: CMBaudotDecoder!, atc: CMPipe!, bandwidth: Float) {
        isRTTY = true
        tonePair = pair.pointee
        let p = CMFSKPipeline()
        pipeline = p

        // -- bandpass filter
        p.bandpassFilter = makeFilter(bandwidth)
        p.originalBandpassFilter = p.bandpassFilter

        // -- matched filter, change baud rate to match tone pair
        let matchedFilter = CMFSKMatchedFilter(defaultFilterWithBaudRate: Float(tonePair.baud))
        matchedFilter.setDataRate(Float(tonePair.baud))
        p.matchedFilter = matchedFilter
        p.originalMatchedFilter = matchedFilter

        //  -- RTTY mixer
        let mixer = RTTYMixer()
        p.mixer = mixer
        mixer.setTonePair(&tonePair)
        mixer.setDemodulator(self)                  //  v0.78
        mixer.setAuralMonitor(receiver?.rttyAuralMonitor)
        //  -- adaptive thresholder
        let atcStage = atc as? CMTappedPipe
        p.atc = atcStage
        (atcStage as? ATCStage)?.setInvert(DarwinBoolean(sidebandState))
        (atcStage as? ATCStage)?.setBitSampling(fromBaudRate: Float(tonePair.baud))

        //  -- Baudot decoder, sends data back to -receivedCharacter: of self
        p.decoder = decoder
    }

    @objc(initFromReceiver:)
    init(fromReceiver rcvr: RTTYReceiver?) {
        super.init()
        isRTTY = true
        delegate = nil
        receiver = rcvr
        let decoder = CMBaudotDecoder(demodulator: self)
        let atc = CMATC()
        var defaultTonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)
        initPipelineStages(&defaultTonePair, decoder: decoder, atc: atc, bandwidth: 306.35)
    }

    @objc(receiver)
    func receiverObject() -> RTTYReceiver? {
        return receiver
    }

    @objc(isRTTY)
    func isRTTYState() -> Bool {
        return isRTTY
    }

    @objc(mixer)
    func mixer() -> CMFSKMixer? {
        return pipeline?.mixer as? CMFSKMixer
    }

    @objc(makeDemodulatorActive:)
    func makeDemodulatorActive(_ state: Bool) {
        if isRTTY, let r = receiver { r.rttyAuralMonitor?.setDemodulatorActive(state) }
    }

    @objc(replaceDecoderWith:)
    func replaceDecoder(with decoder: CMBaudotDecoder!) {
        if let decoder = decoder {
            pipeline?.decoder = decoder
        }
    }

    //  overide base class to change AudioPipe pipeline (assume source is normalized baud rate)
    //		self (importData:)
    //		. bandpassFilter
    //		. mixer
    //		. matchedFilter
    //		. ATC
    //		. BaudotDecoder
    //		. self (receivedCharacter:)
    @objc(setupDemodulatorChain)
    func setupDemodulatorChain() {
        let p = pipeline!
        //  connect AudioPipes
        p.atc?.setClient(p.decoder)
        p.matchedFilter?.setClient(p.atc)
        p.mixer?.setClient(p.matchedFilter)
        p.bandpassFilter?.setClient(p.mixer)
        setClient(p.bandpassFilter)                 //  importData is exported to bandpassFilter by base class
    }

    //  v0.88d
    @objc(setConfig:)
    func setConfig(_ config: ModemConfig!) {
        (pipeline?.mixer as? CMFSKMixer)?.setConfig(config)
    }

    @objc(setBitsPerCharacter:)
    func setBitsPerCharacter(_ bits: Int32) {
        (pipeline?.atc as? CMATC)?.setBitsPerCharacter(bits)
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        //  send data through the processing chain starting at the bandpass filter
        pipeline?.bandpassFilter?.importData(pipe)
    }

    //  v0.76 tap client (used by RTTYMonitor) is now the matched filter output
    @objc(setTap:)
    override func setTap(_ tap: CMPipe!) {
        pipeline?.matchedFilter?.setTap(tap)
    }

    //  return a CMBandpassFilter that has passband centered around the current mark and space carriers.
    @objc(makeFilter:)
    func makeFilter(_ width: Float) -> CMBandpassFilter? {
        let lower: Float, upper: Float
        if tonePair.mark < tonePair.space {
            lower = Float(tonePair.mark)
            upper = Float(tonePair.space)
        } else {
            lower = Float(tonePair.space)
            upper = Float(tonePair.mark)
        }
        let shift = upper - lower
        var delta = (width - shift) * 0.5
        if delta < 0.0 { delta = 0.0 }

        let f = CMBandpassFilter(lowCutoff: lower - delta, highCutoff: upper + delta, length: 256)
        f.setUserParam(delta)
        return f
    }

    //  retrieves userParam from bandpass filter and update passband based on current mark and space
    @objc(updateFilter:)
    func updateFilter(_ f: CMBandpassFilter!) {
        let lower: Float, upper: Float
        if tonePair.mark < tonePair.space {
            lower = Float(tonePair.mark)
            upper = Float(tonePair.space)
        } else {
            lower = Float(tonePair.space)
            upper = Float(tonePair.mark)
        }
        var delta = f.userParam()
        if delta < 0.0 { delta = 0.0 }
        f.updateLowCutoff(lower - delta, highCutoff: upper + delta)
    }

    @objc(setDelegate:)
    func setDelegate(_ inDelegate: AnyObject?) {
        delegate = inDelegate
    }

    @objc(delegate)
    func delegateObject() -> AnyObject? {
        return delegate
    }

    //  called from Baudot decoder when a new character is decoded
    @objc(receivedCharacter:)
    func receivedCharacter(_ c: Int32) {
        guard let d = delegate as? NSObject else { return }
        let sel = NSSelectorFromString("receivedCharacter:")
        if d.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Void
            let fn = unsafeBitCast(d.method(for: sel), to: Fn.self)
            fn(d, sel, c)
        }
    }

    @objc(useMatchedFilter:)
    func useMatchedFilter(_ mf: CMPipe!) {
        let p = pipeline!
        if p.matchedFilter === mf { return }
        mf.setClient(p.atc)
        p.mixer?.setClient(mf)
        p.matchedFilter = (mf as! CMTappedPipe)
    }

    @objc(useBandpassFilter:)
    func useBandpassFilter(_ bpf: CMPipe!) {
        guard let p = pipeline else { return }
        if p.bandpassFilter === bpf { return }
        bpf.setClient(p.mixer)
        setClient(bpf)
        p.bandpassFilter = (bpf as! CMTappedPipe)
    }

    //  set up the tone pair and baud rate parameters of the demodulator
    @objc(setTonePair:)
    func setTonePair(_ inTonePair: UnsafePointer<CMTonePair>!) {
        tonePair = inTonePair.pointee
        (pipeline?.mixer as? CMFSKMixer)?.setTonePair(&tonePair)
        (pipeline?.atc as? ATCStage)?.setBitSampling(fromBaudRate: Float(tonePair.baud))
    }

    @objc(setEqualizer:)
    func setEqualizer(_ index: Int32) {
        (pipeline?.atc as? ATCStage)?.setEqualize(index)
    }

    //  unshift-on-space, pass it on to the Baudot decoder
    @objc(setUSOS:)
    func setUSOS(_ state: Bool) {
        pipeline?.decoder?.setUSOS(state)
    }

    @objc(setBell:)
    func setBell(_ state: Bool) {
        pipeline?.decoder?.setBell(state)
    }

    @objc(setLTRS:)
    func setLTRS(_ state: Bool) {
        pipeline?.decoder?.setLTRS()
    }

    @objc(setSquelch:)
    func setSquelch(_ value: Float) {
        (pipeline?.atc as? ATCStage)?.setSquelch(value)
    }

    @objc(baudotWaveform)
    func baudotWaveform() -> CMPipe? {
        return pipeline?.atc
    }

    @objc(atcWaveform)
    func atcWaveform() -> CMPipe? {
        return (pipeline?.atc as? ATCStage)?.atcWaveformBuffer()
    }
}
