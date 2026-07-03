//
//  RTTYRxControl.swift
//  cocoaModem
//
//  Created by Kok Chen on 1/24/05.
//  Swift port of RTTYRxControl.m.
//
//  NIB-loaded control (loads "RTTYRxControl").  Base class of CWRxControl,
//  SITORRxControl, LiteASCIIControl and LiteRTTYControl, so every ivar becomes an
//  EXACT-named stored property and every outlet an @objc IBOutlet.  Nib outlets
//  were `IBOutlet id`; they are typed here by their runtime usage and accessed
//  nil-tolerantly (?.) to preserve the ObjC nil-messaging behaviour.
//
//  The preferences methods use RTTYConfig / RTTYConfigSet (still ObjC, in
//  RTTYConfig.h + RTTYTypes.h).  Those headers must be visible to Swift (see
//  BRIDGING_NEEDS report); the NSString keys inside the C RTTYConfigSet struct
//  import as Unmanaged<NSString> and are unwrapped by cfgKey().
//

import Cocoa

//  RTTY Aural Monitor sub dictionary keys (were #defines in RTTYRxControl.m)
private let kRxMonitorEnable = "Receive Enable"
private let kRxMonitorAttenuator = "Receive Attenuator"
private let kRxMonitorFixSelect = "Receive Fix Select"
private let kRxMonitorFrequency = "Receive Frequency"
private let kRxClickVolume = "Click Buffer click volume"
private let kRxClickPitch = "Click Buffer click pitch"
private let kRxSoftLimit = "Receive Soft Limiting"
private let kTxMonitorEnable = "Transmit Enable"
private let kTxMonitorAttenuator = "Transmit Attenuator"
private let kTxMonitorFixSelect = "Transmit Fix Select"
private let kTxMonitorFrequency = "Transmit Frequency"
private let kWideMonitorEnable = "Wideband Enable"
private let kWideMonitorAttenuator = "Wideband Attenuator"
private let kMonitorMute = "Mute"
private let kMonitorVolume = "Volume"

//  static CMTonePair adjustTone( CMTonePair *base, int usb, int reverse, float delta )
//  (CMTonePair fields are C doubles.)
private func adjustTone(_ base: UnsafePointer<CMTonePair>, _ usb: Int32, _ reverse: Int32, _ delta: Float) -> CMTonePair {
    var adjusted = base.pointee
    adjusted.mark += Double(delta)      //  RIT
    adjusted.space += Double(delta)

    if (usb ^ reverse) != 0 {
        let t = adjusted.mark
        adjusted.mark = adjusted.space
        adjusted.space = t
    }
    return adjusted
}

@objc(RTTYRxControl)
class RTTYRxControl: CMTappedPipe {

    @objc var controlView: NSView!
    @objc var tuningView: CrossedEllipse!
    @objc var exchangeView: ExchangeView!
    @objc var receiverName: NSTextField!

    //  objects in aux window
    @objc var auxWindow: NSWindow!
    @objc var squelchSlider: NSSlider!
    @objc var bandwidthMatrix: NSMatrix!
    @objc var demodulatorModeMatrix: NSMatrix!
    @objc var printControlCheckbox: NSButton!
    @objc var auralLevelSlider: NSSlider!
    @objc var auralMonitorMute: NSButton!

    //  Aural Monitor Panel
    @objc var monitorSheet: NSWindow!

    @objc var rxMonitorCheckbox: NSButton!
    @objc var rxFixedRadioButton: NSMatrix!
    @objc var rxMonitorFrequencyField: NSTextField!
    @objc var rxMonitorAttenuationField: NSTextField!
    @objc var rxMonitorBackgroundCheckbox: NSButton!
    @objc var rxMonitorBackgroundAttenuator: NSTextField!

    @objc var rxMonitorClickVolumeSlider: NSSlider!
    @objc var rxMonitorClickPitchSlider: NSSlider!
    @objc var rxMonitorSoftLimitCheckbox: NSButton!

    @objc var txMonitorCheckbox: NSButton!
    @objc var txFixedRadioButton: NSMatrix!
    @objc var txMonitorFrequencyField: NSTextField!
    @objc var txMonitorAttenuationField: NSTextField!

    //  RTTY tones
    var sidebandMenu: NSPopUpButton!            //  interface in RTTYConfig
    @objc var rxPolarityButton: NSButton!
    @objc var txPolarityButton: NSButton!

    @objc var markFreq: NSTextField!
    @objc var shiftField: NSTextField!
    @objc var baudRateBox: NSTextField!
    @objc var memorySelectMenu: NSPopUpButton!

    //  input controls
    @objc var activeIndicator: NSTextField!
    @objc var inputAttenuator: NSSlider!
    @objc var vuMeter: VUMeter!

    //  tones
    var tonePair = CMTonePair()                 //  mark is always the lower tone
    var transmitTonePair = CMTonePair()         //  v0.67
    var memory = [CMTonePair](repeating: CMTonePair(), count: 4)
    var selectedTone: Int32 = 0
    var sideband: Int32 = 0                      //  0 = LSB, 1 = USB
    var rxPolarity: Int32 = 0                    //  0 = normal, 1 = reverse
    var txPolarity: Int32 = 0
    var vfoOffset: Float = 0
    var ritOffset: Float = 0
    var txLocked: Bool = false

    var monitor: RTTYMonitor!
    var activeTransmitter: Bool = false

    var uniqueID: Int32 = 0
    var client: RTTY!
    var receiver: RTTYReceiver!
    var config: ModemConfig!
    var spectrumView: Spectrum!
    var waterfall: RTTYWaterfall!

    var auralMonitorPlist: SubDictionary!

    var receiveTextAttribute: UnsafeMutablePointer<TextAttribute>!

    //  ---- init ----

    override init() {
        super.init()
    }

