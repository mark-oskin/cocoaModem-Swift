//
//  RTTYStereoReceiver.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/25/05.
//  Swift port of RTTYStereoReceiver.m.
//
//  Subclass of RTTYReceiver used by the Analyze mode: a reference channel and a
//  device-under-test channel are demodulated in parallel and compared by
//  MultiStereoATC.  The original overrode -initReceiver: and called
//  [super initReceiver:] (the old full base setup).  In the Swift base that full
//  setup is init(receiver:modem:), so this overrides that designated initializer
//  (the base demodulator / bandpass / matched-filter banks it builds are what the
//  inherited -selectDemodulator: / -selectBandwidth: fall back on; the active
//  stereo pipeline built in -setupReceiverChain:config: is separate).  Base ivars
//  (currentTonePair, sidebandState, bandwidthMatrix, enabled, ...) are accessed by
//  their exact RTTYReceiver names.
//
//  Port note: the old CMRTTYMatchedFilter/-initWithDefaultFilter were renamed by
//  the CMPipe wave to RTTYMatchedFilter/-initDefaultFilterWithBaudRate: (45.45
//  baud for RTTY).  `decoder` is declared but, exactly as in the original, is
//  never assigned (stereoATC's downstream client is therefore nil).
//

import Cocoa

@objc(RTTYStereoReceiver)
class RTTYStereoReceiver: RTTYReceiver {

    var refPipe: ChannelSelector!
    var dutPipe: ChannelSelector!
    var refFilter: CMBandpassFilter!
    var dutFilter = [CMBandpassFilter?](repeating: nil, count: 5)
    var selectedDUTFilter: CMBandpassFilter!

    var demod = [RTTYMatchedFilter?](repeating: nil, count: 5)      // old receiver

    var refMixer: CMFSKMixer!
    var mixer: CMFSKMixer!
    var refDemod: RTTYMatchedFilter!
    var refATCBuffer: StereoRefATCBuffer!
    var stereoATC: MultiStereoATC!
    var scope: AnalyzeScope!
    var decoder: CMBaudotDecoder!       // move to CoreModem

    var bpfBuffer: CMTappedPipe!
    var demodBuffer: CMTappedPipe!
    var modemSource: ModemSource!

    var reference: Int32 = 0
    var dut: Int32 = 0

    @objc(initReceiver:modem:)
    override init(receiver index: Int32, modem: Modem!) {
        super.init(receiver: index, modem: modem)

        scope = nil
        reference = 0   /* left */
        dut = 1         /* right */
        refPipe = nil; dutPipe = nil
        sidebandState = false
        modemSource = nil
        // create bandpass filters
        refFilter = CMBandpassFilter(lowCutoff: 2040, highCutoff: 2380, length: 256)

        dutFilter[0] = CMBandpassFilter(lowCutoff: 2090, highCutoff: 2330, length: 256)
        dutFilter[1] = CMBandpassFilter(lowCutoff: 2040, highCutoff: 2380, length: 256)
        dutFilter[2] = CMBandpassFilter(lowCutoff: 1970, highCutoff: 2450, length: 256)
        dutFilter[3] = CMBandpassFilter(lowCutoff: 1920, highCutoff: 2500, length: 128)
        dutFilter[4] = CMBandpassFilter(lowCutoff: 500, highCutoff: 2500, length: 128)
    }

    @objc(setReference:dut:)
    func setReference(_ refChannel: Int32, dut dutChannel: Int32) {
        reference = refChannel
        refPipe?.selectChannel(reference)
        //  crossed ellipse is tapped from refPipe

        dut = dutChannel
        dutPipe?.selectChannel(dut)
        dutPipe?.setTap(nil)
    }

    @objc(setScope:)
    func setScope(_ ascope: AnalyzeScope!) {
        scope = ascope
        if stereoATC != nil { stereoATC.setScope(scope) }
    }

    /* local */
    //  set up filter cutoffs given current mark and space frequencies
    @objc(setFilterCutoffs)
    func setFilterCutoffs() {
        let low: Float
        let high: Float

        if currentTonePair.space < currentTonePair.mark {
            low = Float(currentTonePair.space)
            high = Float(currentTonePair.mark)
        } else {
            low = Float(currentTonePair.mark)
            high = Float(currentTonePair.space)
        }
        //  reference filter has nominal bandwidth
        refFilter?.updateLowCutoff(low - 85, highCutoff: high + 85)

        dutFilter[0]?.updateLowCutoff(low - 35, highCutoff: high + 35)
        dutFilter[1]?.updateLowCutoff(low - 85, highCutoff: high + 85)
        dutFilter[2]?.updateLowCutoff(low - 155, highCutoff: high + 155)
        dutFilter[3]?.updateLowCutoff(low - 205, highCutoff: high + 205)
    }

