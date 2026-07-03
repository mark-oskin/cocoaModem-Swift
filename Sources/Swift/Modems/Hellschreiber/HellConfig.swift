//
//  HellConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Wed Jul 27 2005.
//  Swift port of HellConfig.m.  HellConfig is the nib-loaded Hellschreiber
//  configuration panel; it remains a subclass of ModemConfig (now Swift).
//  HellModulator and ModemEqualizer are Swift; the Hellschreiber modem (still
//  Objective-C, in the bridging header) and the forward-declared oscilloscope /
//  VU meter instruments are reached through informal @objc protocols (the
//  AMConfig / PSKConfig pattern).  The unused `-setColorRed:...`/`-getColorRed:...`
//  overrides are dropped: the (Swift) ModemConfig base already provides identical
//  implementations, so behaviour is preserved by inheritance.
//

import Cocoa

//  --- Plist keys (defined byte-for-byte in Plist.h) ---
private let kHellActive             = "Hell Active"
private let kHellSideband           = "Hell Mode"
private let kHellDiddle             = "Hell Diddle"
private let kHellOffset             = "Hell Offset"
private let kHellOutputLevel        = "Hell Output Sound Level"
private let kHellOutputAttenuator   = "Hell Output Attenuator"
private let kHellInputDevice        = "Hell Input Device"
private let kHellOutputDevice       = "Hell Output Device"
private let kHellTextColor          = "Hell Text Color"
private let kHellSentColor          = "Hell Sent Color"
private let kHellBackgroundColor    = "Hell Background Color"
private let kHellPlotColor          = "Hell Plot Color"
private let kAutoConnect            = "Device AutoConnect"
private let kFastPlayback           = "Fast file playback"

private let LEFTCHANNEL: Int32 = 0

@objc(HellConfig)
class HellConfig: ModemConfig {

    @IBOutlet var sidebandMenu: NSPopUpButton!
    @IBOutlet var vfoOffset: NSTextField!
    //  test tone
    @IBOutlet var testFreq: NSTextField!
    //  Hellschreiber diddle
    @IBOutlet var diddleButton: NSButton!

    //  sound interface
    private var hellModulator: HellModulator!
    private var idleTone: HellModulator!
    private var soundFileRunning: Bool = false
    private var equalize: Float = 1.0

    //  fonts
    private var fonts: Int32 = 0
    private var font = [UnsafeMutablePointer<HellschreiberFontHeader>?](repeating: nil, count: 10)

    private var hell: Hellschreiber? { modemObj as? Hellschreiber }

    //  Hellschreiber Config

    private func loadFont(_ name: String) {
        let path = Bundle.main.path(forResource: name, ofType: "font")
        let cpath = (path as NSString?)?.cString(using: String.Encoding.isoLatin1.rawValue)
        guard let fnt = MakeHellFont(cpath) else { return }
        guard Int(fonts) < font.count else { return }
        font[Int(fonts)] = fnt
        hell?.addFont(fnt, index: fonts)
        fonts += 1
    }

