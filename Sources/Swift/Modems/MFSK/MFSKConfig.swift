//
//  MFSKConfig.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on  2/15/06.
//  Swift port of MFSKConfig.m (nib-loaded MFSK16/DominoEX config panel).
//

import Cocoa

//  --- Plist keys (defined in Plist.h, kept byte-for-byte) ---
private let kMFSKActive           = "MFSK Active"
private let kMFSKSideband          = "MFSK Mode"
private let kMFSKOffset             = "MFSK Offset"
private let kMFSKOutputLevel        = "MFSK Output Sound Level"
private let kMFSKOutputAttenuator   = "MFSK Output Attenuator"
private let kMFSKInputDevice        = "MFSK Input Device"
private let kMFSKOutputDevice       = "MFSK Output Device"
private let kMFSKTextColor          = "MFSK Text Color"
private let kMFSKSentColor          = "MFSK Sent Color"
private let kMFSKBackgroundColor    = "MFSK Background Color"
private let kMFSKPlotColor          = "MFSK Plot Color"
private let kAutoConnect            = "Device AutoConnect"
private let kFastPlayback           = "Fast file playback"

private let LEFTCHANNEL: Int32 = 0

@objc(MFSKConfig)
class MFSKConfig: ModemConfig {

    //  MFSK-specific IBOutlets
    @IBOutlet var sidebandMenu: NSPopUpButton!
    @IBOutlet var vfoOffset: NSTextField!
    //  test tone
    @IBOutlet var testFreq: NSTextField!

    //  transmit modulators
    private var modulator: MFSKModulator!
    private var idleTone: MFSKModulator!
    private var equalize: Float = 1.0

    //  modemObj (inherited Modem!) is always an MFSK for this config
    private var mfsk: MFSK? { modemObj as? MFSK }

    //  MFSK Config