    //  overide base class to change AudioPipe pipeline (assume source is normalized)
    //      source
    //      self
    //      . ChannelSelectorPipe    . crossed ellipse
    //      . BPF[5]
    //      . bpfBuffer
    //      . CMFSKMixer
    //      . ( matchedFilter, mpFilter, heavyMPFilter )
    //      . demodBuffer
    //      . CMATC
    //      . CMBaudotDecoder(importData)

    @objc(setupReceiverChain:config:)
    func setupReceiverChain(_ source: ModemSource!, config: AnalyzeConfig!) {
        modemSource = source
        source?.setFileRepeat(false)

        //  create two AudioPipes
        //  these will really just be to switch the selected data streams to the BPFs

        //  pipeline for reference signal
        refPipe = ChannelSelector()
        refPipe.pipe(withClient: refFilter)
        refPipe.selectChannel(reference)
        refMixer = CMFSKMixer()
        refDemod = RTTYMatchedFilter(defaultFilterWithBaudRate: 45.45)   //  MS
        refATCBuffer = StereoRefATCBuffer()
        stereoATC = MultiStereoATC()
        stereoATC.setInvert(DarwinBoolean(sidebandState))
        stereoATC.setConfigClient(config)
        if scope != nil { stereoATC.setScope(scope) }

        refFilter.setClient(refMixer)
        refMixer.setTonePair(&currentTonePair)
        refMixer.setClient(refDemod)
        refDemod.setClient(refATCBuffer)
        refATCBuffer.setClient(stereoATC)       //  refATCBuffer calls importClockData

        //  pipeline for device under test
        dutPipe = ChannelSelector()
        dutPipe.pipe(withClient: dutFilter[1])
        dutPipe.selectChannel(dut)

        //  set up the AudioPipe pipeline
        mixer = CMFSKMixer()
        mixer.setTonePair(&currentTonePair)

        selectedDUTFilter = dutFilter[1]
        setFilterCutoffs()

        //  create demodulators
        demod[0] = RTTYSingleFilter(tone: 0, baud: 45.45)               //  Mark-only
        demod[1] = RTTYSingleFilter(tone: 1, baud: 45.45)               //  Space-only
        demod[2] = RTTYMPFilter(bitWidth: 0.35, baud: 45.45)            //  MP+
        demod[3] = RTTYMPFilter(bitWidth: 0.70, baud: 45.45)            //  MP-
        demod[4] = RTTYMatchedFilter(defaultFilterWithBaudRate: 45.45)  //  MS
        //  buffers
        bpfBuffer = CMTappedPipe()
        demodBuffer = CMTappedPipe()

        //  connect AudioPipes
        //  the audio pipeline starts at the source (the "input" ModemConfig)
        //  importData of the RTTYReceiver (self) will relay the data to various clients
        config?.setClient(self)

        //  use BPF 1 (normal) as default bandpass
        selectBandwidth(1)
        //  connect all BPF outputs to the bpfBuffer
        for i in 0..<5 { dutFilter[i]?.setClient(bpfBuffer) }
        bpfBuffer.setClient(mixer)

        //  create the different demodulators, hook all their outputs to the demodBuffer
        //  select demodulator 4 as the defualt demodulator
        selectDemodulator(4)
        for i in 0..<5 { demod[i]?.setClient(demodBuffer) }
        demodBuffer.setClient(stereoATC)

        //  MultiATC produces Baudot, but it also has a couple of other outlets for RTTY Monitor probes
        stereoATC.setClient(decoder)
    }

    //  Getter for the refPipe ivar (ObjC had a same-named -refPipe method; the
    //  Swift method is suffixed but keeps the original @objc(refPipe) selector).
    @objc(refPipe)
    func refPipe_() -> ChannelSelector! {
        return refPipe
    }

    //  select an input BPF
    @objc(selectBandwidth:)
    override func selectBandwidth(_ index: Int32) {
        var index = index
        if bandwidthMatrix != nil {
            bandwidthMatrix.deselectAllCells()
            bandwidthMatrix.selectCell(atRow: 0, column: Int(index))
            if index < 0 || index > 4 { index = 1 }
            selectedDUTFilter = dutFilter[Int(index)]
        } else {
            selectedDUTFilter = dutFilter[1]        //  nominal filter
        }
        dutPipe?.setClient(selectedDUTFilter)
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if !enabled { return }

        //  send data through the receiver processing chain
        if dutPipe != nil { dutPipe.importData(pipe) }  // data ends up at importData of MultiStereoATC
        if refPipe != nil { refPipe.importData(pipe) }  // data ends up at importClockData of MultiStereoATC
    }

    @objc(setFileRepeat:)
    func setFileRepeat(_ state: Bool) {
        modemSource?.setFileRepeat(state)
    }
}