    @objc(awakeFromModem:)
    func awakeFromModem(_ modem: Hellschreiber) {
        equalize = 1.0

        fonts = 0
        //  get default fonts
        loadFont("cm bitmap")
        loadFont("cm bitmap aa")
        loadFont("cm small")
        loadFont("cm small aa")
        loadFont("cm bitmapdoublewide")

        toneMatrix = nil
        transmitButton = nil
        timeout = nil
        soundFileRunning = false
        vuMeter = modem.vuMeter

        super.initializeActions()

        //  set up modulator
        hellModulator = HellModulator()
        hellModulator.setFrequency(10.0)        //  default to 10 Hz carrier
        hellModulator.setModemClient(modemObj as? Hellschreiber)
        hellModulator.setFont(font[0])
        //  test tones
        idleTone = HellModulator()
        idleTone.setCW(true)
        idleTone.setFrequency(1000.0)

        (vuMeter as? VUMeter)?.setup()
        fastFileSpeed = 4
        setupModemSource(kHellInputDevice, channel: LEFTCHANNEL)
        setupModemDest(kHellOutputDevice, controlView: soundOutputControls, attenuatorView: soundOutputLevel as? NSView)
        modemDest.setSoundLevelKey(kHellOutputLevel, attenuatorKey: kHellOutputAttenuator)

        //  Set up Transmit equalizer
        equalizer = ModemEqualizer(sheetFor: "Hellschreiber")
        equalize = 1.0

        //  delegate to trap config panel closure
        window?.delegate = self

        //  actions
        setInterface(vfoOffset, to: #selector(sidebandOrOffsetChanged))
        setInterface(sidebandMenu, to: #selector(sidebandOrOffsetChanged))
        setInterface(diddleButton, to: #selector(diddleChanged))

        //  start sampling later in an NSTimer driven -checkActive
        modemSource.enableInput(true)
    }

    @objc(selectFont:)
    func selectFont(_ index: Int32) {
        hellModulator.setFont(font[Int(index)])
    }

    @objc(setMode:)
    func setMode(_ mode: Int32) {
        hellModulator.setMode(mode)
    }

    //  v0.87
    @objc override func setKeyerMode() {
        if let ptt = pttObject() {
            ptt.setKeyerMode(kMicrohamDigitalRouting)      //  v0.93b
        }
    }

    //  data arrived from sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if ((isActiveButton && !isTransmit) || modemSource.fileRunning()) && interfaceVisible {
            if let src = pipe.stream() { data.pointee = src.pointee }
            exportData()
            (vuMeter as? VUMeter)?.importData(pipe)
        }
        if configOpen, let osc = oscilloscope as? Oscilloscope {
            osc.addData(pipe.stream(), isBaudot: false, timebase: 1)
        }
    }

    //  0 - LSB
    //  1 - USB
    @objc(setSideband:)
    func setSideband(_ index: Int32) {
        sidebandMenu?.selectItem(at: Int(index))
        switch index {
        case 1:
            hell?.selectAlternateSideband(true)
            hellModulator.setSidebandState(true)
        default:
            hell?.selectAlternateSideband(false)
            hellModulator.setSidebandState(false)
        }
    }

    //  preferences maintainence, called from Hellschreiber.m
    //  setup default preferences (keys are found in Plist.h)
    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setInt(0, forKey: kHellActive)
        pref.setInt(1, forKey: kFastPlayback)
        pref.setInt(1, forKey: kHellSideband)          //  default to USB
        pref.setFloat(0.0, forKey: kHellOffset)        //  and no VFO offset
        retrieveActualColorPreferences(pref)

        modemSource.setupDefaultPreferences(pref)
        modemDest.setupDefaultPreferences(pref)
        equalizer.setupDefaultPreferences(pref)

        pref.setInt(0, forKey: kHellDiddle)
    }

    @objc(updateColorsFromPreferences:)
    override func updateColorsFromPreferences(_ pref: Preferences!) {
        let color = getColor(kHellTextColor, from: pref)
        let sent = getColor(kHellSentColor, from: pref)
        let bg = getColor(kHellBackgroundColor, from: pref)
        let plot = getColor(kHellPlotColor, from: pref)

        //  set colors
        textColor?.color = color ?? .black
        transmitTextColor?.color = sent ?? .black
        backgroundColor?.color = bg ?? .black
        plotColor?.color = plot ?? .black
        (oscilloscope as? Oscilloscope)?.setDisplayStyle(0, plotColor: plot)   //  initially spectrum
        hell?.setTextColor(color, sentColor: sent, backgroundColor: bg, plotColor: plot)
        hell?.updateColorsInViews()
    }