    @objc(awakeFromModem:)
    func awakeFromModem(_ modem: MFSK) {
        toneMatrix = nil
        transmitButton = nil
        timeout = nil
        vuMeter = modem.vuMeter

        super.initializeActions()

        fastFileSpeed = 16
        setupModemSource(kMFSKInputDevice, channel: LEFTCHANNEL)
        setupModemDest(kMFSKOutputDevice, controlView: soundOutputControls, attenuatorView: soundOutputLevel as? NSView)
        modemDest?.setSoundLevelKey(kMFSKOutputLevel, attenuatorKey: kMFSKOutputAttenuator)
        //  Set up Transmit equalizer
        equalizer = ModemEqualizer(sheetFor: "MFSK")
        equalize = 1.0
        //  test tone
        timeout = nil
        idleTone = MFSKModulator()
        idleTone?.setCW(true)
        idleTone?.setFrequency(1000.0)

        //  delegate to trap config panel closure
        window?.delegate = self
        //  start sampling later in an NSTimer driven -checkActive
        modemSource?.enableInput(true)
        //  actions
        setInterface(vfoOffset, to: #selector(sidebandOrOffsetChanged))
        setInterface(sidebandMenu, to: #selector(sidebandOrOffsetChanged))
    }

    //  v0.87
    override func setKeyerMode() {
        if let ptt = pttObject() {
            ptt.setKeyerMode(kMicrohamDigitalRouting)      //  v0.93b
        }
    }

    //  0 - LSB
    //  1 - USB
    @objc(setSideband:)
    func setSideband(_ index: Int32) {
        sidebandMenu?.selectItem(at: Int(index))
        switch index {
        case 1:
            mfsk?.selectAlternateSideband(true)
        default:
            mfsk?.selectAlternateSideband(false)
        }
    }

    //  accepts a button
    //  returns YES if modemDest is Transmiting
    @objc(turnOnTransmission:button:modulator:)
    func turnOnTransmission(_ inState: Bool, button: NSButton!, modulator m: MFSKModulator!) -> Bool {
        transmitButton = button
        return inState ? startTransmit(m) : stopTransmit()
    }

    //  data arrived from sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        let active = isActiveButton && !isTransmit
        let fileRun = modemSource?.fileRunning() ?? false
        if (active || fileRun) && interfaceVisible {
            if let s = pipe.stream(), data != nil {
                data.pointee = s.pointee
            }
            exportData()
            (vuMeter as? CMPipe)?.importData(pipe)
        }
        if configOpen, let osc = oscilloscope as? Oscilloscope, let s = pipe.stream() {
            osc.addData(s, isBaudot: false, timebase: 1)
        }
    }

    //  check active button
    override func updateActiveButtonState() -> Bool {
        _ = super.updateActiveButtonState()
        return isActiveButton
    }

    @objc func updateDialOffset() {
        var offset = vfoOffset?.floatValue ?? 0.0
        //  use LSB/USB to indicate offset sign in modemObj
        if offset < 0.0 { offset = -offset }
        mfsk?.setWaterfallOffset(offset, sideband: Int32(sidebandMenu?.indexOfSelectedItem ?? 0))
    }

    //  -------------- transmit stream ---------------------
    @objc(startTransmit:)
    func startTransmit(_ m: MFSKModulator!) -> Bool {
        let canTransmit = (mfsk?.checkIfCanTransmit()) ?? false
        if !canTransmit {
            _ = Messages.alert(withMessageText: NSLocalizedString("MFSK cannot transmit.", comment: ""),
                               informativeText: NSLocalizedString("Frequency not set", comment: ""))
            mfsk?.flushOutput()
            return false
        }

        let frequency = mfsk?.transmitFrequency() ?? 0.0
        modulator = m

        if isActiveButton && !isTransmit && interfaceVisible && !configOpen {
            toneIndex = 0
            //  first stop the audio output stream
            modemDest?.stopSampling()
            //  now set the modulator to the current frequency
            modulator?.setFrequency(frequency)
            //  adjust amplitude based on equalizer here
            if let eq = equalizer {
                equalize = eq.amplitude(frequency)
            } else {
                equalize = 1.0
            }
            //  reset the modulator
            modulator?.resetModulator()
            //  finally turn output stream back on
            modemDest?.startSampling()
            if let button = transmitButton {
                button.title = NSLocalizedString("Receive", comment: "")
                button.state = .on
            }
            isTransmit = true
            return true
        }
        isTransmit = false
        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
        if let button = transmitButton {
            button.title = NSLocalizedString("Transmit", comment: "")
            button.state = .off
        }
        if !isActiveButton {
            _ = Messages.alert(withMessageText: NSLocalizedString("Sound Card not active", comment: ""),
                               informativeText: NSLocalizedString("make interface active", comment: ""))
        } else if configOpen {
            _ = Messages.alert(withMessageText: NSLocalizedString("Cannot transmit with the Config Panel open", comment: ""),
                               informativeText: NSLocalizedString("Close Config Panel and try Again", comment: ""))
        }
        return false
    }

    @objc(stopTransmit)
    func stopTransmit() -> Bool {
        if isTransmit {
            isTransmit = false
            modemDest?.stopSampling()
            if let button = transmitButton {
                button.title = NSLocalizedString("Transmit", comment: "")
                button.state = .off
            }
            modemObj?.transmissionEnded()
        }
        return false
    }

    //  ---------------- ModemDest callbacks ---------------------

    //  modemDest needs more data
    @objc(needData:samples:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples n: Int32) -> Int32 {
        //  assume
        //  outputSamplingRate = 11025
        //  outputChannels = 1
        switch toneIndex {
        case 0:
            //  regular transmission
            modulator?.getBufferWithIdleFill(outbuf, length: n)
            if modulator?.terminated() == true {
                modemObj?.changeTransmitStateTo(false)
            }
        default:
            //  idle
            idleTone?.getBufferWithIdleFill(outbuf, length: n)
        }
        if equalizer != nil {
            var i = 0
            while i < Int(n) {
                outbuf[i] *= equalize
                i += 1
            }
        }
        return 1        //  output channels
    }

    @objc(setOutputScale:)
    override func setOutputScale(_ value: Float) {
        outputScale = value
        mfsk?.setOutputScale(value)
        idleTone?.setOutputScale(value)
    }

    /* local */
    @objc(selectTestTone:)
    func selectTestTone(_ index: Int32) {
        guard let tm = toneMatrix else { return }

        tm.deselectAllCells()
        tm.selectCell(atRow: 0, column: Int(index))
        if let t = timeout {
            t.invalidate()
            timeout = nil
        }
        switch index {
        case 0:
            modemDest?.stopSampling()
            modemObj?.executePTT(false)
            toneIndex = 0
        default:
            toneIndex = index
            let freq = testFreq?.floatValue ?? 0.0
            idleTone?.setFrequency(freq)
            modemObj?.executePTT(true)
            modemDest?.startSampling()
        }
    }

    //  watchdog timer, turn test tone off
    @objc(timedOut:)
    func timedOut(_ timer: Timer!) {
        timeout = nil
        selectTestTone(0)
        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
    }

    @IBAction func testToneChanged(_ sender: Any?) {
        toneMatrix = sender as? NSMatrix
        let index = Int32(toneMatrix?.selectedColumn ?? 0)
        selectTestTone(index)
        if index != 0 {
            timeout = Timer.scheduledTimer(timeInterval: 3 * 60, target: self,
                                           selector: #selector(timedOut(_:)), userInfo: self, repeats: false)
        }
    }

    @IBAction func openEqualizer(_ sender: Any?) {
        if let eq = equalizer, let w = window {
            eq.showMacroSheet(in: w)
        }
    }

    /* local */
    @objc(setupDefaultColorPreferences:)
    func setupDefaultColorPreferences(_ pref: Preferences!) {
        set(kMFSKTextColor, fromRed: 1.0, green: 0.8, blue: 0.0, into: pref)
        set(kMFSKBackgroundColor, fromRed: 0.0, green: 0.0, blue: 0.0, into: pref)
        set(kMFSKPlotColor, fromRed: 0.0, green: 1.0, blue: 0.0, into: pref)
        set(kMFSKSentColor, fromRed: 0.0, green: 0.8, blue: 1.0, into: pref)
    }

    //  preferences maintainence, called from MFSK.m
    //  setup default preferences (keys are found in Plist.h)
    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences!) {
        pref.setInt(1, forKey: kFastPlayback)
        pref.setInt(0, forKey: kMFSKActive)
        setupDefaultColorPreferences(pref)
        modemSource?.setupDefaultPreferences(pref)
        modemDest?.setupDefaultPreferences(pref)
        equalizer?.setupDefaultPreferences(pref)
    }

    @objc(updateColorsFromPreferences:)
    override func updateColorsFromPreferences(_ pref: Preferences!) {
        guard let color = getColor(kMFSKTextColor, from: pref),
              let sent = getColor(kMFSKSentColor, from: pref),
              let bg = getColor(kMFSKBackgroundColor, from: pref),
              let plot = getColor(kMFSKPlotColor, from: pref) else { return }
        //  set colors
        textColor?.color = color
        transmitTextColor?.color = sent
        backgroundColor?.color = bg
        plotColor?.color = plot
        (oscilloscope as? Oscilloscope)?.setDisplayStyle(0, plotColor: plot)  //  initially spectrum
        modemObj?.setTextColor(color, sentColor: sent, backgroundColor: bg, plotColor: plot)
        modemObj?.updateColorsInViews()
    }

    //  called from MFSK.m
    //  update all parameters from the plist (called after fetchPlist)
    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences!) -> Bool {
        updateColorsFromPreferences(pref)

        //  preserve ObjC ||-short-circuit: modemDest is only updated when modemSource succeeds
        if (!(modemSource?.updateFromPlist(pref) ?? false)
            || !(modemDest?.updateFromPlist(pref) ?? false))
            && (activeButton?.state == .on) {
            activeButton?.state = .off
            //  toggle input attenuator
            let selStr = "MFSK16/DominoEX: " + NSLocalizedString("Select Sound Card", comment: "")
            _ = Messages.alert(withMessageText: selStr,
                               informativeText: NSLocalizedString("Device removed", comment: ""))
        }

        //  set up active button state
        activeButton?.state = (pref.intValue(forKey: kMFSKActive) == 1) ? .on : .off
        //  now reset active states if autoconnect is off
        if pref.intValue(forKey: kAutoConnect) == 0 { activeButton?.state = .off }

        modemSource?.setDeviceLevel(modemObj?.inputAttenuator(self))
        equalizer?.updateFromPlist(pref)

        setSideband(pref.intValue(forKey: kMFSKSideband))
        vfoOffset?.floatValue = pref.floatValue(forKey: kMFSKOffset)
        updateDialOffset()      //  this updates the labels of the waterfall

        let state = pref.intValue(forKey: kFastPlayback)
        fileSpeedCheckbox?.state = (state != 0) ? .on : .off
        updateFileSpeed()

        return true
    }