    @objc(initIntoView:client:index:)
    init?(intoView view: NSView?, client modem: Modem?, index: Int32) {
        super.init()
        auralMonitorPlist = nil
        if Bundle.main.loadNibNamed("RTTYRxControl", owner: self, topLevelObjects: nil) {
            //  loadNib should have set up controlView connection
            if let view = view, let cv = controlView {
                view.addSubview(cv)
                auxWindow?.title = (index == 0) ? NSLocalizedString("Main Receiver", comment: "") : NSLocalizedString("Sub Receiver", comment: "")
                setupWithClient(modem, index: index)
                activeIndicator?.backgroundColor = NSColor.gray
                return
            }
        }
        return nil
    }

    @objc(setInterface:to:)
    func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    @objc override func awakeFromNib() {
        spectrumView = nil
        waterfall = nil
        monitor = nil
        tonePair.mark = 2125
        tonePair.space = 2295
        tonePair.baud = 45.45
        transmitTonePair = tonePair             //  v0.67
        sideband = 0
        rxPolarity = 0
        txPolarity = 0
        activeTransmitter = false
        vfoOffset = 0
        ritOffset = 0
        txLocked = false

        setInterface(txPolarityButton, to: #selector(txPolarityChanged))
        setInterface(bandwidthMatrix, to: #selector(bandwidthChanged))
        setInterface(demodulatorModeMatrix, to: #selector(demodulatorModeChanged))
        setInterface(squelchSlider, to: #selector(squelchChanged))

        setInterface(rxPolarityButton, to: #selector(rxPolarityChanged))
        setInterface(markFreq, to: #selector(tonePairChanged))
        setInterface(shiftField, to: #selector(shiftChanged))
        setInterface(baudRateBox, to: #selector(baudRateChanged))

        setInterface(memorySelectMenu, to: #selector(tonePairSelected))
        setInterface(inputAttenuator, to: #selector(inputAttenuatorChanged))

        //  0.68 print controls
        setInterface(printControlCheckbox, to: #selector(printControlChanged(_:)))

        //  0.78 aural monitor
        setInterface(auralLevelSlider, to: #selector(auralVolumeChanged(_:)))
        setInterface(auralMonitorMute, to: #selector(auralMuteChanged(_:)))
        setInterface(rxMonitorCheckbox, to: #selector(rxMonitorChanged(_:)))
        setInterface(rxMonitorAttenuationField, to: #selector(rxAttenuatorChanged(_:)))
        setInterface(rxMonitorFrequencyField, to: #selector(rxFrequencyChanged(_:)))
        setInterface(rxFixedRadioButton, to: #selector(rxFixedRadioButtonChanged(_:)))
        //  v0.88c
        setInterface(rxMonitorClickVolumeSlider, to: #selector(rxMonitorClickVolumeSliderChanged(_:)))
        setInterface(rxMonitorClickPitchSlider, to: #selector(rxMonitorClickPitchSliderChanged(_:)))
        setInterface(rxMonitorSoftLimitCheckbox, to: #selector(rxMonitorSoftLimitCheckboxChanged(_:)))

        setInterface(txMonitorCheckbox, to: #selector(txMonitorChanged(_:)))
        setInterface(txMonitorAttenuationField, to: #selector(txAttenuatorChanged(_:)))
        setInterface(txMonitorFrequencyField, to: #selector(txFrequencyChanged(_:)))
        setInterface(txFixedRadioButton, to: #selector(txFixedRadioButtonChanged(_:)))

        setInterface(rxMonitorBackgroundCheckbox, to: #selector(rxWideMonitorChanged(_:)))
    }

    @objc func printControlChanged(_ sender: Any?) {
        receiver?.setPrintControl((sender as? NSButton)?.state == .on)
    }

    @objc func auralVolumeChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setGain((sender as? NSControl)?.floatValue ?? 0, source: AURALMASTER)
    }

    @objc func auralMuteChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setState((sender as? NSButton)?.state != .on, source: AURALMASTER)
    }

    @objc func rxMonitorChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setState((sender as? NSButton)?.state == .on, source: AURALRECEIVE)
    }

    @objc func rxFrequencyChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setOutputFrequency((sender as? NSControl)?.floatValue ?? 0, source: AURALRECEIVE)
    }

    @objc func rxAttenuatorChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setAttenuation((sender as? NSControl)?.intValue ?? 0, source: AURALRECEIVE)
    }

    @objc func rxFixedRadioButtonChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setFloatingTone((sender as? NSMatrix)?.selectedRow == 0, source: AURALRECEIVE)
    }

    //  v0.88c
    @objc func rxMonitorClickVolumeSliderChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setClickVolume((sender as? NSControl)?.floatValue ?? 0)
        receiver?.rttyAuralMonitor?.emitBeep()
    }

    //  v0.88c
    @objc func rxMonitorClickPitchSliderChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setClickPitch((sender as? NSControl)?.floatValue ?? 0)
        receiver?.rttyAuralMonitor?.emitBeep()
    }

    //  v0.88c
    @objc func rxMonitorSoftLimitCheckboxChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setSoftLimit((sender as? NSButton)?.state == .on)
    }

    @objc func txMonitorChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setState((sender as? NSButton)?.state == .on, source: AURALTRANSMIT)
    }

    @objc func txFrequencyChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setOutputFrequency((sender as? NSControl)?.floatValue ?? 0, source: AURALTRANSMIT)
    }

    @objc func txAttenuatorChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setAttenuation((sender as? NSControl)?.intValue ?? 0, source: AURALTRANSMIT)
    }

    @objc func txFixedRadioButtonChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setFloatingTone((sender as? NSMatrix)?.selectedRow == 0, source: AURALTRANSMIT)
    }

    @objc func rxWideMonitorChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setState((sender as? NSButton)?.state == .on, source: AURALBACKGROUND)
    }

    @objc func rxWideAttenuatorChanged(_ sender: Any?) {
        receiver?.rttyAuralMonitor?.setAttenuation((sender as? NSControl)?.intValue ?? 0, source: AURALBACKGROUND)
    }

    @objc(transmitterTonePairChangedTo:)
    func transmitterTonePairChanged(to pair: UnsafeMutablePointer<CMTonePair>) {
        receiver?.rttyAuralMonitor?.setTransmitTonePair(pair)
    }

    @objc(setTransmitLock:)
    func setTransmitLock(_ state: Bool) {
        txLocked = state
    }

    @objc(useAsTransmitTonePair:)
    func useAsTransmitTonePair(_ state: Bool) {
        activeIndicator?.backgroundColor = state ? NSColor.yellow : NSColor.gray
        activeTransmitter = state
    }

    @objc(setupRTTYReceiver)
    func setupRTTYReceiver() {
        receiver.setupReceiverChain(config)
        config.setClient(self)

        //  connect up scope taps to the various audio pipes
        if monitor != nil {
            monitor.connect(4, to: receiver.baudotPipe(), title: "Baudot", baudotMarkers: true, timebase: 8)
            monitor.connect(3, to: receiver.atcPipe(), title: "ATC", baudotMarkers: false, timebase: 2)
            monitor.connect(2, to: receiver.demodBufferPipe(), title: "MFilter", baudotMarkers: false, timebase: 4)
            monitor.connect(1, to: receiver.bpfBufferPipe(), title: "BPF", baudotMarkers: false, timebase: 1)
            monitor.connect(0, to: config as? CMTappedPipe, title: "Input", baudotMarkers: false, timebase: 1)
        }
    }

    //  audio source starts at config and is routed here first
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if receiver == nil || !receiver.enabled { return }

        //  send data through the processing chain
        receiver.importData(pipe)
        //  send data to crossed ellipse display
        tuningView?.importData(pipe)
        //  send data to a spectrum display if needed
        spectrumView?.addData(pipe.stream())
        waterfall?.importData(pipe)
    }

    @objc(setEllipseFatness:)
    func setEllipseFatness(_ value: Float) {
        tuningView?.setFatness(value)
    }

    @objc(setSpectrumView:)
    func setSpectrumView(_ view: Spectrum!) {
        spectrumView = view
        if spectrumView != nil {
            var localTonePair = baseTonePair()
            spectrumView.setTonePairMarker(&localTonePair)
        }
    }

    @objc(setWaterfall:)
    func setWaterfall(_ view: RTTYWaterfall!) {
        waterfall = view
        if waterfall != nil {
            var localTonePair = baseTonePair()
            waterfall.setSideband(sideband)
            waterfall.setTonePairMarker(&localTonePair, index: uniqueID)
            waterfall.setWaterfallID(uniqueID)
            waterfall.setActive(true, index: uniqueID)
            waterfall.useVFOOffset(vfoOffset)
        }
    }

    @objc(setWaterfallOffset:)
    func setWaterfallOffset(_ offset: Float) {
        vfoOffset = offset
        waterfall?.useVFOOffset(offset)
    }

    @objc(setPlotColor:)
    func setPlotColor(_ color: NSColor!) {
        monitor?.setPlotColor(color)
        tuningView?.setPlotColor(color)
    }

    @objc(setupDefaultFilters)
    func setupDefaultFilters() {
        let baud: Float

        //  v0.83 ASCII baud rates
        if (client as? RTTYInterface)?.isASCIIModem == false {
            tonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)
            baud = 45.45
        } else {
            tonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 110.0)
            baud = 110.0
        }

        memory[0].mark = 2125; memory[0].space = 2295; memory[0].baud = Double(baud)
        memory[1].mark = 2110; memory[1].space = 2310; memory[1].baud = Double(baud)
        memory[2].mark = 1415; memory[2].space = 1585; memory[2].baud = Double(baud)
        memory[3].mark = 1275; memory[3].space = 1445; memory[3].baud = Double(baud)
        selectedTone = 0

        setTuningIndicatorState(true)
        //  receive views
        receiveTextAttribute = exchangeView.newAttribute()
        exchangeView.delegate = client as? NSTextViewDelegate
    }

    @objc(setupWithClient:index:)
    func setupWithClient(_ modem: Modem?, index: Int32) {
        uniqueID = index
        client = modem as? RTTY
        setupDefaultFilters()

        //  Create the receiver unless the host is explicitly an ASCII modem.
        //  Non-RTTYInterface hosts (e.g. Analyze) yield nil here — treat that as
        //  "not ASCII" so the receiver is still created (`== false` would make
        //  `nil == false` skip it, leaving `receiver` nil → crash later).
        if (modem as? RTTYInterface)?.isASCIIModem != true {
            //  Pass the real modem, not `client` (= modem as? RTTY, which is nil
            //  for non-RTTY hosts like Analyze) — the receiver needs a live Modem
            //  to reach -application()/-manager.
            receiver = RTTYReceiver(receiver: index, modem: modem)
            //  set up receiver connections
            monitor = RTTYMonitor()
            monitor.setTitle("RTTY Monitor")
        } else {
            //  v0.83
            receiver = ASCIIReceiver(receiver: index)
            monitor = RTTYMonitor()
            monitor.setTitle("ASCII Monitor")
        }
        receiver.setSquelch(squelchSlider)
        receiver.setReceiveView(exchangeView)
        receiver.setDemodulatorModeMatrix(demodulatorModeMatrix)
        receiver.setBandwidthMatrix(bandwidthMatrix)
    }

    @objc(receiver)
    func receiver_() -> RTTYReceiver! {
        return receiver
    }

    @objc(view)
    func view() -> ExchangeView! {
        return exchangeView
    }

    //  -inputAttenuator and -vuMeter getters are provided by the @objc outlet
    //  properties of the same name above (same selectors), so no separate
    //  accessor methods are declared here.

    @objc(uniqueID)
    func uniqueID_() -> Int32 {
        return uniqueID
    }

    @objc(setTuningIndicatorState:)
    func setTuningIndicatorState(_ active: Bool) {
        if tuningView != nil {
            if active { tuningView.enableIndicator(client) } else { tuningView.clearIndicator() }
        }
    }

    @objc(turnOnMarkers:)
    func turnOnMarkers(_ active: Bool) {
        waterfall?.setActive(active, index: uniqueID)
    }

    @objc(textAttribute)
    func textAttribute() -> UnsafeMutablePointer<TextAttribute>! {
        return receiveTextAttribute
    }

    @objc(setName:)
    func setName(_ name: String!) {
        receiverName?.stringValue = name
    }

    @objc(baseTonePair)
    func baseTonePair() -> CMTonePair {
        return adjustTone(&tonePair, sideband, rxPolarity, 0.0)
    }

    @objc(rxTonePair)
    func rxTonePair() -> CMTonePair {
        return adjustTone(&tonePair, sideband, rxPolarity, ritOffset)
    }

    //  v0.67
    @objc(txTonePair)
    func txTonePair() -> CMTonePair {
        return adjustTone(&transmitTonePair, sideband, txPolarity, 0.0)
    }

    //  CW mode uses the mark tone of an RTTY Tone pair
    @objc(cwTone)
    func cwTone() -> Float {
        return Float(tonePair.mark)
    }

    //  get tx tone pair from text fields
    @objc(lockedTxTonePair)
    func lockedTxTonePair() -> CMTonePair {
        var locked = tonePair
        locked.mark = Double(markFreq.intValue)
        locked.space = locked.mark + Double(shiftField.intValue)
        return adjustTone(&locked, sideband, txPolarity, 0.0)
    }

    @objc(sideband)
    func sideband_() -> Int32 {
        return sideband
    }

    //  v0.67 -- separate rx and tx tone pairs
    @objc(setTonePair:mask:)
    func setTonePair(_ tonepair: UnsafePointer<CMTonePair>, mask: Int32) {
        switch mask {
        case 1, 3:
            //  receive or both
            tonePair = tonepair.pointee
            if mask == 3 {
                transmitTonePair = tonePair
                if activeTransmitter { (config as? RTTYConfig)?.txTonePairChanged(self) }
                waterfall?.setTransmitTonePairMarker(&transmitTonePair, index: uniqueID)
            }
            //  send frequencies to receiver
            receiver?.rxTonePairChanged(self)
            //  and to config if we are the selected transmitter
            if activeTransmitter && (mask & 2) == 2 { (config as? RTTYConfig)?.txTonePairChanged(self) }

            //  set cross ellipse filters
            if tuningView != nil {
                var rxTonepair = rxTonePair()
                tuningView.setTonePair(&rxTonepair)
            }
            //  dual RTTY spectrum
            spectrumView?.setTonePairMarker(tonepair)
            if waterfall != nil {
                waterfall.setSideband(sideband)
                waterfall.setTonePairMarker(tonepair, index: uniqueID)
                waterfall.setRITOffset(ritOffset)
                if txLocked {
                    var txTonepair = lockedTxTonePair()
                    waterfall.setTransmitTonePairMarker(&txTonepair, index: uniqueID)
                }
            }
            //  set RTTY Monitor's markers
            monitor?.setTonePairMarker(tonepair)
            if config != nil { (config as? RTTYConfig)?.setTonePairMarker(tonepair) }
        case 2:
            //  transmit case
            if txLocked == false {
                transmitTonePair = tonepair.pointee
                if activeTransmitter { (config as? RTTYConfig)?.txTonePairChanged(self) }
                waterfall?.setTransmitTonePairMarker(&transmitTonePair, index: uniqueID)
            }
            //  tell tx side tones have changed
            (config as? RTTYConfig)?.txTonePairChanged(self)
        default:
            break
        }
    }

    //  v0.67
    @objc(setTonePair:)
    func setTonePair(_ tonepair: UnsafePointer<CMTonePair>) {
        setTonePair(tonepair, mask: 3)
    }

    @objc(setRIT:)
    func setRIT(_ offset: Float) {
        ritOffset = offset
        var rxTonepair = rxTonePair()

        receiver?.rxTonePairChanged(self)
        tuningView?.setTonePair(&rxTonepair)
        waterfall?.setRITOffset(ritOffset)
    }

    @objc(fetchTonePairFromMemory)
    func fetchTonePairFromMemory() {
        //  update tone pair and baud rate
        tonePair.mark = Double(markFreq.intValue)
        tonePair.space = tonePair.mark + Double(shiftField.intValue)
        tonePair.baud = Double(baudRateBox.floatValue)

        //  v0.83 -- should not fix anything other than for 45 -> 45.45
        if tonePair.baud > 44.99 && tonePair.baud < 45.46 {
            tonePair.baud = 1000.0 / 22
        }
        transmitTonePair = tonePair     //  v0.68
    }

    //  v0.67
    @objc(updateTonePairInformationForMask:)
    func updateTonePairInformation(forMask mask: Int32) {
        if (mask & 1) == 1 {
            //  update rx polarity
            if rxPolarityButton.state == .on {
                rxPolarityButton.title = NSLocalizedString("Reversed", comment: "")
                rxPolarity = 1
            } else {
                rxPolarityButton.title = NSLocalizedString("Normal", comment: "")
                rxPolarity = 0
            }
        }
        if (mask & 2) == 2 {
            //  update tx polarity
            if txPolarityButton.state == .on {
                txPolarityButton.title = NSLocalizedString("Reversed", comment: "")
                txPolarity = 1
            } else {
                txPolarityButton.title = NSLocalizedString("Normal", comment: "")
                txPolarity = 0
            }
        }

        //  sideband
        let previous = sideband
        sideband = Int32(sidebandMenu.indexOfSelectedItem)

        if mask & 1 != 0 {
            setTonePair(&tonePair, mask: 1)
        }

        if mask & 2 != 0 {
            transmitTonePair.baud = tonePair.baud

            var flippedPair = transmitTonePair
            if flippedPair.mark < 5.1 { flippedPair = tonePair }

            if (sideband == 1 && txPolarity == 0) || (sideband == 0 && txPolarity == 1) {    //  v0.67 flip mark/space
                flippedPair.mark = tonePair.space
                flippedPair.space = tonePair.mark
            }
            setTonePair(&transmitTonePair, mask: 2)
        }

        //  update waterfall sideband
        if sideband != previous && waterfall != nil {
            var pair = baseTonePair()
            waterfall.setSideband(sideband)
            waterfall.setTonePairMarker(&pair, index: uniqueID)
        }
    }

    @objc(updateTonePairInformation)
    func updateTonePairInformation() {
        updateTonePairInformation(forMask: 3)
    }

    @objc(markFrequency)
    func markFrequency() -> Float {
        return Float(tonePair.mark)
    }

    @objc(setMarkFrequency:)
    func setMarkFrequency(_ f: Float) {
        tonePair.mark = Double(f)
        updateTonePairInformation()
    }

    @objc(spaceFrequency)
    func spaceFrequency() -> Float {
        return Float(tonePair.space)
    }

    @objc(setSpaceFrequency:)
    func setSpaceFrequency(_ f: Float) {
        tonePair.space = Double(f)
        updateTonePairInformation()
    }

    //  v0.67  mask 1 = receiver, 2 = transmitter
    @objc(markFrequencyForMask:)
    func markFrequency(forMask mask: Int32) -> Float {
        if mask == 2 { return Float(transmitTonePair.mark) }
        return Float(rxTonePair().mark)     //  v0.68
    }

    @objc(setMarkFrequency:mask:)
    func setMarkFrequency(_ f: Float, mask: Int32) {
        switch mask {
        case 1, 3:
            tonePair.mark = Double(f)
            updateTonePairInformation(forMask: mask)
        case 2:
            if transmitTonePair.mark < 5 { transmitTonePair = tonePair }
            transmitTonePair.mark = Double(f)
            updateTonePairInformation(forMask: 2)
        default:
            break
        }
    }

    @objc(spaceFrequencyForMask:)
    func spaceFrequency(forMask mask: Int32) -> Float {
        if mask == 2 { return Float(transmitTonePair.space) }
        return Float(rxTonePair().space)    //  v0.68
    }

    @objc(setSpaceFrequency:mask:)
    func setSpaceFrequency(_ f: Float, mask: Int32) {
        switch mask {
        case 1, 3:
            tonePair.space = Double(f)
            updateTonePairInformation(forMask: mask)
        case 2:
            if transmitTonePair.mark < 5 { transmitTonePair = tonePair }
            transmitTonePair.space = Double(f)
            updateTonePairInformation(forMask: 2)
        default:
            break
        }
    }

    //  returns 45.45 for 45 (used by AFSK)
    @objc(baudRate)
    func baudRate() -> Float {
        return Float(tonePair.baud)
    }

    //  returns what is in the baud rate box v0.50
    @objc(actualBaudRate)
    func actualBaudRate() -> Float {
        return baudRateBox.floatValue
    }

    @objc(setBaudRateField:)
    func setBaudRateField(_ rate: Float) {
        let v = Int32(rate)
        if (rate - Float(v)) < 0.01 {
            baudRateBox.intValue = v
            return
        }
        baudRateBox.stringValue = String(format: "%.2f", rate)
    }

    @objc(setBaudRate:)
    func setBaudRate(_ rate: Float) {
        tonePair.baud = Double(rate)
        updateTonePairInformation()
    }

    @objc(invertStateForReceiver)
    func invertStateForReceiver() -> Bool {
        return rxPolarityButton.state == .on
    }

    @objc(setInvertStateForReceiver:)
    func setInvertStateForReceiver(_ state: Bool) {
        rxPolarityButton.state = state ? .on : .off
        updateTonePairInformation()
    }

    @objc(invertStateForTransmitter)
    func invertStateForTransmitter() -> Bool {
        return txPolarityButton.state == .on
    }

    @objc(setInvertStateForTransmitter:)
    func setInvertStateForTransmitter(_ state: Bool) {
        txPolarityButton.state = state ? .on : .off
        updateTonePairInformation()
    }

    @objc(breakinStateForTransmitter)
    func breakinStateForTransmitter() -> Bool {
        return false
    }

    @objc(setBreakinStateForTransmitter:)
    func setBreakinStateForTransmitter(_ state: Bool) {
        //  override in CW
    }

    @objc(showMonitor)
    func showMonitor() {
        if monitor != nil {
            monitor.setTonePairMarker(&tonePair)
            monitor.showWindow()
        }
    }

    @objc(openAuralSheet:)
    func openAuralSheet(_ sender: Any?) {
        if let sheet = monitorSheet, let win = auxWindow {
            win.beginSheet(sheet, completionHandler: nil)
        }
    }

    @objc(closeAuralSheet:)
    func closeAuralSheet(_ sender: Any?) {
        if let sheet = monitorSheet, let win = auxWindow {
            win.endSheet(sheet)     //  end modal beginSheet
            sheet.orderOut(self)    //  remove the sheet
        }
    }

    @objc(openAuralMonitor:)
    func openAuralMonitor(_ sender: Any?) {
        let auralMonitor = (NSApp.delegate as? Application)?.auralMonitor()
        auralMonitor?.showWindow?()
    }

    @objc(auxButtonPushed:)
    func auxButtonPushed(_ sender: Any?) {
        auxWindow?.orderFront(self)
    }

    @objc func squelchChanged() {
        receiver?.newSquelchValue(squelchSlider.floatValue)
    }

    @objc func txPolarityChanged() {
        txPolarity = (txPolarityButton.state == .on) ? 1 : 0
        if txPolarity == 1 { txPolarityButton.title = NSLocalizedString("Reversed", comment: "") } else { txPolarityButton.title = NSLocalizedString("Normal", comment: "") }
        if activeTransmitter { (config as? RTTYConfig)?.txTonePairChanged(self) }
    }

    @objc func bandwidthChanged() {
        receiver?.selectBandwidth(Int32(bandwidthMatrix.selectedColumn))
    }

    @objc func demodulatorModeChanged() {
        receiver?.selectDemodulator(Int32(demodulatorModeMatrix.selectedColumn))
    }

    //  pass changes to the input attenuator to ModemConfig
    @objc func inputAttenuatorChanged() {
        config?.inputAttenuatorChanged(inputAttenuator)
    }

    @objc func rxPolarityChanged() {
        updateTonePairInformation()
        receiver?.forceLTRS()       //  force to LTRS when polarity change 0.19
    }

    @objc func tonePairChanged() {
        fetchTonePairFromMemory()
        updateTonePairInformation()
    }

    @objc func shiftChanged() {
        tonePair.space = tonePair.mark + Double(shiftField.intValue)
        updateTonePairInformation()
    }

    //  map baud rates so that 45 maps to 45.45
    @objc func baudRateChanged() {
        var baud = baudRateBox.floatValue
        //  v0.83 -- should not fix anything other than for 45 -> 45.45
        if baud > 44.99 && baud < 45.46 {
            baud = 1000.0 / 22
        }
        tonePair.baud = Double(baud)
        updateTonePairInformation()
    }

    //  tone pair memory menu changed
    @objc func tonePairSelected() {
        selectedTone = Int32(memorySelectMenu.indexOfSelectedItem)
        markFreq.intValue = Int32(memory[Int(selectedTone)].mark)
        shiftField.intValue = Int32(abs(memory[Int(selectedTone)].space - memory[Int(selectedTone)].mark))
        setBaudRateField(Float(memory[Int(selectedTone)].baud))
        fetchTonePairFromMemory()
        updateTonePairInformation()
    }

    @objc(tonePairStore:)
    func tonePairStore(_ sender: Any?) {
        let index = memorySelectMenu.indexOfSelectedItem
        memory[index].mark = Double(markFreq.intValue)
        memory[index].space = memory[index].mark + Double(shiftField.intValue)
        memory[index].baud = Double(baudRateBox.floatValue)
    }

    @objc(hideMonitorOnDeactivation:)
    func hideMonitorOnDeactivation(_ hide: Bool) {
        monitor?.hideScopeOnDeactivation(DarwinBoolean(hide))
    }

    //  ---- preferences ----

    //  local
    private func toneString(_ f: [Int32]) -> String {
        return String(format: "%d,%d,%d,%d", f[0], f[1], f[2], f[3])
    }

    //  local
    private func baudString(_ f: [Float]) -> String {
        return String(format: "%.2f,%.2f,%.2f,%.2f", f[0], f[1], f[2], f[3])
    }

    //  local
    private func decodeToneString(_ str: String, into p: inout [Int32]) {
        let parts = str.components(separatedBy: ",")
        for i in 0..<min(4, parts.count) {
            p[i] = Int32(parts[i].trimmingCharacters(in: .whitespaces)) ?? p[i]
        }
    }

    //  local
    private func decodeBaudString(_ str: String, into p: inout [Float]) {
        let parts = str.components(separatedBy: ",")
        for i in 0..<min(4, parts.count) {
            p[i] = Float(parts[i].trimmingCharacters(in: .whitespaces)) ?? p[i]
        }
    }

    //  NSString keys stored inside the C RTTYConfigSet struct import as Unmanaged.
    private func cfgKey(_ u: Unmanaged<NSString>?) -> String {
        return (u?.takeUnretainedValue() as String?) ?? ""
    }

    @objc(setupBasicDefaultPreferences:config:)
    func setupBasicDefaultPreferences(_ pref: Preferences!, config cfg: ModemConfig!) {
        config = cfg
        guard let set = (config as? RTTYConfig)?.configSetPointer() else { return }

        //  get sidebandMenu interface from RTTYConfig
        sidebandMenu = (config as? RTTYConfig)?.sidebandMenu
        setInterface(sidebandMenu, to: #selector(tonePairChanged))

        pref.setInt(0, forKey: cfgKey(set.pointee.sideband))
        pref.setFloat(0.6, forKey: cfgKey(set.pointee.squelch))

        if auxWindow != nil && set.pointee.controlWindow != nil {
            if uniqueID != 0 {
                //  offset sub control a little
                var frame = auxWindow.frame
                frame.origin.y += 20
                frame.origin.x += 20
                auxWindow.setFrame(frame, display: false)
            }
            pref.setString(auxWindow.frameDescriptor, forKey: cfgKey(set.pointee.controlWindow))
        }
    }

    //  v0.78 (Private API)
    private func setupAuralMonitorDefaultPreferences(_ pref: Preferences!, config cfg: ModemConfig!) {
        //  create a sub dictionary to hold RTTY Aural Monitor parameters
        auralMonitorPlist = SubDictionary()

        if auralMonitorPlist != nil {
            auralMonitorPlist.setInt(0, forKey: kRxMonitorEnable)
            auralMonitorPlist.setInt(0, forKey: kRxMonitorAttenuator)
            auralMonitorPlist.setInt(1, forKey: kRxMonitorFixSelect)
            auralMonitorPlist.setInt(1760, forKey: kRxMonitorFrequency)

            auralMonitorPlist.setFloat(0.5, forKey: kRxClickVolume)
            auralMonitorPlist.setFloat(1000.0, forKey: kRxClickPitch)
            auralMonitorPlist.setInt(0, forKey: kRxSoftLimit)

            auralMonitorPlist.setInt(0, forKey: kTxMonitorEnable)
            auralMonitorPlist.setInt(6, forKey: kTxMonitorAttenuator)
            auralMonitorPlist.setInt(1, forKey: kTxMonitorFixSelect)
            auralMonitorPlist.setInt(1048, forKey: kTxMonitorFrequency)

            auralMonitorPlist.setInt(0, forKey: kWideMonitorEnable)
            auralMonitorPlist.setInt(10, forKey: kWideMonitorAttenuator)

            auralMonitorPlist.setInt(1, forKey: kMonitorMute)
            auralMonitorPlist.setFloat(0.5, forKey: kMonitorVolume)
        }
    }

    @objc(setupDefaultPreferences:config:)
    func setupDefaultPreferences(_ pref: Preferences!, config cfg: ModemConfig!) {
        var f = [Float](repeating: 0, count: 4)
        var g = [Int32](repeating: 0, count: 4)

        setupBasicDefaultPreferences(pref, config: cfg)

        guard let set = (config as? RTTYConfig)?.configSetPointer() else { return }
        if set.pointee.usesRTTYAuralMonitor.boolValue { setupAuralMonitorDefaultPreferences(pref, config: cfg) }   //  v0.78

        pref.setInt(selectedTone, forKey: cfgKey(set.pointee.tone))      //  tone memory
        pref.setInt(0, forKey: cfgKey(set.pointee.rxPolarity))
        pref.setInt(0, forKey: cfgKey(set.pointee.txPolarity))

        for i in 0..<4 { g[i] = Int32(memory[i].mark) }
        pref.setString(toneString(g), forKey: cfgKey(set.pointee.mark))

        for i in 0..<4 { g[i] = Int32(memory[i].space) }
        pref.setString(toneString(g), forKey: cfgKey(set.pointee.space))

        for i in 0..<4 { f[i] = Float(memory[i].baud) }
        pref.setString(baudString(f), forKey: cfgKey(set.pointee.baud))
    }

    @objc(updateBasicFromPlist:config:)
    func updateBasicFromPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        config = cfg
        guard let set = (config as? RTTYConfig)?.configSetPointer() else { return }

        if auxWindow != nil && set.pointee.controlWindow != nil {
            auxWindow.setFrame(from: pref.stringValue(forKey: cfgKey(set.pointee.controlWindow)))
        }
        if receiver != nil { receiver.setSquelchValue(pref.floatValue(forKey: cfgKey(set.pointee.squelch))) }

        //  menus for tone pair polarities
        sidebandMenu.selectItem(at: Int(pref.intValue(forKey: cfgKey(set.pointee.sideband))))
        //  tone pair table selection
        fetchTonePairFromMemory()
        updateTonePairInformation()
    }

    //  v0.78
    private func updateAuralMonitorFromPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        guard auralMonitorPlist != nil, let set = (config as? RTTYConfig)?.configSetPointer() else { return }

        //  merge plist that is read into auralMonitorPlist
        auralMonitorPlist.dictionary().addEntries(from: pref.dictionary(forKey: cfgKey(set.pointee.auralMonitor)) ?? [:])

        //  global (both receive and transmit)
        if auralLevelSlider != nil {
            auralLevelSlider.floatValue = auralMonitorPlist.floatValueForKey(kMonitorVolume)
            auralVolumeChanged(auralLevelSlider)
        }
        if auralMonitorMute != nil {
            auralMonitorMute.state = (auralMonitorPlist.intValueForKey(kMonitorMute) == 0) ? .off : .on
            auralMuteChanged(auralMonitorMute)
        }

        //  receive
        if rxMonitorCheckbox != nil {
            rxMonitorCheckbox.state = (auralMonitorPlist.intValueForKey(kRxMonitorEnable) == 0) ? .off : .on
            rxMonitorChanged(rxMonitorCheckbox)
        }
        if rxMonitorAttenuationField != nil {
            rxMonitorAttenuationField.intValue = auralMonitorPlist.intValueForKey(kRxMonitorAttenuator)
            rxAttenuatorChanged(rxMonitorAttenuationField)
        }
        if rxMonitorFrequencyField != nil {
            rxMonitorFrequencyField.floatValue = auralMonitorPlist.floatValueForKey(kRxMonitorFrequency)
            rxFrequencyChanged(rxMonitorFrequencyField)
        }
        if rxFixedRadioButton != nil {
            rxFixedRadioButton.selectCell(atRow: Int(auralMonitorPlist.intValueForKey(kRxMonitorFixSelect)), column: 0)
            rxFixedRadioButtonChanged(rxFixedRadioButton)
        }

        //  wideband
        if rxMonitorBackgroundCheckbox != nil {
            rxMonitorBackgroundCheckbox.state = (auralMonitorPlist.intValueForKey(kWideMonitorEnable) == 0) ? .off : .on
            rxWideMonitorChanged(rxMonitorBackgroundCheckbox)
        }
        if rxMonitorBackgroundAttenuator != nil {
            rxMonitorBackgroundAttenuator.intValue = auralMonitorPlist.intValueForKey(kWideMonitorAttenuator)
            rxWideAttenuatorChanged(rxMonitorBackgroundAttenuator)
        }

        //  click buffer beep (v0.88c)
        if rxMonitorClickVolumeSlider != nil {
            rxMonitorClickVolumeSlider.floatValue = auralMonitorPlist.floatValueForKey(kRxClickVolume)
            receiver?.rttyAuralMonitor?.setClickVolume(rxMonitorClickVolumeSlider.floatValue)
        }
        if rxMonitorClickPitchSlider != nil {
            rxMonitorClickPitchSlider.floatValue = auralMonitorPlist.floatValueForKey(kRxClickPitch)
            receiver?.rttyAuralMonitor?.setClickPitch(rxMonitorClickPitchSlider.floatValue)
        }
        if rxMonitorSoftLimitCheckbox != nil {
            let intval = auralMonitorPlist.intValueForKey(kRxSoftLimit)
            rxMonitorSoftLimitCheckbox.state = (intval == 0) ? .off : .on
            receiver?.rttyAuralMonitor?.setSoftLimit(intval != 0)
        }

        //  transmit
        if txMonitorCheckbox != nil {
            txMonitorCheckbox.state = (auralMonitorPlist.intValueForKey(kTxMonitorEnable) == 0) ? .off : .on
            txMonitorChanged(txMonitorCheckbox)
        }
        if txMonitorAttenuationField != nil {
            txMonitorAttenuationField.intValue = auralMonitorPlist.intValueForKey(kTxMonitorAttenuator)
            txAttenuatorChanged(txMonitorAttenuationField)
        }
        if txMonitorFrequencyField != nil {
            txMonitorFrequencyField.floatValue = auralMonitorPlist.floatValueForKey(kTxMonitorFrequency)
            txFrequencyChanged(txMonitorFrequencyField)
        }
        if txFixedRadioButton != nil {
            txFixedRadioButton.selectCell(atRow: Int(auralMonitorPlist.intValueForKey(kTxMonitorFixSelect)), column: 0)
            txFixedRadioButtonChanged(txFixedRadioButton)
        }
    }

    @objc(updateFromPlist:config:)
    func updateFromPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        var f = [Float](repeating: 0, count: 4)
        var g = [Int32](repeating: 0, count: 4)

        config = cfg
        guard let set = (config as? RTTYConfig)?.configSetPointer() else { return }

        decodeToneString(pref.stringValue(forKey: cfgKey(set.pointee.mark)), into: &g)
        for i in 0..<4 { memory[i].mark = Double(g[i]) }

        decodeToneString(pref.stringValue(forKey: cfgKey(set.pointee.space)), into: &g)
        for i in 0..<4 { memory[i].space = Double(g[i]) }

        decodeBaudString(pref.stringValue(forKey: cfgKey(set.pointee.baud)), into: &f)
        for i in 0..<4 { memory[i].baud = Double(f[i]) }

        selectedTone = pref.intValue(forKey: cfgKey(set.pointee.tone))
        if selectedTone > 3 { selectedTone = 0 }
        memorySelectMenu.selectItem(at: Int(selectedTone))

        //  menus for tone pair polarities
        rxPolarityButton.state = (pref.intValue(forKey: cfgKey(set.pointee.rxPolarity)) == 0) ? .off : .on
        txPolarityButton.state = (pref.intValue(forKey: cfgKey(set.pointee.txPolarity)) == 0) ? .off : .on
        //  tone pair table selection
        markFreq.intValue = Int32(memory[Int(selectedTone)].mark)
        shiftField.intValue = Int32(abs(memory[Int(selectedTone)].space - memory[Int(selectedTone)].mark + 0.1))
        setBaudRateField(Float(memory[Int(selectedTone)].baud))

        if set.pointee.usesRTTYAuralMonitor.boolValue { updateAuralMonitorFromPlist(pref, config: cfg) }   //  v0.78
        updateBasicFromPlist(pref, config: cfg)
    }

    @objc(retrieveBasicForPlist:config:)
    func retrieveBasicForPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        config = cfg
        guard let set = (config as? RTTYConfig)?.configSetPointer() else { return }

        if auxWindow != nil && set.pointee.controlWindow != nil {
            pref.setString(auxWindow.frameDescriptor, forKey: cfgKey(set.pointee.controlWindow))
        }
        pref.setInt(sideband, forKey: cfgKey(set.pointee.sideband))

        if receiver != nil { pref.setFloat(receiver.squelchValue(), forKey: cfgKey(set.pointee.squelch)) }
    }

    //  v0.78
    private func retrieveAuralMonitorForPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        guard auralMonitorPlist != nil, let set = (config as? RTTYConfig)?.configSetPointer() else { return }

        auralMonitorPlist.setInt(rxMonitorCheckbox.state == .on ? 1 : 0, forKey: kRxMonitorEnable)
        auralMonitorPlist.setInt(txMonitorCheckbox.state == .on ? 1 : 0, forKey: kTxMonitorEnable)
        auralMonitorPlist.setInt(rxMonitorBackgroundCheckbox.state == .on ? 1 : 0, forKey: kWideMonitorEnable)

        auralMonitorPlist.setInt(rxMonitorFrequencyField.intValue, forKey: kRxMonitorFrequency)
        auralMonitorPlist.setInt(txMonitorFrequencyField.intValue, forKey: kTxMonitorFrequency)

        auralMonitorPlist.setInt(rxMonitorAttenuationField.intValue, forKey: kRxMonitorAttenuator)
        auralMonitorPlist.setInt(txMonitorAttenuationField.intValue, forKey: kTxMonitorAttenuator)
        auralMonitorPlist.setInt(rxMonitorBackgroundAttenuator.intValue, forKey: kWideMonitorAttenuator)

        auralMonitorPlist.setFloat(rxMonitorClickVolumeSlider.floatValue, forKey: kRxClickVolume)
        auralMonitorPlist.setFloat(rxMonitorClickPitchSlider.floatValue, forKey: kRxClickPitch)
        auralMonitorPlist.setInt(rxMonitorSoftLimitCheckbox.state == .on ? 1 : 0, forKey: kRxSoftLimit)

        auralMonitorPlist.setInt(auralMonitorMute.state == .on ? 1 : 0, forKey: kMonitorMute)
        auralMonitorPlist.setFloat(auralLevelSlider.floatValue, forKey: kMonitorVolume)

        auralMonitorPlist.setInt(Int32(rxFixedRadioButton.selectedRow), forKey: kRxMonitorFixSelect)
        auralMonitorPlist.setInt(Int32(txFixedRadioButton.selectedRow), forKey: kTxMonitorFixSelect)

        //  copy auralMonitorPlist into plist
        pref.setDictionary(auralMonitorPlist.dictionary() as? [AnyHashable: Any], forKey: cfgKey(set.pointee.auralMonitor))
    }

    @objc(retrieveForPlist:config:)
    func retrieveForPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        var f = [Float](repeating: 0, count: 4)
        var g = [Int32](repeating: 0, count: 4)

        guard let set = (config as? RTTYConfig)?.configSetPointer() else { return }

        if set.pointee.usesRTTYAuralMonitor.boolValue { retrieveAuralMonitorForPlist(pref, config: cfg) }   //  v0.78
        retrieveBasicForPlist(pref, config: cfg)

        for i in 0..<4 { g[i] = Int32(memory[i].mark) }
        pref.setString(toneString(g), forKey: cfgKey(set.pointee.mark))

        for i in 0..<4 { g[i] = Int32(memory[i].space) }
        pref.setString(toneString(g), forKey: cfgKey(set.pointee.space))

        for i in 0..<4 { f[i] = Float(memory[i].baud) }
        pref.setString(baudString(f), forKey: cfgKey(set.pointee.baud))

        pref.setInt(selectedTone, forKey: cfgKey(set.pointee.tone))     //  tone memory
        pref.setInt(rxPolarity, forKey: cfgKey(set.pointee.rxPolarity))
        pref.setInt(txPolarity, forKey: cfgKey(set.pointee.txPolarity))

        if receiver != nil { pref.setFloat(receiver.squelchValue(), forKey: cfgKey(set.pointee.squelch)) }
    }
}
