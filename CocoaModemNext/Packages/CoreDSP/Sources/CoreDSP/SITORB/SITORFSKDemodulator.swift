//
//  SITORFSKDemodulator.swift
//  CoreDSP
//
//  Wires the SITOR-B receive chain: self -> bandpassFilter -> mixer ->
//  matchedFilter -> bitSync -> decoder, the same CMPipe.exportData()
//  cascade topology as RTTY's CMFSKDemodulator (RTTY/CMFSKDemodulator.swift)
//  -- and, in fact, reuses RTTY's already-ported CMFSKMixer and
//  CMFSKMatchedFilter verbatim (both are generic FSK-to-baseband /
//  matched-filter-plus-decimate stages with no RTTY-specific behavior; only
//  the bandwidth, tone pair, baud rate and the bit-sync/decoder stages that
//  follow differ between the two modes). What's genuinely SITOR-B-specific
//  is the bit-sync (SITORBitSync's comb-filter clock recovery, quite
//  different from RTTY's CMATC adaptive-threshold approach) and the Moore/
//  CCIR-476 FEC decoder (MooreDecoder) -- both fresh ports in this subfolder.
//
//  This orchestrator itself is fresh glue (not a transplant of a specific
//  original file): the original's SITORReceiver.swift built a whole tunable
//  bandpass/matched-filter *bank* (5 bandwidths, 5 matched filter variants
//  selectable at runtime, matching RTTYReceiver's generic UI) and left the
//  actual chain wiring to CMFSKDemodulator.initPipelineStages (an
//  Objective-C class not present in this transplant -- see
//  SITORDemodulator.swift's doc comment). This port fixes the bandwidth and
//  matched filter to the bank's *default selection*
//  (bandpassFilter index 1 == 425 Hz, matchedFilter index 4 == the plain
//  mark+space CMFSKMatchedFilter) rather than porting the unused bank
//  machinery, exactly the "fresh, minimal glue" the task calls for.
//
//  Mark/space/baud (2125/2295 Hz, 100 baud) match SITORReceiver's own
//  `defaultTones` and the standard CCIR-476 SITOR-B/NAVTEX parameters.
//

import Foundation

protocol SITORDemodulatorDelegate: AnyObject {
    func sitorReceivedCharacter(_ c: Int32)
    func sitorSyncStateChanged(_ state: SITORSyncState)
}

extension SITORDemodulatorDelegate {
    func sitorReceivedCharacter(_ c: Int32) {}
    func sitorSyncStateChanged(_ state: SITORSyncState) {}
}

final class SITORFSKDemodulator: CMTappedPipe, MooreDecoderDelegate {

    weak var delegate: SITORDemodulatorDelegate?
    var tonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 100.0)

    private var bandpassFilter: CMBandpassFilter!
    private let mixer = CMFSKMixer()
    private let matchedFilter: CMFSKMatchedFilter
    private let bitSync = SITORBitSync()
    private let decoder = MooreDecoder()

    override init() {
        matchedFilter = CMFSKMatchedFilter(defaultFilterWithBaudRate: Float(100.0))
        super.init()

        matchedFilter.setDataRate(Float(tonePair.baud))
        bitSync.setMooreDecoder(decoder)
        decoder.delegate = self

        bandpassFilter = makeFilter(425.0)

        //  connect the pipe chain (importData is exported to bandpassFilter by self)
        bitSync.setClient(decoder)
        matchedFilter.setClient(bitSync)
        mixer.setClient(matchedFilter)
        bandpassFilter.setClient(mixer)

        mixer.setTonePair(&tonePair)
    }

    //  send data through the processing chain starting at the bandpass filter
    override func importData(_ pipe: CMPipe!) {
        bandpassFilter.importData(pipe)
    }

    //  return a CMBandpassFilter that has passband centered around the current mark and space carriers
    //  (identical construction to RTTY's CMFSKDemodulator.makeFilter / the original
    //  CMFSKDemodulator.makeFilter: -- SITORReceiver called this same helper via its
    //  base CMFSKDemodulator with width 425.0).
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

    func setSquelch(_ value: Float) {
        bitSync.setSquelch(value)
    }

    func setErrorPrint(_ state: Bool) {
        decoder.setErrorPrint(state)
    }

    func setUSOS(_ state: Bool) {
        decoder.setUSOS(state)
    }

    func setBell(_ state: Bool) {
        decoder.setBell(state)
    }

    func setInvert(_ state: Bool) {
        bitSync.setInvert(state)
    }

    // MARK: - MooreDecoderDelegate

    func mooreReceivedCharacter(_ c: Int32) {
        delegate?.sitorReceivedCharacter(c)
    }

    func mooreSyncStateChanged(_ state: SITORSyncState) {
        delegate?.sitorSyncStateChanged(state)
    }
}
