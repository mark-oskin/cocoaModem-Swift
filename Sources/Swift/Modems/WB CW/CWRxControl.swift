//
//  CWRxControl.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/2/06.
//  Swift port of CWRxControl.m.
//
//  Subclass of RTTYRxControl for wideband CW.  Adds its own nib outlets and CW
//  ivars; base ivars/outlets are accessed by their exact RTTYRxControl names.
//  Plist keys (kWBCW...) were #define @"..." string macros in Plist.h, which the
//  Swift importer does not surface, so their literal values are inlined here.
//

import Cocoa

private let kWBCWMainMonitor = "WBCW Main Monitor"
private let kWBCWSubMonitor = "WBCW Sub Monitor"
private let kWBCWMainBandwidth = "WBCW Main Bandwidth"
private let kWBCWSubBandwidth = "WBCW Sub Bandwidth"
private let kWBCWMainSquelch = "WBCW Squelch A"
private let kWBCWSubSquelch = "WBCW Squelch B"
private let kWBCWMainSidetoneLevel = "WBCW Main Sidetone Level"
private let kWBCWSubSidetoneLevel = "WBCW Sub Sidetone Level"

@objc(CWRxControl)
class CWRxControl: RTTYRxControl {

    @objc var bandwidthMenu: NSPopUpButton!
    @objc var wideButton: NSButton!
    @objc var panoButton: NSButton!
    @objc var levelSlider: NSSlider!
    @objc var monitorButton: NSButton!
    @objc var speedMenu: NSPopUpButton!
    @objc var cwSquelchSlider: NSSlider!
    @objc var reportSpeed: NSTextField!
    @objc var latencyMenu: NSPopUpButton!

    var cwEnabled: Bool = false
    var cwMonitor: CWMonitor!
    var previousReportedSpeed: Int32 = 0

    var lockedTonePair = CMTonePair()

