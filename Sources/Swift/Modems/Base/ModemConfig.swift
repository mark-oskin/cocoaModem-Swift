//
//  ModemConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Sat Jul 31 2004.
//  Swift port of ModemConfig.m.  ModemConfig is the common base of the 14
//  nib-loaded modem configuration panels.  It remains a subclass of DestClient
//  (now also Swift).  Its instance variables are kept as EXACT-named stored
//  properties: subclasses (in this and other batches) reference them by name,
//  and the already-converted AMConfig.swift reaches several of them through KVC,
//  so those are exposed with @objc / @IBOutlet.
//
//  Naming notes (cross-batch contract):
//   * The `long sequenceNumber` ivar and its trivial `-sequenceNumber` getter
//     collapse into the single `@objc var sequenceNumber: Int` property (the
//     getter selector `sequenceNumber` is preserved).  PSKConfig increments it.
//   * The `float outputScale` ivar is kept as a plain (non-@objc) `outputScale`
//     property so its synthesized setter does NOT collide with the inherited
//     `setOutputScale:` selector.  Subclasses access it by Swift name.
//   * The empty base `-soundFileStopped` stub is dropped (ModemSource dispatches
//     it via respondsToSelector:; subclasses that need it supply their own).
//

import Cocoa

//  v0.93b microHAM routing
let kMicrohamAutoRouting: Int32    = 0
let kMicrohamDigitalRouting: Int32 = 2
let kMicrohamCWRouting: Int32      = 4
let kMicrohamFSKRouting: Int32     = 5

//  oscilloscope is a forward-declared id in the original; reach its one entry

@objc(ModemConfig)
class ModemConfig: DestClient, NSWindowDelegate {

    @IBOutlet var window: NSWindow!
    @IBOutlet var modemObj: Modem!

    //  common control
    @IBOutlet var activeButton: NSButton!
    @IBOutlet var soundOutputLevel: AnyObject!
    @IBOutlet var waveformMatrix: NSMatrix!
    @IBOutlet var textColor: NSColorWell!
    @IBOutlet var transmitTextColor: NSColorWell!
    @IBOutlet var backgroundColor: NSColorWell!
    @IBOutlet var plotColor: NSColorWell!

    //  input controls
    @IBOutlet var soundInputControls: NSView!
    @IBOutlet var soundFileControls: NSView!
    @IBOutlet var fileSpeedCheckbox: NSButton!
    @IBOutlet var inputPad: NSTextField!

    //  output controls
    @IBOutlet var soundOutputControls: NSView!

    //  instrumentation scope
    @IBOutlet var oscilloscope: AnyObject!
    @IBOutlet var specLabel: NSMatrix!

    //  Equalizer
    @objc var equalizer: ModemEqualizer!

    //  states
    @objc var isActiveButton: Bool = false
    @objc var interfaceVisible: Bool = false
    @objc var isTransmit: Bool = false
    @objc var inputSamplingState: Bool = false
    var configOpen: Bool = false
    @objc var sequenceNumber: Int = 0

    //  sound interface
    @objc var modemSource: ModemSource!
    @objc var modemSource2: ModemSource!
    @objc var modemDest: ModemDest!
    @objc var vuMeter: AnyObject!

    //  transmit
    let tempBuffer: UnsafeMutablePointer<Float>   //  [512]
    let bpfBuf: UnsafeMutablePointer<Float>        //  [512]
    @objc var transmitButton: NSButton!
    @objc var timeout: Timer!

    //  tone generator
    @objc var toneMatrix: NSMatrix!
    @objc var toneIndex: Int32 = 0
    var outputScale: Float = 0     //  (non-@objc: see naming notes)

    //  sound file
    @objc var fastFileSpeed: Int32 = 0

    //  AGC
    @objc var agcValue: Float = 0

    override init() {
        tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        bpfBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        tempBuffer.initialize(repeating: 0, count: 512)
        bpfBuf.initialize(repeating: 0, count: 512)
        super.init()
    }

    deinit {
        tempBuffer.deallocate()
        bpfBuf.deallocate()
    }

