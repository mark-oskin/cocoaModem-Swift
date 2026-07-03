//
//  PSKConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Tue Jul 27 2004.
//  Swift port of PSKConfig.m.  PSKConfig is the nib-loaded PSK configuration
//  panel; it remains a subclass of ModemConfig (now Swift).  PSK, PSKModulator,
//  PSKAuralMonitor and the sound source/destination collaborators are reached
//  either through their Swift types or, for the still-Objective-C PSK modem,
//  through informal @objc protocols (the AMConfig / QSO.swift pattern).
//

import Cocoa

//  --- Plist keys (defined byte-for-byte in Plist.h) ---
private let kPSKActive            = "PSK Active"
private let kFastPlayback         = "Fast file playback"
private let kPSKSideband          = "PSK Mode"
private let kPSKOffset            = "PSK Offset"
private let kPSKInputDevice       = "PSK Input Device"
private let kPSKOutputDevice      = "PSK Output Device"
private let kPSKOutputLevel       = "PSK Output Sound Level"
private let kPSKOutputAttenuator  = "PSK Output Attenuator"
private let kPSKTextColor         = "PSK Text Color"
private let kPSKSentColor         = "PSK Sent Color"
private let kPSKBackgroundColor   = "PSK Background Color"
private let kPSKPlotColor         = "PSK Plot Color"
private let kAutoConnect          = "Device AutoConnect"

private let LEFTCHANNEL: Int32 = 0

@objc(PSKConfig)
class PSKConfig: ModemConfig {

    @IBOutlet var sidebandMenu: NSPopUpButton!
    @IBOutlet var vfoOffset: NSTextField!
    //  test tone
    @IBOutlet var testFreq: NSTextField!

    //  sound interface
    private var pskModulator: PSKModulator!
    private var idleTone: PSKModulator!
    private var soundFileRunning: Bool = false
    private var equalize: Float = 1.0

    private var auralMonitor: PSKAuralMonitor?      //  v0.78
    private var overrun: NSLock!

    //  PSK Config

    @objc(awakeFromModem:)
    func awakeFromModem(_ modem: PSK) {
        toneMatrix = nil
        transmitButton = nil
        timeout = nil
        soundFileRunning = false
        setClient(modem)

        overrun = NSLock()

        super.initializeActions()

        //  set up modulator
        pskModulator = PSKModulator()
        pskModulator.setFrequency(10.0)        //  default to 10 Hz carrier
        pskModulator.setModemClient(modemObj)

        //  actions
        setInterface(vfoOffset, to: #selector(sidebandOrOffsetChanged))
        setInterface(sidebandMenu, to: #selector(sidebandOrOffsetChanged))

        //  test tones
        idleTone = PSKModulator()
        idleTone.setFrequency(1000.0)

        fastFileSpeed = 4
        setupModemSource(kPSKInputDevice, channel: LEFTCHANNEL)
        setupModemDest(kPSKOutputDevice, controlView: soundOutputControls, attenuatorView: soundOutputLevel as? NSView)
        modemDest.setSoundLevelKey(kPSKOutputLevel, attenuatorKey: kPSKOutputAttenuator)

        //  Transmit monitor (cached at -needData)
        auralMonitor = nil
        //  Set up Transmit equalizer
        equalizer = ModemEqualizer(sheetFor: "PSK")
        equalize = 1.0
        //  delegate to trap config panel closure
        window.delegate = self

        //  start sampling later in an NSTimer driven -checkActive
        modemSource.enableInput(true)
    }

    //  data arrived from sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        sequenceNumber += 1
        if overrun.try() {
            //  discard overruns
            if interfaceVisible {
                if (isActiveButton && !isTransmit) || modemSource.fileRunning() {
                    if let src = pipe.stream() { data.pointee = src.pointee }
                    exportData()
                }
                if configOpen, let osc = oscilloscope as? Oscilloscope {
                    osc.addData(pipe.stream(), isBaudot: false, timebase: 1)
                }
            }
            overrun.unlock()
        }
    }

    //  0 - LSB
    //  1 - USB
    @objc(setPSKSideband:)
    func setPSKSideband(_ index: Int32) {
        sidebandMenu?.selectItem(at: Int(index))
        switch index {
        case 1:
            (modemObj as? PSK)?.selectAlternateSideband(true)
        default:
            (modemObj as? PSK)?.selectAlternateSideband(false)
        }
    }

    //  v0.87
    @objc override func setKeyerMode() {
        if let ptt = pttObject() {
            ptt.setKeyerMode(kMicrohamDigitalRouting)      //  v0.93b
        }
    }

    //  preferences maintenance, called from PSK.m
    //  setup default preferences (keys are found in Plist.h)
    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setInt(0, forKey: kPSKActive)
        pref.setInt(1, forKey: kFastPlayback)
        pref.setInt(1, forKey: kPSKSideband)               //  default to USB
        pref.setFloat(0.0, forKey: kPSKOffset)             //  and no VFO offset
        retrieveActualColorPreferences(pref)

        modemSource.setupDefaultPreferences(pref)
        modemDest.setupDefaultPreferences(pref)
        equalizer.setupDefaultPreferences(pref)
    }

