//
//  SynchAM.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/17/07.
//  Swift port of SynchAM.m.  SynchAM remains a subclass of the Objective-C
//  class Modem (Modem stays Objective-C; its header is in the bridging header).
//
//  This is the Synchronous-AM mode tab.  It is instantiated by StdManager via
//  -initIntoTabView:manager: and loads the "SynchAM" nib.
//

import Cocoa

//  --- Plist keys (defined in Plist.h, which is not in the bridging header) ---
private let kSynchAMLockCenter = "AM Lock Center"
private let kSynchAMLockRange  = "AM Lock Range"
private let kSynchAMVolume     = "AM Volume"
private let kSynchAMEqEnable    = "AM Eq Enable"
private let kSynchAMEq300      = "AM Eq 300"
private let kSynchAMEq600      = "AM Eq 600"
private let kSynchAMEq1200     = "AM Eq 1200"
private let kSynchAMEq2400     = "AM Eq 2400"
private let kSynchAMEq4800     = "AM Eq 4800"

//  Informal access to still-Objective-C collaborators that are not in the
//  bridging header (resolved dynamically through AnyObject message dispatch,
//  the same pattern used by QSO.swift).
@objc private protocol SynchAMLightInformal {
    @objc func setBackgroundColor(_ color: NSColor?)
}
@objc private protocol SynchAMVUMeterInformal {
    @objc func setup()
}
@objc private protocol SynchAMSourceInformal {
    @objc func setDeviceLevel(_ slider: NSSlider?)
}

@objc(SynchAM)
class SynchAM: Modem {

    //  outlets connected by SynchAM.nib -- names must match nib keys exactly
    @objc var waterfall: AMWaterfall!
    //  the outlet is named "inputAttenuator"; the accessor -inputAttenuator: has
    //  the same base name so the stored property is renamed and given the exact
    //  nib key via @objc.
    @objc(inputAttenuator) var inputAttenuatorOutlet: NSSlider!
    @objc var vuMeter: AnyObject!

    @objc var volumeSlider: NSSlider!
    @objc var muteCheckbox: NSButton!

    @objc var lockRangeSlider: NSSlider!
    @objc var lockOffsetSlider: NSSlider!
    @objc var lockLight: AnyObject!

    @objc var equalizerCheckbox: NSButton!
    @objc var eq300Slider: NSSlider!
    @objc var eq600Slider: NSSlider!
    @objc var eq1200Slider: NSSlider!
    @objc var eq2400Slider: NSSlider!
    @objc var eq4800Slider: NSSlider!

    private var lockState: Int32 = 0
    //  demodulator
    private var demodulator: AMDemodulator?
    //  output
    private var outputScale: Float = 0.0      // stepped attenuator in aural config

    //  the config panel object (an AMConfig, connected by the nib)
    private var amConfig: AMConfig? { return configObj(0) as? AMConfig }

    //  inherited Modem ivar plistHasBeenUpdated is not visible to Swift; access via KVC
    private var plistUpdated: Bool {
        get { (value(forKey: "plistHasBeenUpdated") as? NSNumber)?.boolValue ?? false }
        set { setValue(newValue, forKey: "plistHasBeenUpdated") }
    }

    //  SynchAM : Modem : CMPipe
    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr.showSplash("Creating Synch-AM Modem")

        super.init(into: tabview, nib: "SynchAM", manager: mgr)

