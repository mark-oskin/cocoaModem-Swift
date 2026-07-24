//
//  FAX.swift
//  cocoaModem
//
//  Created by Kok Chen on Mar 6 2006.
//  Swift port of FAX.m / FAX.h.
//
//  The HF-FAX mode tab.  FAX : Modem.  It is instantiated by StdManager via
//  -initIntoTabView:manager: and loads the "HF-FAX" nib.
//
//  Port notes:
//   * Every original ivar keeps its EXACT name.  `id` outlets become
//     `@objc var … : AnyObject!` and are messaged through optional chaining /
//     casts.  The `inputAttenuator` outlet is renamed `inputAttenuatorOutlet`
//     (with @objc(inputAttenuator) preserving the nib key) so it does not clash
//     with the inherited Modem `-inputAttenuator:` accessor — same treatment as
//     SynchAM.swift.  The `vuMeter` ivar and the `-vuMeter` accessor are unified
//     into one `@objc var vuMeter`.
//   * The C `BitmapContext` typedef in FAX.h was unused (no ivar / reference in
//     FAX.m and no external users) and is dropped.
//   * FAXReceiver, FAXDisplay, VUMeter, Waterfall, ModemConfig/ModemSource are
//     already Swift and used directly.  FAXConfig is still Objective-C and is
//     reached by casting the inherited `config` outlet to FAXConfig.
//

import Cocoa

@objc(FAX)
class FAX: Modem {

    //  --- IBOutlets ---
    @objc var waterfall: AnyObject!

    //  the outlet is named "inputAttenuator"; the inherited -inputAttenuator:
    //  accessor shares the base name, so the stored property is renamed and
    //  given the exact nib key via @objc (mirrors SynchAM).
    @objc(inputAttenuator) var inputAttenuatorOutlet: AnyObject!
    //  ivar `vuMeter` and the `-vuMeter` accessor unified into one property.
    @objc var vuMeter: VUMeter!

    @objc var bandwidthMenu: AnyObject!

    //  AudioPipes
    @objc var rx: FAXReceiver!

    @objc var thread: Thread!

    //  demodulator
    @objc var vfoOffset: Float = 0
    @objc var sideband: Int32 = 0

    //  Prefs
    @objc var sidebandState: Bool = false
    //  receive
    @objc var receiveWait: Timer!

    //  the config panel object (a FAXConfig, connected by the nib)
    private var faxConfig: FAXConfig? { return config as? FAXConfig }

    //  =======================================================================
    //  FAX : Modem : CMPipe
    //  =======================================================================

    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr.showSplash("Creating FAX Modem")

        super.init(into: tabview, nib: "HF-FAX", manager: mgr)