    @objc(updateColorsFromPreferences:)
    override func updateColorsFromPreferences(_ pref: Preferences!) {
        let color = getColor(kPSKTextColor, from: pref)
        let sent = getColor(kPSKSentColor, from: pref)
        let bg = getColor(kPSKBackgroundColor, from: pref)
        let plot = getColor(kPSKPlotColor, from: pref)

        //  set colors
        textColor?.color = color ?? .black
        transmitTextColor?.color = sent ?? .black
        backgroundColor?.color = bg ?? .black
        plotColor?.color = plot ?? .black
        (oscilloscope as? Oscilloscope)?.setDisplayStyle(0, plotColor: plot)  //  initially spectrum
        (modemObj as? PSK)?.setTextColor(color, sentColor: sent, backgroundColor: bg, plotColor: plot)
    }

    //  called from PSK.m
    //  update all parameters from the plist (called after fetchPlist)
    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences) -> Bool {
        //  set up active button states and set the button states
        //  later, a Timer would activate to obey these buttons
        activeButton?.state = (pref.intValue(forKey: kPSKActive) == 1) ? .on : .off

        //  now reset active states if autoconnect is off
        if pref.intValue(forKey: kAutoConnect) == 0 { activeButton?.state = .off }

        updateColorsFromPreferences(pref)

        if (!modemSource.updateFromPlist(pref) || !modemDest.updateFromPlist(pref)) && (activeButton?.state == .on) {
            activeButton?.state = .off
            //  toggle input attenuator
            _ = Messages.alert(withMessageText: NSLocalizedString("PSK settings needs to be reselected", comment: ""),
                               informativeText: NSLocalizedString("Device removed", comment: ""))
        }
        modemSource.setDeviceLevel((modemObj as? PSK)?.inputAttenuator(self) ?? nil)
        equalizer.updateFromPlist(pref)

        setPSKSideband(pref.intValue(forKey: kPSKSideband))
        vfoOffset?.floatValue = pref.floatValue(forKey: kPSKOffset)
        updateDialOffset()      //  this updates the labels of the waterfall

        let state = pref.intValue(forKey: kFastPlayback)
        fileSpeedCheckbox?.state = (state != 0) ? .on : .off
        updateFileSpeed()

        return true
    }

    @objc(retrieveActualColorPreferences:)
    override func retrieveActualColorPreferences(_ pref: Preferences!) {
        set(kPSKTextColor, fromColor: textColor?.color ?? .black, into: pref)
        set(kPSKSentColor, fromColor: transmitTextColor?.color ?? .black, into: pref)
        set(kPSKBackgroundColor, fromColor: backgroundColor?.color ?? .black, into: pref)
        set(kPSKPlotColor, fromColor: plotColor?.color ?? .black, into: pref)
    }

    //  update preference dictionary for writing back into the plist file
    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        retrieveActualColorPreferences(pref)
        //  PSK input prefs
        modemSource.retrieveForPlist(pref)
        pref.setInt((fileSpeedCheckbox?.state == .on) ? 1 : 0, forKey: kFastPlayback)
        //  PSK output prefs
        modemDest.retrieveForPlist(pref)
        equalizer.retrieveForPlist(pref)

        //  active button states and local flag
        pref.setInt((activeButton?.state == .on) ? 1 : 0, forKey: kPSKActive)
        let index = sidebandMenu?.indexOfSelectedItem ?? 0
        pref.setInt(Int32(index), forKey: kPSKSideband)
        pref.setFloat(vfoOffset?.floatValue ?? 0, forKey: kPSKOffset)
    }

    @objc func startModulator() {
        pskModulator.resetModulator()
        pskModulator.insertShortIdle()
    }

    //  -------------- transmit stream ---------------------

    @objc(setTransmitFrequency:)
    func setTransmitFrequency(_ freq: Float) {
        pskModulator.setFrequency(freq)
    }

    @objc func startTransmit() -> Bool {
        let canTransmit = (modemObj as? PSK)?.checkTx() ?? false
        if !canTransmit {
            _ = Messages.alert(withMessageText: NSLocalizedString("Selected PSK Transceiver not on", comment: ""),
                               informativeText: NSLocalizedString("need to set xcvr", comment: ""))
            (modemObj as? PSK)?.flushOutput()
            return false
        }

        if isActiveButton && interfaceVisible && !isTransmit && !configOpen {
            toneIndex = 0
            //  first stop the audio output stream
            modemDest.stopSampling()
            //  now set the correct frequency
            let frequency = (modemObj as? PSK)?.transmitFrequency() ?? 0
            setTransmitFrequency(frequency)
            //  adjust amplitude based on equalizer here
            equalize = (equalizer != nil) ? equalizer.amplitude(frequency) : 1.0

            //  turn on the modulator
            startModulator()
            //  finally turn output stream back on
            modemDest.startSampling()
            if let transmitButton = transmitButton {
                transmitButton.title = NSLocalizedString("Receive", comment: "")
                transmitButton.state = .on
            }
            isTransmit = true
            return true
        }
        isTransmit = false
        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
        if let transmitButton = transmitButton {
            transmitButton.title = NSLocalizedString("Transmit", comment: "")
            transmitButton.state = .off
        }
        if !isActiveButton {
            _ = Messages.alert(withMessageText: NSLocalizedString("psk sound not active", comment: ""),
                               informativeText: NSLocalizedString("make interface active", comment: ""))
        } else if configOpen {
            _ = Messages.alert(withMessageText: NSLocalizedString("Close Config Panel", comment: ""),
                               informativeText: NSLocalizedString("Close Config Panel and try Again", comment: ""))
        }
        return false
    }

    @objc func stopTransmit() -> Bool {
        if isTransmit {
            isTransmit = false
            modemDest.stopSampling()
            if let transmitButton = transmitButton {
                transmitButton.title = NSLocalizedString("Transmit", comment: "")
                transmitButton.state = .off
            }
            flushTransmitBuffer()      //  0.46
            (modemObj as? PSK)?.transmissionEnded()
        }
        return false
    }

    @objc(transmitCharacter:)
    func transmitCharacter(_ ascii: Int32) {
        if ascii == 0x5 {                       //  %[rx]
            pskModulator.insertSquelchTail()
            return
        }
        if ascii == 0x6 { return }              //  ignore %[tx] for now
        pskModulator.appendASCII(ascii)
    }

    //  v0.70
    @objc(transmitDoubleByteCharacter:second:)
    func transmitDoubleByteCharacter(_ first: Int32, second: Int32) {
        if first == 0 {
            if second == 0x5 {                  //  %[rx]
                pskModulator.insertSquelchTail()
                return
            }
            if second == 0x6 { return }         //  ignore %[tx] for now
        }
        pskModulator.appendDoubleByte(first, second: second)
    }

    @objc func flushTransmitBuffer() {
        pskModulator.resetModulatorAndFlush()   //  v0.44
    }

    //  accepts a button
    //  returns YES if PSK modemDest is Transmitting
    @objc(turnOnTransmission:button:mode:)
    func turnOnTransmission(_ inState: Bool, button: NSButton?, mode: Int32) -> Bool {
        pskModulator.setPSKMode(mode)
        transmitButton = button
        return inState ? startTransmit() : stopTransmit()
    }

    /* local */
    @objc(selectTestTone:)
    func selectTestTone(_ index: Int32) {
        guard let toneMatrix = toneMatrix else { return }

        toneMatrix.deselectAllCells()
        toneMatrix.selectCell(atRow: 0, column: Int(index))
        if let t = timeout {
            t.invalidate()
            timeout = nil
        }
        switch index {
        case 0:
            modemDest.stopSampling()
            (modemObj as? PSK)?.executePTT(false)
        default:
            toneIndex = index
            let freq = testFreq?.floatValue ?? 0
            idleTone.setFrequency(freq)
            (modemObj as? PSK)?.executePTT(true)
            modemDest.startSampling()
        }
    }

    //  watchdog timer, turn test tone off
    @objc(timedOut:)
    func timedOut(_ timer: Timer?) {
        timeout = nil
        selectTestTone(0)
        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
    }

    @objc func updateDialOffset() {
        if false && soundFileRunning {
            //  use "USB" for soundfiles, with 0 vfo offset
            (modemObj as? PSK)?.setWaterfallOffset(0.0, sideband: 1)
            return
        }

        var offset = vfoOffset?.floatValue ?? 0
        //  use LSB/USB to indicate offset sign in modemObj
        if offset < 0.0 { offset = -offset }
        (modemObj as? PSK)?.setWaterfallOffset(offset, sideband: Int32(sidebandMenu?.indexOfSelectedItem ?? 0))
    }

    //  called from ModemSource when file starts
    @objc(soundFileStarting:)
    override func soundFileStarting(_ filename: String!) {
        soundFileRunning = true
        updateDialOffset()
    }

    //  called from ModemSource when file stopped
    @objc func soundFileStopped() {
        soundFileRunning = false
        updateDialOffset()
    }

    // -------------------------------------------------------------------
    @objc override func colorChanged(_ client: Any?) {
        (oscilloscope as? Oscilloscope)?.setDisplayStyle(Int32(waveformMatrix?.selectedRow ?? 0), plotColor: plotColor?.color)
        (modemObj as? PSK)?.setTextColor(textColor?.color, sentColor: transmitTextColor?.color,
                                                            backgroundColor: backgroundColor?.color, plotColor: plotColor?.color)
    }

    //  sideband or VFO offset changed
    @objc func sidebandOrOffsetChanged() {
        setPSKSideband(Int32(sidebandMenu?.indexOfSelectedItem ?? 0))
        updateDialOffset()
    }

    @objc func testToneChanged(_ sender: Any?) {
        toneMatrix = sender as? NSMatrix
        let index = Int32(toneMatrix?.selectedColumn ?? 0)
        selectTestTone(index)
        if index != 0 {
            timeout = Timer.scheduledTimer(timeInterval: 3 * 60, target: self,
                                           selector: #selector(timedOut(_:)), userInfo: self, repeats: false)
        }
    }

    @objc func openEqualizer(_ sender: Any?) {
        if let equalizer = equalizer { equalizer.showMacroSheet(in: window) }
    }

    //  ---------------- ModemDest callbacks ---------------------

    //  modemDest needs more data
    @objc(needData:samples:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples samples: Int32) -> Int32 {
        //  assume
        //  outputSamplingRate = 11025
        //  outputChannels = 1

        //  cache auralMonitor
        if auralMonitor == nil { auralMonitor = (outputClient as? PSK)?.auralMonitor() ?? nil }

        let n = Int(samples)
        switch toneIndex {
        case 0:
            //  regular transmission
            pskModulator.getBufferWithIdleFill(outbuf, length: samples)
            if outbuf[n - 2] == 0.0 && outbuf[n - 1] == 0.0 {
                (modemObj as? PSK)?.changeTransmitStateTo(false)
            }
        default:
            //  idle
            idleTone.getBufferWithIdleFill(outbuf, length: samples)
        }
        //  send prescaled value to aural monitor
        auralMonitor?.importTransmitData(outbuf)

        let v = (equalizer != nil) ? equalize * outputScale : outputScale
        for i in 0..<n { outbuf[i] *= v }

        return 1    //  output channels
    }

    @objc(setOutputScale:)
    override func setOutputScale(_ value: Float) {
        outputScale = value * ((modemObj as? PSK)?.outputBoost ?? 1.0)  //  v0.88 allow 2 dB boost
        pskModulator.setOutputScale(1.0)      //  v0.78 apply scale at needData
        idleTone.setOutputScale(1.0)
    }

    //  ------------------------ Delegates -----------------------
    //  delegate for Config panel
    @objc override func windowShouldClose(_ sender: NSWindow) -> Bool {
        configOpen = false
        updateInputSamplingState()
        modemDest.stopSampling()
        //  turn tone matrix selection to OFF
        toneMatrix?.deselectAllCells()
        toneMatrix?.selectCell(atRow: 0, column: 0)
        toneIndex = 0

        return true
    }
}