    //  called from Hellschreiber.m
    //  update all parameters from the plist (called after fetchPlist)
    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences) -> Bool {
        //  set up active button states and set the button states
        //  later, a Timer would activate to obey these buttons
        activeButton?.state = (pref.intValue(forKey: kHellActive) == 1) ? .on : .off

        //  now reset active states if autoconnect is off
        if pref.intValue(forKey: kAutoConnect) == 0 { activeButton?.state = .off }

        updateColorsFromPreferences(pref)

        if (!modemSource.updateFromPlist(pref) || !modemDest.updateFromPlist(pref)) && (activeButton?.state == .on) {
            activeButton?.state = .off
            //  toggle input attenuator
            let selStr = "Hellschreiber: " + NSLocalizedString("Select Sound Card", comment: "")
            _ = Messages.alert(withMessageText: selStr, informativeText: NSLocalizedString("Device removed", comment: ""))
        }
        modemSource.setDeviceLevel(hell?.inputAttenuator(self))
        equalizer.updateFromPlist(pref)

        setSideband(pref.intValue(forKey: kHellSideband))
        vfoOffset?.floatValue = pref.floatValue(forKey: kHellOffset)
        updateDialOffset()      //  this updates the labels of the waterfall

        var state = pref.intValue(forKey: kFastPlayback)
        fileSpeedCheckbox?.state = (state != 0) ? .on : .off
        updateFileSpeed()

        state = pref.intValue(forKey: kHellDiddle)
        diddleButton?.state = (state != 0) ? .on : .off
        hellModulator.setDiddle(state != 0)

        return true
    }

    @objc(retrieveActualColorPreferences:)
    override func retrieveActualColorPreferences(_ pref: Preferences!) {
        set(kHellTextColor, fromColor: textColor?.color ?? .black, into: pref)
        set(kHellSentColor, fromColor: transmitTextColor?.color ?? .black, into: pref)
        set(kHellBackgroundColor, fromColor: backgroundColor?.color ?? .black, into: pref)
        set(kHellPlotColor, fromColor: plotColor?.color ?? .black, into: pref)
    }

    //  update preference dictionary for writing back into the plist file
    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        retrieveActualColorPreferences(pref)
        //  Hellschreiber input prefs
        modemSource.retrieveForPlist(pref)
        pref.setInt((fileSpeedCheckbox?.state == .on) ? 1 : 0, forKey: kFastPlayback)
        //  Hellschreiber output prefs
        modemDest.retrieveForPlist(pref)
        equalizer.retrieveForPlist(pref)

        //  active button states and local flag
        pref.setInt((activeButton?.state == .on) ? 1 : 0, forKey: kHellActive)
        pref.setInt((diddleButton?.state == .on) ? 1 : 0, forKey: kHellDiddle)
        let index = sidebandMenu?.indexOfSelectedItem ?? 0
        pref.setInt(Int32(index), forKey: kHellSideband)
        pref.setFloat(vfoOffset?.floatValue ?? 0, forKey: kHellOffset)
    }

    @objc func startModulator() {
        hellModulator.resetModulator()
        hellModulator.insertShortIdle()
    }

    //  -------------- transmit stream ---------------------
    @objc func startTransmit() -> Bool {
        let canTransmit = hell?.checkTx() ?? false
        if !canTransmit {
            _ = Messages.alert(withMessageText: NSLocalizedString("Hellschreiber not on", comment: ""),
                               informativeText: NSLocalizedString("Click on waterfall", comment: ""))
            hell?.flushOutput()
            return false
        }

        if isActiveButton && !isTransmit && interfaceVisible && !configOpen {
            toneIndex = 0
            //  first stop the audio output stream
            modemDest.stopSampling()
            //  now set the correct frequency
            let frequency = hell?.transmitFrequency() ?? 0
            hellModulator.setFrequency(frequency)
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
            let selStr = "Hellschreiber: " + NSLocalizedString("Select Sound Card", comment: "")
            _ = Messages.alert(withMessageText: selStr, informativeText: NSLocalizedString("make interface active", comment: ""))
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
            hell?.transmissionEnded()
        }
        return false
    }

    @objc(transmitCharacter:)
    func transmitCharacter(_ ascii: Int32) {
        if ascii == 5 /* switch to receive */ {
            hellModulator.insertEndOfTransmit()
            return
        }
        if ascii == 0x6 { return }      //  ignore %[tx] hint

        hellModulator.appendASCII(ascii)
    }

    @objc func flushTransmitBuffer() {
        hellModulator.flushTransmitBuffer()
    }

    //  accepts a button
    //  returns YES if Hellschreiber modemDest is Transmiting
    @objc(turnOnTransmission:button:)
    func turnOnTransmission(_ inState: Bool, button: NSButton?) -> Bool {
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
            hell?.executePTT(false)
            toneIndex = 0
        default:
            toneIndex = index
            let freq = testFreq?.floatValue ?? 0
            idleTone.setFrequency(freq)
            hell?.executePTT(true)
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
            hell?.setWaterfallOffset(0.0, sideband: 1)
            return
        }
        var offset = vfoOffset?.floatValue ?? 0
        //  use LSB/USB to indicate offset sign in modemObj
        if offset < 0.0 { offset = -offset }
        hell?.setWaterfallOffset(offset, sideband: Int32(sidebandMenu?.indexOfSelectedItem ?? 0))
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
        hell?.setTextColor(textColor?.color, sentColor: transmitTextColor?.color,
                           backgroundColor: backgroundColor?.color, plotColor: plotColor?.color)
    }

    //  sideband or VFO offset changed
    @objc func sidebandOrOffsetChanged() {
        setSideband(Int32(sidebandMenu?.indexOfSelectedItem ?? 0))
        updateDialOffset()
    }

    //  diddle changed
    @objc func diddleChanged() {
        hellModulator.setDiddle(diddleButton?.state == .on)
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

        switch toneIndex {
        case 0:
            //  regular transmission
            hellModulator.getBufferWithIdleFill(outbuf, length: samples)
            if hellModulator.terminated() {
                hell?.changeTransmitStateTo(false)
            }
        default:
            //  idle
            idleTone.getBufferWithIdleFill(outbuf, length: samples)
        }
        if equalizer != nil {
            for i in 0..<Int(samples) { outbuf[i] *= equalize }
        }
        return 1    //  output channels
    }

    @objc(setOutputScale:)
    override func setOutputScale(_ value: Float) {
        outputScale = value
        hellModulator.setOutputScale(outputScale)
        idleTone.setOutputScale(outputScale)
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