        //  (super already stored manager = mgr)
        lockState = -1
        outputScale = 0.707
    }

    @objc(setInterface:to:)
    override func setInterface(_ object: NSControl!, to selector: Selector!) {
        object.action = selector
        object.target = self
    }

    override func awakeFromNib() {
        setValue(NSLocalizedString("Synch-AM", comment: ""), forKey: "ident")

        amConfig?.awakeFromModem(self)
        waterfall?.awakeFromModem()
        waterfall?.enableIndicator(self)

        setInterface(lockRangeSlider, to: #selector(lockParamsChanged))
        setInterface(lockOffsetSlider, to: #selector(lockParamsChanged))

        setInterface(volumeSlider, to: #selector(volumeChanged))
        setInterface(muteCheckbox, to: #selector(volumeChanged))

        setInterface(equalizerCheckbox, to: #selector(equalizerCheckboxChanged))
        setInterface(eq300Slider, to: #selector(equalizerChanged(_:)))
        setInterface(eq600Slider, to: #selector(equalizerChanged(_:)))
        setInterface(eq1200Slider, to: #selector(equalizerChanged(_:)))
        setInterface(eq2400Slider, to: #selector(equalizerChanged(_:)))
        setInterface(eq4800Slider, to: #selector(equalizerChanged(_:)))

        setInterface(inputAttenuatorOutlet, to: #selector(inputAttenuatorChanged))

        demodulator = AMDemodulator()
        demodulator?.setClient(self)

        vuMeter?.setup?()
    }

    //  v0.87
    @objc(switchModemIn) override func switchIn() {
        //  do nothing in receive only interface
    }

    @objc(inputAttenuator:)
    override func inputAttenuator(_ config: ModemConfig!) -> NSSlider! {
        return inputAttenuatorOutlet
    }

    @objc func inputAttenuatorChanged() {
        (amConfig?.value(forKey: "modemSource") as AnyObject?)?.setDeviceLevel?(inputAttenuatorOutlet)
    }

    @objc func equalizerChanged(_ sender: Any?) {
        let n: Int32
        let s = sender as AnyObject?
        if s === eq300Slider { n = 300 }
        else if s === eq600Slider { n = 600 }
        else if s === eq1200Slider { n = 1200 }
        else if s === eq2400Slider { n = 2400 }
        else if s === eq4800Slider { n = 4800 }
        else { return }

        var value = ((sender as? NSControl)?.floatValue ?? 0) * 0.95
        if value < 0.01 { value = 0.01 }
        value = sqrt(value)
        demodulator?.setEqualizer(n, value: value)
    }

    @objc func equalizerCheckboxChanged() {
        if equalizerCheckbox.state == .on {
            eq300Slider.isEnabled = true
            equalizerChanged(eq300Slider)
            eq600Slider.isEnabled = true
            equalizerChanged(eq600Slider)
            eq1200Slider.isEnabled = true
            equalizerChanged(eq1200Slider)
            eq2400Slider.isEnabled = true
            equalizerChanged(eq2400Slider)
            eq4800Slider.isEnabled = true
            equalizerChanged(eq4800Slider)
            demodulator?.setEqualizerEnable(true)
        } else {
            eq300Slider.isEnabled = false
            eq600Slider.isEnabled = false
            eq1200Slider.isEnabled = false
            eq2400Slider.isEnabled = false
            eq4800Slider.isEnabled = false
            demodulator?.setEqualizerEnable(false)
        }
    }

    @objc func lockParamsChanged() {
        let width = lockRangeSlider.floatValue * 0.5
        let center = lockOffsetSlider.floatValue

        var low = center - width
        var high = center + width

        if low < -90 {
            low = -90
            high = low + width * 2
            if high > 110 { high = 110 }
        }
        if high > 110 {
            high = 110
            low = high - width * 2
            if low < -90 { low = -90 }
        }

        low += 200
        high += 200

        var fc = demodulator?.carrier() ?? 0
        if fc < low { fc = low } else if fc > high { fc = high }

        waterfall?.setTrack(fc, low: low, high: high)
        demodulator?.setTrack(fc, low: low, high: high)
    }

    @objc func volumeChanged() {
        let v: Float
        if muteCheckbox.state == .on {
            v = 0.0
        } else {
            let slider = volumeSlider.floatValue
            v = powf(10.0, slider / 20.0) * outputScale
        }
        demodulator?.setVolume(v)
    }

    @objc(setOutputScale:)
    func setOutputScale(_ v: Float) {
        outputScale = v
        volumeChanged()
    }

    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        //  mirror the Objective-C cast (CMTappedPipe*)self -- self is a CMPipe and
        //  is only ever used as a CMPipe (passed to -setClient:).
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    //  overide base class to change AudioPipe pipeline (assume source is normalized)
    //		source
    //		. self(importData)
    //			. demodulator
    //				. self
    //			. waterfall
    //			. VU Meter
    override func updateSourceFromConfigInfo() {
        managerObject()?.showSplash("Updating Synchronous AM sound source")
        //  send codec data here
        amConfig?.setClient(self)
        amConfig?.checkActive()
    }

    //  process the new data buffer
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        demodulator?.importData(pipe)
        waterfall?.importData(pipe)
        (vuMeter as? CMPipe)?.importData(pipe)
    }

    @objc(setOutput:samples:)
    func setOutput(_ array: UnsafeMutablePointer<Float>?, samples n: Int32) {
        amConfig?.setOutput(array, samples: n)
    }

    @objc(setLock:freq:)
    func setLock(_ delta: Float, freq f: Float) -> Int32 {
        let d = abs(delta)
        let color: NSColor
        let state: Int32
        if d > 2.0 {
            state = 0
            color = .gray
        } else {
            if d < 1.0 {
                color = .green
                state = 2
            } else {
                color = .yellow
                state = 1
            }
        }
        if state != lockState {
            lockLight?.setBackgroundColor?(color)
            lockState = state
        }
        waterfall?.setTrack(f)
        return lockState
    }

    @objc(setWaterfallOffset:sideband:)
    func setWaterfallOffset(_ freq: Float, sideband polarity: Int32) {
        waterfall?.setOffset(freq, sideband: polarity)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)
        amConfig?.setupDefaultPreferences(pref)

        pref.setFloat(0.0, forKey: kSynchAMLockCenter)
        pref.setFloat(50.0, forKey: kSynchAMLockRange)
        pref.setFloat(-30.0, forKey: kSynchAMVolume)

        pref.setFloat(0.5, forKey: kSynchAMEq300)
        pref.setFloat(0.5, forKey: kSynchAMEq600)
        pref.setFloat(0.5, forKey: kSynchAMEq1200)
        pref.setFloat(0.5, forKey: kSynchAMEq2400)
        pref.setFloat(0.5, forKey: kSynchAMEq4800)
        pref.setInt(0, forKey: kSynchAMEqEnable)
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func update(fromPlist pref: Preferences!) -> Bool {
        _ = super.update(fromPlist: pref)

        managerObject()?.showSplash("Updating Synchronous AM configurations")
        _ = amConfig?.updateFromPlist(pref)

        lockOffsetSlider.floatValue = pref.floatValue(forKey: kSynchAMLockCenter)
        lockRangeSlider.floatValue = pref.floatValue(forKey: kSynchAMLockRange)
        lockParamsChanged()

        volumeSlider.floatValue = pref.floatValue(forKey: kSynchAMVolume)
        volumeChanged()

        eq300Slider.floatValue = pref.floatValue(forKey: kSynchAMEq300)
        equalizerChanged(eq300Slider)
        eq600Slider.floatValue = pref.floatValue(forKey: kSynchAMEq600)
        equalizerChanged(eq600Slider)
        eq1200Slider.floatValue = pref.floatValue(forKey: kSynchAMEq1200)
        equalizerChanged(eq1200Slider)
        eq2400Slider.floatValue = pref.floatValue(forKey: kSynchAMEq2400)
        equalizerChanged(eq2400Slider)
        eq4800Slider.floatValue = pref.floatValue(forKey: kSynchAMEq4800)
        equalizerChanged(eq4800Slider)

        equalizerCheckbox.state = (pref.intValue(forKey: kSynchAMEqEnable) == 0) ? .off : .on
        equalizerCheckboxChanged()

        plistUpdated = true                             //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieve(forPlist pref: Preferences!) {
        if plistUpdated == false { return }             //  v0.53d

        pref.setFloat(lockOffsetSlider.floatValue, forKey: kSynchAMLockCenter)
        pref.setFloat(lockRangeSlider.floatValue, forKey: kSynchAMLockRange)
        pref.setFloat(volumeSlider.floatValue, forKey: kSynchAMVolume)

        pref.setFloat(eq300Slider.floatValue, forKey: kSynchAMEq300)
        pref.setFloat(eq600Slider.floatValue, forKey: kSynchAMEq600)
        pref.setFloat(eq1200Slider.floatValue, forKey: kSynchAMEq1200)
        pref.setFloat(eq2400Slider.floatValue, forKey: kSynchAMEq2400)
        pref.setFloat(eq4800Slider.floatValue, forKey: kSynchAMEq4800)

        pref.setInt((equalizerCheckbox.state == .off) ? 0 : 1, forKey: kSynchAMEqEnable)

        super.retrieve(forPlist: pref)
        amConfig?.retrieveForPlist(pref)
    }
}