    @objc func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    @objc func initializeActions() {
        agcValue = 0.4          //  v0.88d

        setInterface(textColor, to: #selector(colorChanged(_:)))
        setInterface(transmitTextColor, to: #selector(colorChanged(_:)))
        setInterface(backgroundColor, to: #selector(colorChanged(_:)))
        setInterface(plotColor, to: #selector(colorChanged(_:)))

        //  send active button changes to activeButtonChanged
        setInterface(activeButton, to: #selector(activeButtonChanged))
        //  send input pad changes to inputPadChanged
        setInterface(inputPad, to: #selector(inputPadChanged))

        //  send file speed changes to fileSpeedChanged
        setInterface(fileSpeedCheckbox, to: #selector(fileSpeedChanged))

        //  send plot style button changes
        setInterface(waveformMatrix, to: #selector(plotStyleChanged))
    }

    //  sets up a modem source with one data channel if ch = (0,1); dual channel if ch = 2
    @objc(setupModemSource:channel:)
    func setupModemSource(_ inputDevice: String!, channel ch: Int32) {
        isActiveButton = false
        interfaceVisible = false
        isTransmit = false
        configOpen = false
        inputSamplingState = false
        sequenceNumber = 0

        let speed: Int32 = (fileSpeedCheckbox != nil && fileSpeedCheckbox.state == .on) ? fastFileSpeed : 1

        equalizer = nil
        modemSource = ModemSource(intoView: soundInputControls, device: inputDevice,
                                  fileExtra: soundFileControls, playbackSpeed: speed,
                                  channel: ch, client: self)

        modemSource.setupSoundCards()                       //  v0.78

        let dataClient = modemObj.dataClient()
        if let dataClient = dataClient { setClient(dataClient) }   //  data is sent to the dataClient (except SDR devices)
        modemSource.delegate = self                         //  soundFileStarting, soundFileStopped (ModemSource folds -setDelegate: into the `delegate` property)

        let inputAttenuator = modemObj.inputAttenuator(self)
        if let inputAttenuator = inputAttenuator {
            //  set up input attenuator
            modemSource.registerLevelSlider(inputAttenuator, isScalar: false)
            inputAttenuator.floatValue = 0.0
        }
        if let inputPad = inputPad {
            modemSource.registerInputPad(inputPad)
            inputPad.floatValue = 0.0
        }
    }

    @objc(setupModemDest:controlView:attenuatorView:)
    func setupModemDest(_ outputDevice: String!, controlView: NSView!, attenuatorView levelView: NSView!) {
        //  set up output sound with this config as the data source of sound channel
        modemDest = ModemDest(intoView: controlView, device: outputDevice, level: levelView,
                              client: self, pttHub: modemObj.managerObject()?.pttHub())

        modemDest.setupSoundCards()        //  v0.78

        if levelView != nil {
            //  set up common level slider (ModemDest folds -outputLevel into the `outputLevel` property)
            if let slider = modemDest.outputLevel {
                modemDest.registerLevelSlider(slider, isScalar: true)
            }
        }
    }

    //  v0.78 clean up modemsource(s) and modemDest
    @objc func applicationTerminating() {
    }

    @objc func modemObject() -> Modem? {
        return modemObj
    }

    @objc func pttObject() -> PTT? {
        if modemDest == nil { return nil }
        return modemDest.ptt          //  ModemDest folds -ptt into the `ptt` property
    }

    @objc func openPanel() {
        window.center()
        window.orderFront(self)
        //  set ourself as delegate of config's window to catch closes
        window.delegate = self

        configOpen = true
        updateInputSamplingState()
        if isTransmit {
            isTransmit = false
            modemDest.stopSampling()
        }
    }

    @objc func closePanel() {
        configOpen = false
        window.orderOut(self)
    }

    @objc func transmitActive() -> Bool {
        return isTransmit
    }

    @objc(setConfigOpen:)
    func setConfigOpen(_ state: Bool) {
        configOpen = state
        updateInputSamplingState()      //  v0.29
    }

    //  override by class instance
    @objc(setOutputScale:)
    override func setOutputScale(_ value: Float) {
    }

    @objc func soundInputActive() -> Bool {
        return isActiveButton
    }

    @objc(setSoundInputActive:)
    func setSoundInputActive(_ state: Bool) {
        activeButton?.state = state ? .on : .off
        checkActive()
    }

    //  check active button
    @objc func updateActiveButtonState() -> Bool {
        //  check active button for state changes
        isActiveButton = (activeButton?.state == .on)
        activeButton?.title = isActiveButton ? NSLocalizedString("Active", comment: "") : NSLocalizedString("Inactive", comment: "")

        return isActiveButton
    }

    @objc func updateInputSamplingState() {
        let oldState = inputSamplingState

        //  turn sampling on if config panel is open or config's interface is selected (v0.27) and is active
        inputSamplingState = ((isActiveButton && interfaceVisible) || configOpen)

        if inputSamplingState != oldState {
            if inputSamplingState {
                modemSource?.startSampling()
            } else {
                modemSource?.stopSampling()
            }
        }
    }

    //  v0.87
    @objc func setKeyerMode() {
        print("ModemConfig: setKeyerMode (should override by subclass")
    }

    //  v0.88d
    //  Received an AGC correction value from CMFSKMixer.
    //  This value should not be called if it is between 0.35 and 0.5.
    //  If the value is lower than 0.35, the input sound card gain should be increased.
    //  If the value is greater than 0.5, the input sound card gain should be reduced.
    @objc(processAGC:)
    func processAGC(_ amplitude: Float) {
        if amplitude > 0.5 || amplitude < 0.3 {
            //  fast AGC
            agcValue = amplitude
        } else {
            //  slow AGC
            agcValue = agcValue * 0.9 + amplitude * 0.1
        }

        if agcValue > 0.50 {
            if agcValue > 0.70 {
                modemSource?.changeDeviceGain(-4)
                return
            }
            modemSource?.changeDeviceGain(-2)
            return
        }
        if agcValue < 0.35 {
            if agcValue < 0.2 {
                modemSource?.changeDeviceGain(2)
                return
            }
            modemSource?.changeDeviceGain(1)
        }
    }

    @objc(updateVisibleState:)
    func updateVisibleState(_ state: Bool) {
        interfaceVisible = state
        //  now check if we need to turn on/off actual sampling
        updateInputSamplingState()
    }

    @objc func inputSource() -> ModemSource? {
        return modemSource
    }

    @objc func updateFileSpeed() {
        let speed: Int32 = (fileSpeedCheckbox?.state == .on) ? fastFileSpeed : 1
        modemSource?.fileSpeedChanged(speed)
    }

    //  AudioOutputPort callback - override by subclasses
    @objc(needData:samples:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples n: Int32) -> Int32 {
        return 0
    }

    //  Plist
    //  set preferences to an NSColor (version 1)
    @objc(setColorRed:green:blue:fromColor:into:)
    func setColorRed(_ rTag: String, green gTag: String, blue bTag: String, fromColor color: NSColor, into pref: Preferences) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        pref.setFloat(Float(red), forKey: rTag)
        pref.setFloat(Float(green), forKey: gTag)
        pref.setFloat(Float(blue), forKey: bTag)
    }

    //  set preferences to an NSColor (version 2)
    @objc(set:fromColor:into:)
    func set(_ tag: String, fromColor color: NSColor, into pref: Preferences) {
        pref.setColor(color, forKey: tag)
    }

    @objc(set:fromRed:green:blue:into:)
    func set(_ tag: String, fromRed red: Float, green: Float, blue: Float, into pref: Preferences) {
        pref.setRed(red, green: green, blue: blue, forKey: tag)
    }

    //  get an NSColor for preferences (version 1)
    @objc(getColorRed:green:blue:from:)
    func getColorRed(_ rTag: String, green gTag: String, blue bTag: String, from pref: Preferences) -> NSColor {
        let red = pref.floatValue(forKey: rTag)
        let green = pref.floatValue(forKey: gTag)
        let blue = pref.floatValue(forKey: bTag)
        return NSColor(calibratedRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }

    //  get an NSColor for preferences (version 2)
    @objc(getColor:from:)
    func getColor(_ tag: String, from pref: Preferences) -> NSColor? {
        return pref.colorValue(forKey: tag)
    }

    @objc(inputAttenuatorChanged:)
    func inputAttenuatorChanged(_ inputAttenuator: NSSlider!) {
        modemSource?.setDeviceLevel(inputAttenuator)
    }

    //  this is called from Application.m after the plist has been updated
    //  and whenever an "active" button for some mode is pressed or changed by AppleScript
    @objc func checkActive() {
        _ = updateActiveButtonState()
        modemSource?.enableInput(true)
        modemDest?.enableOutput(true)
        updateInputSamplingState()
        modemObj.activeChanged(self)
    }

    //  override by subclasses of ModemConfig
    @objc(updateColorsFromPreferences:)
    func updateColorsFromPreferences(_ pref: Preferences!) {
    }

    //  override by subclasses of ModemConfig
    @objc(retrieveActualColorPreferences:)
    func retrieveActualColorPreferences(_ pref: Preferences!) {
    }

    //  ---- actions ---------
    @objc func activeButtonChanged() {
        checkActive()
    }

    @objc func colorChanged(_ sender: Any?) {
    }

    @objc func plotStyleChanged() {
        let which = waveformMatrix.selectedRow
        waveformMatrix.deselectAllCells()
        waveformMatrix.selectCell(atRow: which, column: 0)

        //  hide spectrum label if waveform style
        for i in 0..<5 {
            if let text = specLabel?.cell(atRow: 0, column: i) {
                text.stringValue = (which == 0) ? ModemConfig.freqLabel[i] : ""
            }
        }
        (oscilloscope as? Oscilloscope)?.setDisplayStyle(Int32(which), plotColor: plotColor?.color)
    }

    private static let freqLabel = ["500", "1000", "1500", "2000", "2500"]

    @objc func inputPadChanged() {
        modemSource?.setPadLevel(inputPad)
        modemSource?.setDeviceLevel(modemObj.inputAttenuator(self))
    }

    @objc func fileSpeedChanged() {
        updateFileSpeed()
    }

    //  delegate to ModemSource
    @objc(soundFileStarting:)
    func soundFileStarting(_ filename: String!) {
    }

    //  delegate of config window
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        setConfigOpen(false)
        return true
    }

    //  v0.73 direct file open (shift-Cms-F)
    @objc func directOpenSoundFile() {
        modemSource?.openFile(self)
    }
}