    @objc(retrieveActualColorPreferences:)
    override func retrieveActualColorPreferences(_ pref: Preferences!) {
        if let c = textColor?.color { set(kMFSKTextColor, fromColor: c, into: pref) }
        if let c = transmitTextColor?.color { set(kMFSKSentColor, fromColor: c, into: pref) }
        if let c = backgroundColor?.color { set(kMFSKBackgroundColor, fromColor: c, into: pref) }
        if let c = plotColor?.color { set(kMFSKPlotColor, fromColor: c, into: pref) }
    }

    //  update preference dictionary for writing back into the plist file
    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences!) {
        retrieveActualColorPreferences(pref)
        //  MFSK input prefs
        modemSource?.retrieveForPlist(pref)
        pref.setInt((fileSpeedCheckbox?.state == .on) ? 1 : 0, forKey: kFastPlayback)
        //  MFSK output prefs
        modemDest?.retrieveForPlist(pref)
        equalizer?.retrieveForPlist(pref)

        //  active button states and local flag
        pref.setInt((activeButton?.state == .on) ? 1 : 0, forKey: kMFSKActive)
        pref.setInt(Int32(sidebandMenu?.indexOfSelectedItem ?? 0), forKey: kMFSKSideband)
        pref.setFloat(vfoOffset?.floatValue ?? 0.0, forKey: kMFSKOffset)
    }

    // -------------------------------------------------------------------

    override func colorChanged(_ client: Any?) {
        guard let pc = plotColor else { return }
        (oscilloscope as? Oscilloscope)?.setDisplayStyle(Int32(waveformMatrix?.selectedRow ?? 0), plotColor: pc.color)
        modemObj?.setTextColor(textColor?.color, sentColor: transmitTextColor?.color,
                              backgroundColor: backgroundColor?.color, plotColor: pc.color)
    }

    //  sideband or VFO offset changed
    @objc func sidebandOrOffsetChanged() {
        setSideband(Int32(sidebandMenu?.indexOfSelectedItem ?? 0))
        mfsk?.turnOffReceiver(0, option: false)         //  v0.73
        updateDialOffset()
    }

    //  ------------------------ Delegates -----------------------
    //  delegate for Config panel
    @objc override func windowShouldClose(_ sender: NSWindow) -> Bool {
        configOpen = false
        updateInputSamplingState()
        //  turn tone matrix selection to OFF if it was on
        if toneIndex != 0 {
            toneMatrix?.deselectAllCells()
            toneMatrix?.selectCell(atRow: 0, column: 0)
            selectTestTone(0)
            toneIndex = 0
        }
        return true
    }
}