        manager = mgr
    }

    @objc(setInterface:to:)
    override func setInterface(_ object: NSControl!, to selector: Selector!) {
        object?.action = selector
        object?.target = self
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("HF-FAX", comment: "")

        faxConfig?.awakeFromModem(self)
        sidebandState = false
        waterfall?.awakeFromModem?()
        waterfall?.enableIndicator?(self)
        //  set up the scroller for the input view
        if let sview = receiveView?.superview?.superview as? NSScrollView {
            let scroller = sview.verticalScroller
            //  -setFloatValue:knobProportion: is unavailable in Swift; set the
            //  two NSScroller properties it wrapped directly.
            scroller?.floatValue = 1.0
            scroller?.knobProportion = 0.125
        }

        vuMeter?.setup()
        rx = nil

        faxConfig?.inputSource()?.registerDeviceSlider(inputAttenuatorOutlet as? NSSlider)   //  v0.80

        setInterface(bandwidthMenu as? NSControl, to: #selector(bandwidthChanged))
        setInterface(inputAttenuatorOutlet as? NSControl, to: #selector(inputAttenuatorChanged))  //  v0.80 was missing earlier
    }

    //  v0.87
    override func switchModemIn() {
        //  do nothing in receive only interface
    }

    @objc func inputAttenuatorChanged() {
        faxConfig?.inputSource()?.setDeviceLevel(inputAttenuatorOutlet as? NSSlider)
    }

    @objc(setVisibleState:)
    override func setVisibleState(_ visible: Bool) {
        if visible {
            //  start the FAXDisplay (which should create the bitmap if it does not already exist)
            (receiveView as? FAXDisplay)?.start()
            //  initialize receiver if this is the first time we are made visible
            if rx == nil {
                //  create receiver
                rx = FAXReceiver(fromModem: self)
                rx?.enableReceiver(true)
            }
        }
        super.setVisibleState(visible)
    }

    @objc(configObj)
    func configObj() -> FAXConfig! {
        return config as? FAXConfig
    }

    @objc(faxView)
    func faxView() -> FAXDisplay! {
        return receiveView as? FAXDisplay
    }

    //  overide base class to change AudioPipe pipeline (assume source is normalized)
    //		source
    //		. self(importData)
    //			. waterfall
    //			. receiver
    //			. VU Meter
    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating HF-FAX sound source")
        //  send codec data here
        faxConfig?.setClient(self)
        faxConfig?.checkActive()
    }

    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        //  mirror the Objective-C cast (CMTappedPipe*)self -- self is a CMPipe.
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    //  process the new data buffer
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        //  send data to users
        rx?.importData(pipe)
        (waterfall as? CMPipe)?.importData(pipe)
        vuMeter?.importData(pipe)
    }

    //  waterfall clicked
    //  Note: for USB left edge is always 400 Hz no matter what the VFO offset is
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    override func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID index: Int32) {
        rx?.selectFrequency(freq, fromWaterfall: acquire)
        rx?.enableReceiver(true)
    }

    //  receive frequency set not by clicking, but by direct entry
    @objc(receiveFrequency:)
    func receiveFrequency(_ freq: Float) {
        frequencyUpdatedTo(freq)
        clicked(freq, secondsAgo: 0, option: false, fromWaterfall: false, waterfallID: 0)
    }

    //  frequency update from HellReceiver
    @objc(frequencyUpdatedTo:)
    func frequencyUpdatedTo(_ tone: Float) {
        waterfall?.forceToneTo?(tone, receiver: 0)
    }

    @objc(setWaterfallOffset:sideband:)
    func setWaterfallOffset(_ freq: Float, sideband polarity: Int32) {
        let offset = abs(freq)

        vfoOffset = offset
        sideband = polarity

        waterfall?.setOffset?(freq, sideband: sideband)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)

        pref.setInt(0, forKey: kFAXActive)
        pref.setInt(0, forKey: kFAXSize)

        faxConfig?.setupDefaultPreferences(pref)
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = super.updateFromPlist(pref)

        manager?.showSplash("Updating HF-FAX configurations")
        _ = faxConfig?.updateFromPlist(pref)
        //  v0.80 registers with ModemSource and setup half/full button
        inputAttenuatorChanged()
        faxView()?.setupScale(pref.intValue(forKey: kFAXSize) != 0)

        plistHasBeenUpdated = true                      //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }       //  v0.53d
        super.retrieveForPlist(pref)
        faxConfig?.retrieveForPlist(pref)
        pref.setInt((faxView()?.scaleIsFullSize() == true) ? 1 : 0, forKey: kFAXSize)   //  v0.80
    }

    //  sideband state (set from PSKConfig's LSB/USB button)
    //  NO = LSB
    @objc(selectAlternateSideband:)
    func selectAlternateSideband(_ state: Bool) {
        sidebandState = state
        waterfall?.setSideband?(state ? 1 : 0)
    }

    @objc(waterfallRangeChanged:)
    func waterfallRangeChanged(_ sender: Any!) {
        waterfall?.setDynamicRange?((sender as? NSControl)?.floatValue ?? 0)
    }

    @objc func bandwidthChanged() {
        rx?.changeBandwidth(to: Int32((bandwidthMenu as? NSPopUpButton)?.indexOfSelectedItem ?? 0))
    }
}