    @objc(initIntoView:client:index:)
    override init?(intoView view: NSView?, client modem: Modem?, index: Int32) {
        super.init()
        previousReportedSpeed = 0
        if Bundle.main.loadNibNamed("CWRxControl", owner: self, topLevelObjects: nil) {
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

    @objc override func awakeFromNib() {
        spectrumView = nil
        waterfall = nil
        monitor = nil
        tonePair.mark = 0.0             //  not demodulating until clicked
        tonePair.space = 0.0           //  space and baud not used in CW mode
        tonePair.baud = 0.0
        sideband = 0
        rxPolarity = 0
        txPolarity = 0
        activeTransmitter = false
        cwEnabled = false
        vfoOffset = 0
        ritOffset = 0
        txLocked = false
        monitor = nil

        setInterface(inputAttenuator, to: #selector(inputAttenuatorChanged))
        setInterface(bandwidthMenu, to: #selector(bandwidthChanged))
        setInterface(wideButton, to: #selector(widenessChanged))
        setInterface(levelSlider, to: #selector(levelChanged))
        setInterface(panoButton, to: #selector(widenessChanged))
        setInterface(monitorButton, to: #selector(monitorEnableChanged))
        setInterface(speedMenu, to: #selector(speedChanged))
        setInterface(cwSquelchSlider, to: #selector(cwSquelchChanged))
        setInterface(latencyMenu, to: #selector(latencyChanged))
    }

    @objc(setupWithClient:index:)
    override func setupWithClient(_ modem: Modem?, index: Int32) {
        uniqueID = index
        client = modem as? RTTY
        setupDefaultFilters()
        speedChanged()      //  set up default wpm

        receiver = CWReceiver(receiver: index, modem: modem)
        receiver.setReceiveView(exchangeView)
    }

    @objc(setupCWReceiverWithMonitor:)
    func setupCWReceiverWithMonitor(_ sidetone: CWMonitor!) {
        cwMonitor = sidetone
        (receiver as? CWReceiver)?.setupReceiverChain(config, monitor: sidetone)     //  v0.88d
        config.setClient(self)
    }

    @objc(newClick:)
    func newClick(_ delta: Float) {
        (receiver as? CWReceiver)?.newClick(delta)
    }

    @objc(enableCWReceiver:)
    func enableCWReceiver(_ state: Bool) {
        if cwEnabled == state { return }

        cwEnabled = state
        (receiver as? CWReceiver)?.changingState(to: state)
        cwMonitor?.enableSidetone(state, index: uniqueID)
    }

    //  audio source starts at config and is routed here first
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if receiver == nil || !receiver.enabled { return }

        //  send data through the processing chain if waterfall has been clicked
        if receiver != nil && cwEnabled { receiver.importData(pipe) }

        //  send data to waterfall display
        waterfall?.importData(pipe)
    }

    //  mark tone of tonepair is used in CW mode as the CW frequency
    @objc(setTonePair:)
    override func setTonePair(_ tonepair: UnsafePointer<CMTonePair>) {
        tonePair = tonepair.pointee

        //  send frequencies to receiver
        receiver?.rxTonePairChanged(self)
        //  and to config if we are the selected transmitter
        if activeTransmitter { (config as? CWConfig)?.txTonePairChanged(self) }
        //  set cross ellipse filters
        if tuningView != nil {
            var rxTonepair = rxTonePair()
            tuningView.setTonePair(&rxTonepair)
        }
        if waterfall != nil {
            waterfall.setSideband(sideband)
            waterfall.setTonePairMarker(tonepair, index: uniqueID)
            waterfall.setRITOffset(ritOffset)
            if txLocked {
                //  tx locked
                waterfall.setTransmitTonePairMarker(&lockedTonePair, index: uniqueID)
            }
        }
        if config != nil { (config as? RTTYConfig)?.setTonePairMarker(tonepair) }
    }

    @objc(lockTonePairToCurrentTone)
    func lockTonePairToCurrentTone() {
        lockedTonePair = rxTonePair()
    }

    @objc(setFrequency:)
    func setFrequency(_ freq: Float) {
        var tempTonePair = CMTonePair()
        tempTonePair.mark = Double(freq)
        tempTonePair.space = 0.0            //  CW has no space tone
        tempTonePair.baud = 0.0
        setTonePair(&tempTonePair)
    }

    @objc(setupDefaultFilters)
    override func setupDefaultFilters() {
        setTuningIndicatorState(true)
        //  receive views
        receiveTextAttribute = exchangeView.newAttribute()
        exchangeView.delegate = client as? NSTextViewDelegate
    }

    @objc(fetchTonePairFromMemory)
    override func fetchTonePairFromMemory() {
        //  no tone pair memory in CW mode
    }

    @objc func latencyChanged() {
        let latency = Int32(latencyMenu.selectedItem?.tag ?? 0)
        (receiver as? CWReceiver)?.setLatency(latency)
    }

    @objc override func bandwidthChanged() {
        let bandwidth = Float(bandwidthMenu.selectedItem?.tag ?? 0)
        (receiver as? CWReceiver)?.setCWBandwidth(bandwidth)
    }

    @objc func widenessChanged() {
        let isWide = (wideButton.state == .on)
        (client as? WBCW)?.enableWide(isWide, index: uniqueID)

        if isWide {
            panoButton.isEnabled = true
            let isPano = (panoButton.state == .on)
            (client as? WBCW)?.enablePano(isPano, index: uniqueID)
        } else {
            panoButton.isEnabled = false
        }
    }

    @objc func cwSquelchChanged() {
        let limit: Float = -2.25
        var v = cwSquelchSlider.floatValue
        if v > limit { cwSquelchSlider.floatValue = limit }

        var qsb: Float = -30.0      //  fixed 30 dB depth
        if qsb > limit { qsb = limit }

        v = cwSquelchSlider.floatValue
        (client as? WBCW)?.changeSquelchTo(v, fastQSB: qsb, slowQSB: qsb * 0.32, index: uniqueID)
    }

    @objc func monitorEnableChanged() {
        if monitorButton == nil { return }

        let isEnable = (monitorButton.state == .on) && monitorButton.isEnabled

        bandwidthMenu.isEnabled = isEnable
        wideButton.isEnabled = isEnable
        let panoEnabled = isEnable && (wideButton.state == .on)
        panoButton.isEnabled = panoEnabled
        levelSlider.isEnabled = isEnable

        (client as? WBCW)?.enableMonitor(isEnable, index: uniqueID)
    }

    @objc(setMonitorEnableButton:)
    func setMonitorEnableButton(_ state: Bool) {
        if monitorButton != nil {
            monitorButton.isEnabled = state
            monitorEnableChanged()
        }
    }

    @objc func speedChanged() {
        let speed = Int32(speedMenu.selectedItem?.tag ?? 0)
        reportSpeed.stringValue = "Speed"
        previousReportedSpeed = 0
        (client as? WBCW)?.changeSpeedTo(speed, index: uniqueID)
    }

    @objc(setReportedSpeed:limited:)
    func setReportedSpeed(_ wpm: Int32, limited: Bool) {
        if wpm != previousReportedSpeed {
            previousReportedSpeed = wpm
            if wpm == 0 {
                reportSpeed.stringValue = " . . . "
            } else {
                reportSpeed.stringValue = String(format: limited ? "%d* wpm" : "%d wpm", wpm)
            }
        }
    }

    @objc func levelChanged() {
        let v = levelSlider.floatValue
        (client as? WBCW)?.monitorLevel(powf(10.0, v / 20.0), index: uniqueID)
    }

    @objc(updateTonePairInformation)
    override func updateTonePairInformation() {
        //  sideband
        let previous = sideband
        sideband = Int32(sidebandMenu.indexOfSelectedItem)
        (client as? WBCW)?.sidebandChanged(sideband, index: uniqueID)
        setTonePair(&tonePair)

        //  update waterfall sideband
        if sideband != previous && waterfall != nil {
            var pair = CMTonePair(mark: 0.0, space: 0.0, baud: 45.45)
            waterfall.setSideband(sideband)
            waterfall.setTonePairMarker(&pair, index: uniqueID)
        }
    }

    @objc(rxTonePair)
    override func rxTonePair() -> CMTonePair {
        var adjusted = tonePair
        adjusted.mark += Double(ritOffset)      //  RIT
        return adjusted
    }

    @objc(txTonePair)
    override func txTonePair() -> CMTonePair {
        return tonePair
    }

    //  Plist support
    @objc(setupDefaultPreferences:config:)
    override func setupDefaultPreferences(_ pref: Preferences!, config cfg: ModemConfig!) {
        setupBasicDefaultPreferences(pref, config: cfg)
        pref.setInt(0, forKey: (uniqueID == 0) ? kWBCWMainMonitor : kWBCWSubMonitor)
        pref.setInt(100, forKey: (uniqueID == 0) ? kWBCWMainBandwidth : kWBCWSubBandwidth)
        pref.setFloat(cwSquelchSlider.floatValue, forKey: (uniqueID == 0) ? kWBCWMainSquelch : kWBCWSubSquelch)
        pref.setFloat(0.0, forKey: (uniqueID == 0) ? kWBCWMainSidetoneLevel : kWBCWSubSidetoneLevel)
    }

    @objc(updateFromPlist:config:)
    override func updateFromPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        updateBasicFromPlist(pref, config: cfg)
        let state = pref.intValue(forKey: (uniqueID == 0) ? kWBCWMainMonitor : kWBCWSubMonitor)
        cwSquelchSlider.floatValue = pref.floatValue(forKey: (uniqueID == 0) ? kWBCWMainSquelch : kWBCWSubSquelch)
        cwSquelchChanged()
        monitorButton.state = (state != 0) ? .on : .off
        monitorEnableChanged()
        let value = pref.intValue(forKey: (uniqueID == 0) ? kWBCWMainBandwidth : kWBCWSubBandwidth)
        bandwidthMenu.selectItem(withTag: Int(value))
        bandwidthChanged()

        let dB = pref.floatValue(forKey: (uniqueID == 0) ? kWBCWMainSidetoneLevel : kWBCWSubSidetoneLevel)
        levelSlider.floatValue = dB
        levelChanged()
    }

    @objc(retrieveForPlist:config:)
    override func retrieveForPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        retrieveBasicForPlist(pref, config: cfg)
        pref.setInt((monitorButton.state == .on) ? 1 : 0, forKey: (uniqueID == 0) ? kWBCWMainMonitor : kWBCWSubMonitor)
        pref.setFloat(cwSquelchSlider.floatValue, forKey: (uniqueID == 0) ? kWBCWMainSquelch : kWBCWSubSquelch)
        pref.setInt(Int32(bandwidthMenu.selectedItem?.tag ?? 0), forKey: (uniqueID == 0) ? kWBCWMainBandwidth : kWBCWSubBandwidth)
        pref.setFloat(levelSlider.floatValue, forKey: (uniqueID == 0) ? kWBCWMainSidetoneLevel : kWBCWSubSidetoneLevel)
    }

    //  AppleScript support
    @objc(invertStateForTransmitter)
    override func invertStateForTransmitter() -> Bool {
        return false
    }

    @objc(setInvertStateForTransmitter:)
    override func setInvertStateForTransmitter(_ state: Bool) {
        //  do nothing in CW
    }
}
