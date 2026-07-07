//
//  CMFSKDemodulator.swift
//  CoreDSP
//
//  Wires the RTTY receive chain: self -> bandpassFilter -> mixer ->
//  matchedFilter -> atc -> decoder, exactly the pipe topology
//  setupDemodulatorChain built in the original (CMPipe.exportData() forwards
//  each stage's output to the next stage's importData()). The delegate was
//  Objective-C duck-typing (`AnyObject?` + optional-chained @objc methods);
//  here it's a plain Swift protocol with a default no-op implementation.
//
//  Dropped relative to the original: the runtime-swappable CMFSKPipeline
//  (useMatchedFilter:/useBandpassFilter:, the ATCStage duck-typed protocol
//  bridging CMATC vs. SITORBitSync) -- machinery for switching between
//  multiple demodulator variants (RTTY / ASCII / SITOR-B / multipath) at
//  runtime, none of which apply to this single-mode RTTY transplant. The
//  bandwidth (340 Hz) and default tone pair (2125/2295 Hz mark/space,
//  45.45 baud) match RTTYDemodulator's own init(fromReceiver:), which is the
//  actual RTTY-tuned subclass in the old app (as opposed to CMFSKDemodulator's
//  own more generic 306.35 Hz default).
//

import Foundation

protocol CMFSKDemodulatorDelegate: AnyObject {
    func fskReceivedCharacter(_ c: Int32)
}

extension CMFSKDemodulatorDelegate {
    func fskReceivedCharacter(_ c: Int32) {}
}

final class CMFSKDemodulator: CMTappedPipe {

    weak var delegate: CMFSKDemodulatorDelegate?
    var tonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)

    private var bandpassFilter: CMBandpassFilter!
    private let mixer = CMFSKMixer()
    private let matchedFilter: CMFSKMatchedFilter
    private let atc = CMATC()
    private var decoder: CMBaudotDecoder!

    override init() {
        matchedFilter = CMFSKMatchedFilter(defaultFilterWithBaudRate: Float(45.45))
        super.init()

        matchedFilter.setDataRate(Float(tonePair.baud))
        atc.setBitSampling(fromBaudRate: Float(tonePair.baud))
        decoder = CMBaudotDecoder(demodulator: self)
        bandpassFilter = makeFilter(340.0)

        //  connect the pipe chain (importData is exported to bandpassFilter by self)
        atc.setClient(decoder)
        matchedFilter.setClient(atc)
        mixer.setClient(matchedFilter)
        bandpassFilter.setClient(mixer)
    }

    //  send data through the processing chain starting at the bandpass filter
    override func importData(_ pipe: CMPipe!) {
        bandpassFilter.importData(pipe)
    }

    //  return a CMBandpassFilter that has passband centered around the current mark and space carriers.
    private func makeFilter(_ width: Float) -> CMBandpassFilter {
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
    private func updateFilter() {
        let lower: Float, upper: Float
        if tonePair.mark < tonePair.space {
            lower = Float(tonePair.mark)
            upper = Float(tonePair.space)
        } else {
            lower = Float(tonePair.space)
            upper = Float(tonePair.mark)
        }
        var delta = bandpassFilter.userParam()
        if delta < 0.0 { delta = 0.0 }
        bandpassFilter.updateLowCutoff(lower - delta, highCutoff: upper + delta)
    }

    //  set up the tone pair and baud rate parameters of the demodulator.
    //  Unlike the original (which left bandpass repositioning to a separate,
    //  UI-triggered updateFilter: call), this also repositions the bandpass
    //  filter -- this is fresh glue code, not a DSP transplant, and always
    //  repositioning on a shift/baud change is simply correct.
    func setTonePair(_ inTonePair: UnsafePointer<CMTonePair>) {
        tonePair = inTonePair.pointee
        mixer.setTonePair(&tonePair)
        atc.setBitSampling(fromBaudRate: Float(tonePair.baud))
        updateFilter()
    }

    func setEqualizer(_ index: Int32) {
        atc.setEqualize(index)
    }

    //  unshift-on-space, pass it on to the Baudot decoder
    func setUSOS(_ state: Bool) {
        decoder.setUSOS(state)
    }

    func setBell(_ state: Bool) {
        decoder.setBell(state)
    }

    func setSquelch(_ value: Float) {
        atc.setSquelch(value)
    }

    func setInvert(_ isInvert: Bool) {
        atc.setInvert(isInvert)
    }

    //  called from the Baudot decoder when a new character is decoded
    func receivedCharacter(_ c: Int32) {
        delegate?.fskReceivedCharacter(c)
    }
}
