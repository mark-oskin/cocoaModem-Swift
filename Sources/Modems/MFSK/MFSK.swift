//
//  MFSK.m
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/15/06.
//  Swift port of MFSK.m / MFSK.h.
//
//  MFSK : ContestInterface.  The MFSK16 + DominoEX mode tab.  Instantiated by
//  StdManager via -initIntoTabView:manager:, loading the "MFSK" nib.
//
//  Port notes:
//   * Every original ivar is an internal (mostly @objc) stored property with its
//     EXACT name.  Inherited ivars/methods (config, manager, receiveView,
//     transmitView, macroSheet, currentSheet, check, contestTab, ...) are reached
//     by their exact names across the Swift module.
//   * IBOutlet id -> AnyObject! (message sends via optional chaining / casts),
//     except outlets whose collaborators are Swift and require concrete typing:
//     waterfall (Waterfall!), dominoReceiveBox (ScrollingField!),
//     dominoReceiveView (AYTextView!), and vuMeter (unified with its -vuMeter
//     getter into a VUMeter! property).
//   * The `inputAttenuator` outlet is renamed inputAttenuatorOutlet (@objc keeps
//     the nib key) so it does not collide with -inputAttenuator:.
//   * receiver/demodulator ivars are unified with their same-named getters.
//   * ObjC Boolean parameters on still-Objective-C collaborators (MFSKReceiver
//     and the DominoEX receivers, MFSKConfig -turnOnTransmission:...) arrive as
//     DarwinBoolean and are wrapped.
//   * receiveTextAttribute/transmitTextAttribute are UnsafeMutablePointer
//     <TextAttribute>? (base Modem type); unwrapped before use with AYTextView.
//   * MRC dealloc/retain/release dropped (ARC).  The NOISETEST DSP test harness
//     is kept under #if NOISETEST (excluded from normal builds).
//

import Cocoa

//  --- Plist keys (defined in Plist.h, which is not in the bridging header) ---
private let kMFSKFont           = "MFSK Font"
private let kMFSKFontSize        = "MFSK Font Size"
private let kMFSKTxFont          = "MFSK Tx Font"
private let kMFSKTxFontSize      = "MFSK Tx Font Size"
private let kMFSKSquelch         = "MFSK Squelch"
private let kMFSKTrellisDepth    = "MFSK Trellis Depth"
private let kMFSKWaterfallNR     = "MFSK Waterfall Noise Reduction"
private let kMFSKSelection       = "MFSK Selection"
private let kDominoFont          = "Domino Font"
private let kDominoFontSize      = "Domino Font Size"
private let kDominoSmoothScroll  = "Domino Smooth Scroll"
private let kDominoEchoBeacon    = "Domino Echo Beacon"
private let kDominoRcvrEnable    = "Domino Beacon Receive Enable"
private let kDominoSendEnable    = "Domino Beacon Send Enable"
private let kDominoBeacon        = "Domino Beacon Message"
private let kSlashZeros          = "Null for Zero"

//  MFSK mode-menu tags (mirror of MFSKModes.h; typed Int32 to keep switch/compare
//  unambiguous).
private let kMFSK16Mode: Int32     = 0
private let kDominoEX4Mode: Int32  = 4
private let kDominoEX5Mode: Int32  = 5
private let kDominoEX8Mode: Int32  = 8
private let kDominoEX11Mode: Int32 = 11
private let kDominoEX16Mode: Int32 = 16
private let kDominoEX22Mode: Int32 = 22

//  CNR thresholds for squelch (was a static float[] in MFSK.m).
private let kMFSKSquelchThreshold: [Float] = [ 24.0, 12.0, 6.0, 3.0, 1.5, 0.0001 ]

//  'mf16' four-char AppleScript modulation code.
private let kMF16Code: Int32 = 0x6d663136

//  Phi (slashed zero) = 0xd8 in cocoaModemParams.h.
private let kPhi: Int32 = 0xd8

//  Informal @objc surface for the transmit "light" (an id outlet whose class
//  responds to -setBackgroundColor:).  Mirrors the pattern shipped in SynchAM.
@objc private protocol MFSKLightInformal {
    @objc func setBackgroundColor(_ color: NSColor?)
}

@objc(MFSK)
class MFSK: ContestInterface, NSTextViewDelegate {

    //  --- IBOutlets (id in MFSK.h) ---
    @objc var waterfall: Waterfall!
    @objc var transmitButton: AnyObject!
    @objc var transmitLight: AnyObject!

    //  outlet is named "inputAttenuator"; -inputAttenuator: has the same base
    //  name, so the property is renamed and given the exact nib key via @objc.
    @objc(inputAttenuator) var inputAttenuatorOutlet: AnyObject!
    @objc var vuMeter: VUMeter!                 //  unified with -vuMeter getter

    @objc var mfskIndicator: AnyObject!
    @objc var mfskIndicatorLabel: AnyObject!

    @objc var mfskAFCBox: AnyObject!
    @objc var mfskLatencyBox: AnyObject!

    @objc var mfskModeMenu: AnyObject!
    @objc var exchangeTabView: AnyObject!

    @objc var dominoFECMenu: AnyObject!
    @objc var dominoReceiveView: AYTextView!
    @objc var dominoReceiveBox: ScrollingField!
    @objc var dominoReceiveTextField: AnyObject!
    @objc var dominoReceiveCheckbox: AnyObject!
    @objc var dominoSendCheckbox: AnyObject!
    @objc var dominoSendField: AnyObject!
    @objc var dominoSmoothScrollCheckbox: AnyObject!
    @objc var dominoBeaconEchoCheckbox: AnyObject!

    @objc var softDecodeCheckbox: AnyObject!
    @objc var afcTabView: AnyObject!
    @objc var afcSlider: AnyObject!
    @objc var latencySlider: AnyObject!
    @objc var txTrackSlider: AnyObject!
    @objc var squelchSlider: AnyObject!

    @objc var rxFreqField: AnyObject!
    @objc var txFreqField: AnyObject!
    @objc var txTransferButton: AnyObject!

    @objc var thread: Thread!

    @objc var mfskMode: Int32 = 0               //  0 = MFSK16, 16 = DominoEX16, etc

    //  receiver ivar unified with -receiver getter
    @objc var receiver: MFSKReceiver!
    @objc var mfsk16Receiver: MFSKReceiver!
    @objc var domino5Receiver: MFSKReceiver!
    @objc var domino11Receiver: MFSKReceiver!
    @objc var domino22Receiver: MFSKReceiver!
    @objc var domino4Receiver: MFSKReceiver!
    @objc var domino8Receiver: MFSKReceiver!
    @objc var domino16Receiver: MFSKReceiver!

    @objc var modulator: MFSKModulator!
    @objc var mfsk16Modulator: MFSKModulator!
    //  declared MFSKModulator* in MFSK.h but always holds a DominoModulator;
    //  typed concretely so -setBeacon:/-setBinWidth:baudRatio: are reachable.
    @objc var dominoModulator: DominoModulator!

    //  demodulator ivar unified with -demodulator getter
    @objc var demodulator: MFSKDemodulator!
    @objc var enabled: Bool = false
    @objc var active: Bool = false

    //  waterfall
    @objc var displayedRxFrequency: Float = 0
    @objc var displayedTxFrequency: Float = 0

    //  demodulator
    @objc var vfoOffset: Float = 0
    @objc var sideband: Int32 = 0
    @objc var displayedFrequency: Float = 0
    @objc var clickedFrequency: Float = 0
    @objc var frequencyDefined: Bool = false

    //  Prefs
    @objc var sidebandState: Bool = false
    //  transmit
    @objc var transmitViewLock: NSLock!
    @objc var transmitBufferCheck: Timer!
    @objc var indexOfUntransmittedText: Int32 = 0
    @objc var echoBeacon: Bool = false

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    @objc(initIntoTabView:manager:)
    init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr.showSplash("Creating MFSK16 and DominoEX Modems")

        super.init(into: tabview, nib: "MFSK", manager: mgr)

        manager = mgr
        transceivers = 1
        enabled = false
        displayedFrequency = 0.0
        clickedFrequency = 0.0
        displayedRxFrequency = -1
        displayedTxFrequency = -1

        receiver = nil
        mfsk16Receiver = MFSK16Receiver()
        domino4Receiver = DominoHalfRateReceiver(asMode: kDominoEX4Mode)
        domino8Receiver = DominoHalfRateReceiver(asMode: kDominoEX8Mode)
        domino16Receiver = DominoReceiver(asMode: kDominoEX16Mode)
        domino5Receiver = DominoHalfRateReceiver(asMode: kDominoEX5Mode)
        domino11Receiver = DominoReceiver(asMode: kDominoEX11Mode)
        domino22Receiver = DominoReceiver(asMode: kDominoEX22Mode)

        modulator = nil
        mfsk16Modulator = MFSK16Modulator()
        mfsk16Modulator?.setModemClient(self)
        dominoModulator = DominoModulator()
        dominoModulator?.setModemClient(self)

        (mfskModeMenu as? NSPopUpButton)?.selectItem(withTag: Int(kDominoEX11Mode))
        //  [ self setMFSKMode ] deferred to awakeFromNib (v0.75)
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("MFSK", comment: "")

        (config as? MFSKConfig)?.awakeFromModem(self)
        ptt = (config as? MFSKConfig)?.pttObject()

        awakeFromContest()
        initCallsign()
        initColors()
        initMacros()
        sidebandState = false
        sideband = 1                            //  default to USB

        //  use QSO transmitview
        (contestTab as? NSTabView)?.selectTabViewItem(at: 0)

        waterfall?.awakeFromModem()
        waterfall?.enableIndicator(self)
        waterfall?.setScrollWheelRate(0.5)

        //  0.75 moved here
        setMFSKMode()

        //  prefs
        charactersSinceTimerStarted = 0
        timeout = nil
        transmitBufferCheck = nil
        thread = Thread.current
        frequencyDefined = false

        //  transmit view
        indexOfUntransmittedText = 0
        transmitState = false
        sentColor = false
        transmitCount = 0
        transmitCountLock = NSLock()
        transmitViewLock = NSLock()
        transmitTextAttribute = transmitView?.newAttribute()
        transmitView?.delegate = self
        //  receive view
        receiveTextAttribute = receiveView?.newAttribute()
        receiveView?.delegate = self            //  delegate for callsign clicks
        transmitView?.delegate = self           //  capture backspace

        //  DominoEX secondary text
        if let field = dominoReceiveTextField as? NSTextField {
            dominoReceiveBox?.setTextField(field)
        }
        (dominoSmoothScrollCheckbox as? NSControl)?.action = Selector(("setSmoothState:"))
        (dominoSmoothScrollCheckbox as? NSControl)?.target = dominoReceiveBox

        vuMeter?.setup()

        setInterface(transmitButton as? NSControl, to: #selector(transmitButtonChanged))
        setInterface(inputAttenuatorOutlet as? NSControl, to: #selector(inputAttenuatorChanged))
        setInterface(softDecodeCheckbox as? NSControl, to: #selector(softDecodeChanged))
        setInterface(afcSlider as? NSControl, to: #selector(afcSliderChanged(_:)))
        setInterface(txTrackSlider as? NSControl, to: #selector(afcSliderChanged(_:)))
        setInterface(latencySlider as? NSControl, to: #selector(latencySliderChanged))
        setInterface(squelchSlider as? NSControl, to: #selector(squelchSliderChanged))
        setInterface(txTransferButton as? NSControl, to: #selector(setTxFrequencyFromRxFrequency))
        setInterface(mfskModeMenu as? NSControl, to: #selector(setMFSKMode))               // v0.73
        setInterface(dominoFECMenu as? NSControl, to: #selector(setFEC))                   // v0.73
        setInterface(dominoSmoothScrollCheckbox as? NSControl, to: #selector(setDominoReceiveBeaconState)) // v0.73
        setInterface(dominoBeaconEchoCheckbox as? NSControl, to: #selector(setDominoReceiveBeaconState))   // v0.73

        setInterface(dominoSendCheckbox as? NSControl, to: #selector(dominoTransmitBeaconChanged))         // v0.73
        setInterface(dominoSendField as? NSControl, to: #selector(dominoTransmitBeaconChanged))            // v0.73

        setInterface(rxFreqField as? NSControl, to: #selector(rxFieldChanged))
    }

    //  =======================================================================

    //  v0.87
    @objc(switchModemIn)
    override func switchModemIn() {
        if config != nil { (config as? MFSKConfig)?.setKeyerMode() }
    }

    @objc func setFEC() {
        let fecMode = Int32((dominoFECMenu as? NSPopUpButton)?.selectedItem?.tag ?? 0)
        let useFEC = (fecMode >= 4)

        demodulator?.setUseFEC(DarwinBoolean(useFEC))
        dominoModulator?.setUseFEC(useFEC)
        if useFEC {
            demodulator?.setInterleaverStages(fecMode)
            dominoModulator?.setInterleaverStages(fecMode)
        }
    }

    //  Set MFSK mode to tag of the mode popup menu's selected item.
    @objc func setMFSKMode() {
        let oldReceiver = receiver
        mfskMode = Int32(((mfskModeMenu as? NSPopUpButton)?.selectedItem?.tag ?? 0) % 32)
        dominoReceiveBox?.setMFSKMode(mfskMode)     //  change smooth scrolling rate

        var bins: Int32 = 18
        var interface: Int32 = 1
        var spread: Float = 0
        var binWidth: Float = 0
        var baudRatio: Int32 = 0
        let newReceiver: MFSKReceiver?

        switch mfskMode {
        case kDominoEX4Mode:
            newReceiver = domino4Receiver; modulator = dominoModulator; binWidth = 7.8125; baudRatio = 2
        case kDominoEX5Mode:
            newReceiver = domino5Receiver; modulator = dominoModulator; binWidth = 10.7666; baudRatio = 2
        case kDominoEX8Mode:
            newReceiver = domino8Receiver; modulator = dominoModulator; binWidth = 15.625; baudRatio = 2
        case kDominoEX11Mode:
            newReceiver = domino11Receiver; modulator = dominoModulator; binWidth = 10.7666; baudRatio = 1
        case kDominoEX16Mode:
            newReceiver = domino16Receiver; modulator = dominoModulator; binWidth = 15.625; baudRatio = 1
        case kDominoEX22Mode:
            newReceiver = domino22Receiver; modulator = dominoModulator; binWidth = 10.766*2; baudRatio = 1
        default:    //  MFSK16
            newReceiver = mfsk16Receiver; modulator = mfsk16Modulator; bins = 16; interface = 0; spread = 16*15.625
        }

        if modulator === dominoModulator {
            spread = 18*binWidth
            (modulator as? DominoModulator)?.setBinWidth(binWidth, baudRatio: baudRatio)
        }

        //  select between MFSK16 and DominoEX (secondary messages, etc) GUI
        (exchangeTabView as? NSTabView)?.selectTabViewItem(at: Int(interface))

        //  set up indicators
        (mfskIndicatorLabel as? MFSKIndicatorLabel)?.setBins(bins)
        waterfall?.setSpread(spread)

        if newReceiver !== oldReceiver {
            let wasActive = active
            if receiver != nil {
                turnOffReceiver(0, option: false)
                enableModem(false)
            }
            //  clear DominoEX receive beacon if mode changed
            if oldReceiver != nil { dominoReceiveBox?.clear() }
            //  finally, perform the switch
            receiver = newReceiver

            enableModem(wasActive)
            demodulator = receiver?.demodulator
            demodulator?.updateRxFreqLabelAndField(0)
            demodulator?.setFreqIndicator(mfskIndicator as? MFSKIndicator, label: mfskIndicatorLabel as? MFSKIndicatorLabel)
            if modulator === dominoModulator { setFEC() }
            demodulator?.setModem(self)
        }
        //  select AFC/Tx Track tab view and set modem
        if interface == 0 {
            (afcTabView as? NSTabView)?.selectFirstTabViewItem(self)
            demodulator?.setAFCState((afcSlider as? NSSlider)?.intValue ?? 0)
        } else {
            (afcTabView as? NSTabView)?.selectLastTabViewItem(self)
            demodulator?.setAFCState((txTrackSlider as? NSSlider)?.intValue ?? 0)
        }
    }

    //  v0.73
    @objc func setDominoReceiveBeaconState() {
        if let checkbox = dominoSmoothScrollCheckbox as? NSButton {
            dominoReceiveBox?.setSmoothState(checkbox)
        }
        echoBeacon = (((dominoBeaconEchoCheckbox as? NSButton)?.state ?? .off) != .off)
    }

    //  v0.73
    @objc func dominoTransmitBeaconChanged() {
        let string = (dominoSendField as? NSTextField)?.stringValue ?? ""

        if ((dominoSendCheckbox as? NSButton)?.state ?? .off) == .off || string.isEmpty {
            "".withCString { dominoModulator?.setBeacon($0) }
            return
        }
        if let cstr = (string as NSString).cString(using: String.Encoding.isoLatin1.rawValue) {
            dominoModulator?.setBeacon(cstr)
        }
    }

    //  define ourself as the recipient of audio data
    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        //  mirror the Objective-C cast (CMPipe*)self
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    @objc override func initMacros() {
        currentSheet = 0
        check = 0
        let application = manager?.appObject()
        for i in 0..<3 {
            let sheet = MFSKMacros(sheet: ())
            setMacroSheet(sheet, index: Int32(i))
            sheet.setUserInfo(application?.userInfoObject(),
                              qso: (manager as? StdManager)?.qsoObject(),
                              modem: self, canImport: true)
        }
    }

    //  overide base class to change AudioPipe pipeline (assume source is normalized)
    override func updateSourceFromConfigInfo() {
        //  send data to distribution box for concurrent display on waterfall
        (config as? CMPipe)?.setClient(self)
        (config as? MFSKConfig)?.checkActive()
    }

    //  process the new data buffer
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        #if NOISETEST
        //  for test file, carrier power = .03 ; Eb/No = ( 22.26 - 15 ) = 7.26 dB
        //  for sd = 1.0.  hard decoder copied to ~6.4 dB, soft decoder to ~5.4 dB.
        if let stream = pipe?.stream() {
            let array = stream.array
            let ebNo: Float = 6.0
            let sigma = powf(1.12203, 7.26 - ebNo)      //  sigma = 2 for 1.2203^6.02
            for i in 0..<512 { array[i] = (array[i] + gaussianNoise(sigma)) * 0.2 }
        }
        #endif

        if receiver != nil && enabled { receiver?.importData(pipe) }
        //  send data to other data clients
        if waterfall != nil { waterfall?.importData(pipe) }
        if vuMeter != nil { vuMeter?.importData(pipe) }
    }

    @objc(setOutputScale:)
    func setOutputScale(_ value: Float) {
        modulator?.setOutputScale(value)
    }

    @objc(audioToneFromFreqReadout:)
    func audioToneFromFreqReadout(_ freq: Float) -> Float {
        return (sideband != 0) ? (freq + vfoOffset) : (vfoOffset - freq)
    }

    @objc(freqReadoutFromAudioTone:)
    func freqReadoutFromAudioTone(_ tone: Float) -> Float {
        return (sideband != 0) ? (tone - vfoOffset) : (vfoOffset - tone)
    }

    //  v0.73
    @objc func rxFieldChanged() {
        let freq = audioToneFromFreqReadout((rxFreqField as? NSTextField)?.floatValue ?? 0)

        enabled = true
        clickedFrequency = freq
        setRxFrequency(freq)
        receiver?.selectFrequency(freq, fromWaterfall: false)
        receiver?.clicked(0.0)
    }

    //  v0.73  Modulator gets its transmit tone from here
    @objc func transmitFrequency() -> Float {
        return audioToneFromFreqReadout((txFreqField as? NSTextField)?.floatValue ?? 0)
    }

    //  v0.73  receive physical audio tone
    @objc func receiveFrequency() -> Float {
        return audioToneFromFreqReadout((rxFreqField as? NSTextField)?.floatValue ?? 0)
    }

    //  v0.73
    @objc(setRxFrequency:)
    func setRxFrequency(_ audioTone: Float) {
        displayedFrequency = audioTone
        waterfall?.forceToneTo(audioTone, receiver: 0)
        if audioTone < 10 {
            (rxFreqField as? NSTextField)?.stringValue = ""
            return
        }
        let readout = freqReadoutFromAudioTone(audioTone)

        if readout != displayedRxFrequency {
            displayedRxFrequency = readout
            let freqString = String(format: "%.1f", readout)
            (rxFreqField as? NSTextField)?.stringValue = freqString
            //  if AFC turned on, set the tx frequency field also
            let slider: AnyObject? = (mfskMode == 0) ? afcSlider : txTrackSlider
            if ((slider as? NSSlider)?.intValue ?? 0) == 1 {
                (txFreqField as? NSTextField)?.stringValue = freqString
            }
        }
    }

    @objc(setTxFrequency:)
    func setTxFrequency(_ audioTone: Float) {
        if audioTone < 10 {
            (txFreqField as? NSTextField)?.stringValue = ""
            return
        }

        let readout = freqReadoutFromAudioTone(audioTone)

        if readout != displayedTxFrequency {
            displayedTxFrequency = readout
            let freqString = String(format: "%.1f", readout)
            (txFreqField as? NSTextField)?.stringValue = freqString
        }
    }

    //  called from MFSK16 demodulator when locked
    @objc(applyRxFreqOffset:)
    func applyRxFreqOffset(_ offset: Float) {
        //  v0.33 apply opposite correction if sideband is LSB (0)
        let freq = clickedFrequency + offset * ((sideband == 0) ? -1 : 1)
        if abs(displayedFrequency - freq) < 0.1 { return }
        setRxFrequency(freq)
    }

    @objc(turnOffReceiver:option:)
    override func turnOffReceiver(_ channel: Int32, option: Bool) {
        if transmitState == true {
            //  make sure transmitter is off first!
            changeTransmitStateTo(false)
            usleep(100000)
        }
        enabled = false
        setRxFrequency(0)
        setTxFrequency(0)
        if mfskIndicator != nil { (mfskIndicator as? MFSKIndicator)?.clear() }
        if mfskIndicatorLabel != nil { (mfskIndicatorLabel as? MFSKIndicatorLabel)?.clear() }
    }

    @objc func setTxFrequencyFromRxFrequency() {
        setTxFrequency(receiveFrequency())
    }

    @objc(checkIfCanTransmit)
    override func checkIfCanTransmit() -> Bool {
        return transmitFrequency() > 100
    }

    @objc func flushOutput() {
        transmitCountLock?.lock()
        transmitCount = 0
        transmitCountLock?.unlock()
        //  now flush whatever is in the modulator pipeline
        modulator?.flushOutput()
    }

    //  this overrides the method in Modem.m
    override func flushAndLeaveTransmit() {
        flushOutput()
        enterTransmitMode(false)
    }

    //  Actual tone frequency (independent of USB/LSB/offset)
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    override func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID index: Int32) {
        if (config as? MFSKConfig)?.soundInputActive() != true {
            //  check if A/D is active
            waterfall?.clearMarkers()
            _ = Messages.alert(withMessageText: NSLocalizedString("Sound Card not active", comment: ""),
                               informativeText: NSLocalizedString("Select Sound Card", comment: ""))
            return
        }
        enabled = true
        setRxFrequency(freq)
        clickedFrequency = freq
        if acquire { setTxFrequency(freq) }
        receiver?.selectFrequency(freq, fromWaterfall: acquire)
        receiver?.clicked(secs)
    }

    //  v0.73
    @objc(setTextColor:sentColor:backgroundColor:plotColor:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!) {
        textColor = inTextColor
        sentTextColor = sentTColor
        backgroundColor = bgColor
        plotColor = pColor

        receiveView?.backgroundColor = backgroundColor
        transmitView?.backgroundColor = backgroundColor
        dominoReceiveView?.backgroundColor = backgroundColor
        if let bg = backgroundColor { dominoReceiveBox?.setBackgroundColor(bg) }
        (dominoSendField as? NSTextField)?.backgroundColor = backgroundColor

        if let attr = receiveTextAttribute { receiveView?.setTextColor(textColor, attribute: attr) }
        if let attr = transmitTextAttribute { transmitView?.setViewTextColor(textColor, attribute: attr) }
        if let attr = receiveTextAttribute { dominoReceiveView?.setTextColor(textColor, attribute: attr) }
        if let tc = textColor { dominoReceiveBox?.setTextColor(tc) }
        (dominoSendField as? NSTextField)?.textColor = textColor
    }

    @objc(displayCharacter:)
    func displayCharacter(_ c: Int32) {
        //  send character to MFSK16 receiveView
        append(c, to: receiveView)
        manager?.appObject()?.addToVoice(c, channel: 1)     //  0.96d
        //  applescript
        transceiver1?.receiver()?.insertBuffer(c)
    }

    //  v0.73  DominoEX primary output
    @objc(displayPrimary:)
    func displayPrimary(_ c: Int32) {
        //  send character to Domino tab's exchangeView
        append(c, to: dominoReceiveView)
        manager?.appObject()?.addToVoice(c, channel: 1)     //  0.96d
        //  applescript
        transceiver1?.receiver()?.insertBuffer(c)
    }

    //  v0.73  if negative, clear the box
    @objc(displaySecondary:)
    func displaySecondary(_ c: Int32) {
        if c < 0 {
            dominoReceiveBox?.clear()
        } else {
            dominoReceiveBox?.appendCharacter(c, draw: ((dominoReceiveCheckbox as? NSButton)?.state ?? .off) == .on)
        }
    }

    //  sideband state (set from PSKConfig's LSB/USB button).  NO = LSB
    @objc(selectAlternateSideband:)
    func selectAlternateSideband(_ state: Bool) {
        let sb: Int32 = state ? 1 : 0
        waterfall?.setSideband(sb)
        let ds = state
        receiver?.setSidebandState(ds)
        domino4Receiver?.setSidebandState(ds)
        domino5Receiver?.setSidebandState(ds)
        domino8Receiver?.setSidebandState(ds)
        domino11Receiver?.setSidebandState(ds)
        domino16Receiver?.setSidebandState(ds)
        domino22Receiver?.setSidebandState(ds)
        modulator?.setSidebandState(state)
        dominoModulator?.setSidebandState(state)
    }

    @objc(setWaterfallOffset:sideband:)
    func setWaterfallOffset(_ freq: Float, sideband polarity: Int32) {
        let offset = abs(freq)

        vfoOffset = offset
        sideband = polarity

        waterfall?.setOffset(freq, sideband: sideband)
    }

    //  this gets periodically called to check for inactivity
    @objc func timedOut(_ timer: Timer?) {
        if charactersSinceTimerStarted == 0 {
            //  timed out!
            changeTransmitStateTo(false)
        }
        charactersSinceTimerStarted = 0
    }

    private func sendTextStorage() {
        transmitViewLock?.lock()
        if let storage = transmitView?.textStorage {
            let total = storage.length
            if Int(indexOfUntransmittedText) < total {
                let string = storage.string as NSString
                while Int(indexOfUntransmittedText) < total {
                    let uch = string.character(at: Int(indexOfUntransmittedText))
                    indexOfUntransmittedText += 1
                    modulator?.appendASCII(Int32(uch))
                    charactersSinceTimerStarted += 1
                }
            }
        }
        transmitViewLock?.unlock()
    }

    //  this gets periodically called to check transmit buffer activity
    @objc func checkTransmitBuffer(_ timer: Timer?) {
        sendTextStorage()
    }

    //  allow receive data to flush through the pipeline before changing text color
    //  and sending transmit buffer
    @objc func delayTransmit(_ timer: Timer?) {
        transmitView?.select()
        //  send any test that has been buffered up
        sendTextStorage()
    }

    //  execute string
    @objc(executeMacroString:)
    override func executeMacroString(_ macro: String!) {
        if let macro = macro { transmitView?.insertAtEnd(macro) }

        if transmitCount > 0 {
            //  keep transmit on if needed
            if transmitState == false { changeTransmitStateTo(true) }
        }
    }

    //  for %[tx] and %[rx] macros
    override func sendMessageImmediately() {
        transmitCountLock?.lock()
        transmitCount += 1
        transmitCountLock?.unlock()
    }

    //  state = 0 : gray, 1 : red, 2 : yellow
    @objc(changeTransmitLight:)
    func changeTransmitLight(_ state: Int32) {
        let indicatorColor: NSColor
        switch state {
        case 1:
            indicatorColor = .red
        case 2:
            indicatorColor = .yellow
        default:
            indicatorColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
        }
        transmitLight?.setBackgroundColor?(indicatorColor)
    }

    @objc(changeTransmitStateTo:)
    override func changeTransmitStateTo(_ state: Bool) {
        let result = (config as? MFSKConfig)?.turnOnTransmission(state,
                                                                 button: transmitButton as? NSButton,
                                                                 modulator: modulator)
        transmitState = result ?? false

        if transmitState == true {
            executePTT(true)
            changeTransmitLight(1)
            transmitView?.window?.makeFirstResponder(transmitView)
            if timeout != nil { timeout.invalidate() }
            charactersSinceTimerStarted = 0
            //  prepare modulator
            modulator?.resetModulator()
            if manager?.useWatchdog() == true {
                timeout = Timer.scheduledTimer(timeInterval: 150, target: self, selector: #selector(timedOut(_:)), userInfo: self, repeats: true)
            }
            transmitBufferCheck = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(checkTransmitBuffer(_:)), userInfo: self, repeats: true)
            //  set text color in receive view and turn on transmit
            _ = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(delayTransmit(_:)), userInfo: self, repeats: false)
        } else {
            executePTT(false)
            changeTransmitLight(0)
            if timeout != nil { timeout.invalidate() }
            timeout = nil
            if transmitBufferCheck != nil { transmitBufferCheck.invalidate() }
            transmitBufferCheck = nil
            transmitCountLock?.lock()
            transmitCount = 0
            transmitCountLock?.unlock()
            setSentColor(false, view: receiveView as? ExchangeView, textAttribute: receiveTextAttribute)
            transmitView?.select()
        }
    }

    //  (Private API)
    @objc(transmittedCharacter:channel:)
    func transmittedCharacter(_ c: Int32, channel: Int32) {
        var c = c
        if c <= 26 {
            //  control character in stream
            switch c + Int32(UInt8(ascii: "a")) - 1 {
            case Int32(UInt8(ascii: "z")):
                //  end of macro transmitCount balance
                transmitCountLock?.lock()
                if transmitCount > 0 { transmitCount -= 1 }
                transmitCountLock?.unlock()
                return
            default:
                //  for carriage return, newline, etc
                break
            }
        } else {
            setSentColor(true, view: receiveView as? ExchangeView, textAttribute: receiveTextAttribute)
            if c == Int32(UInt8(ascii: "0")) && slashZero { c = kPhi }
        }
        //  send character
        switch channel {
        case 1:
            append(c, to: dominoReceiveView)
        default:
            append(c, to: receiveView)
        }
        manager?.appObject()?.addToVoice(c, channel: 0)     //  0.96d
        //  applescript
        transceiver1?.transmitter()?.insertBuffer(c)
        transmitView?.select()
    }

    //  Echo to MFSK16 ReceiveView
    @objc(transmittedCharacter:)
    override func transmittedCharacter(_ ch: Int32) {
        transmittedCharacter(ch, channel: 0)
    }

    //  Echo to DominoEX ReceiveView
    @objc(transmittedPrimaryCharacter:)
    func transmittedPrimaryCharacter(_ c: Int32) {
        transmittedCharacter(c, channel: 1)
    }

    //  Echo to DominoEX beacon
    @objc(transmittedSecondaryCharacter:)
    func transmittedSecondaryCharacter(_ c: Int32) {
        if echoBeacon { displaySecondary(c) }
    }

    //  called from local object or from StdManager (main menu)
    @objc(enterTransmitMode:)
    override func enterTransmitMode(_ state: Bool) {
        if state {
            if (config as? MFSKConfig)?.soundInputActive() != true {
                //  check if A/D is active
                (transmitButton as? NSButton)?.state = .off
                _ = Messages.alert(withMessageText: NSLocalizedString("Sound Card not active", comment: ""),
                                   informativeText: NSLocalizedString("Select Sound Card", comment: ""))
                return
            }
            if transmitFrequency() < 10.0 {
                //  check if frequency has been selected in waterfall
                (transmitButton as? NSButton)?.state = .off
                _ = Messages.alert(withMessageText: NSLocalizedString("Frequency not selected", comment: ""),
                                   informativeText: NSLocalizedString("Frequency not set", comment: ""))
                return
            }
        }
        if state != transmitState {
            if state == true {
                //  immediately change state to transmit
                changeTransmitStateTo(state)
            } else {
                //  enter a %[rx] character into the stream
                transmitView?.insertInTextStorage(String(format: "%c", 5 /*^E*/))
            }
        }
    }

    //  Application sends this through the ModemManager when quitting
    override func applicationTerminating() {
        ptt?.applicationTerminating()               //  v0.89
    }

    @objc func transmitButtonChanged() {
        let state = ((transmitButton as? NSButton)?.state == .on)
        enterTransmitMode(state)
    }

    @objc func inputAttenuatorChanged() {
        (config as? MFSKConfig)?.inputSource()?.setDeviceLevel(inputAttenuatorOutlet as? NSSlider)
    }

    //  v0.33
    @objc(inputAttenuator:)
    override func inputAttenuator(_ config: ModemConfig!) -> NSSlider! {
        return inputAttenuatorOutlet as? NSSlider
    }

    @objc func softDecodeChanged() {
        demodulator?.setSoftDecodeState(DarwinBoolean((softDecodeCheckbox as? NSButton)?.state == .on))
    }

    @objc func afcSliderChanged(_ sender: Any?) {
        demodulator?.setAFCState((sender as? NSControl)?.intValue ?? 0)
    }

    @objc func latencySliderChanged() {
        demodulator?.setTrellisDepth((latencySlider as? NSSlider)?.intValue ?? 0)
    }

    @objc func squelchSliderChanged() {
        var index = (squelchSlider as? NSSlider)?.intValue ?? 0
        if index <= 0 { index = 0 } else if index > 5 { index = 5 }
        demodulator?.setSquelchThreshold(kMFSKSquelchThreshold[Int(index)])
    }

    @objc(enableModem:)
    override func enableModem(_ inActive: Bool) {
        active = inActive
        receiver?.enableReceiver(active)
    }

    @objc(waterfallRangeChanged:)
    func waterfallRangeChanged(_ sender: Any!) {
        waterfall?.setDynamicRange((sender as? NSControl)?.floatValue ?? 0)
    }

    @objc(flushTransmitStream:)
    func flushTransmitStream(_ sender: Any!) {
        //  modulator flushOutput was replaced by -flushOutput (v0.85)
        flushOutput()                               //  v0.85
    }

    //  --- preferences ---

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)

        pref.setString("Verdana", forKey: kMFSKFont)
        pref.setFloat(18.0, forKey: kMFSKFontSize)
        pref.setString("Verdana", forKey: kMFSKTxFont)
        pref.setFloat(14.0, forKey: kMFSKTxFontSize)

        //  v0.73
        pref.setString("Verdana", forKey: kDominoFont)
        pref.setFloat(18.0, forKey: kDominoFontSize)
        pref.setInt(1, forKey: kDominoSmoothScroll)
        pref.setInt(1, forKey: kDominoEchoBeacon)
        pref.setInt(1, forKey: kDominoRcvrEnable)
        pref.setInt(1, forKey: kDominoSendEnable)
        pref.setString("", forKey: kDominoBeacon)
        pref.setInt(1, forKey: kMFSKWaterfallNR)

        pref.setInt(11, forKey: kMFSKSelection)     //  0 = MFSK16, 11 = DominoEX11, 16 = DominoEX16, etc

        (config as? MFSKConfig)?.setupDefaultPreferences(pref)

        for i in 0..<3 {
            if let sheet = macroSheet(Int32(i)) as? MFSKMacros {
                sheet.setupDefaultPreferences(pref, option: Int32(i))
            }
        }
        //  set default Trellis depth
        pref.setInt(45, forKey: kMFSKTrellisDepth)
        pref.setInt(4, forKey: kMFSKSquelch)
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = super.updateFromPlist(pref)

        var fontName = pref.stringValue(forKey: kMFSKFont)
        var fontSize = pref.floatValue(forKey: kMFSKFontSize)
        if let attr = receiveTextAttribute { receiveView?.setTextFont(fontName ?? "", size: fontSize, attribute: attr) }

        fontName = pref.stringValue(forKey: kMFSKTxFont)
        fontSize = pref.floatValue(forKey: kMFSKTxFontSize)
        if let attr = transmitTextAttribute { transmitView?.setTextFont(fontName ?? "", size: fontSize, attribute: attr) }

        fontName = pref.stringValue(forKey: kDominoFont)
        fontSize = pref.floatValue(forKey: kDominoFontSize)
        if let attr = receiveTextAttribute { dominoReceiveView?.setTextFont(fontName ?? "", size: fontSize, attribute: attr) }

        manager?.showSplash("Updating MFSK configurations")
        _ = (config as? MFSKConfig)?.updateFromPlist(pref)

        var i = pref.intValue(forKey: kMFSKSquelch)
        (squelchSlider as? NSSlider)?.intValue = i
        squelchSliderChanged()

        manager?.showSplash("Loading MFSK macros")
        for j in 0..<3 {
            if let sheet = macroSheet(Int32(j)) as? MFSKMacros {
                _ = sheet.updateFromPlist(pref, option: Int32(j))
            }
        }
        //  check slashed zero key
        useSlashedZero(pref.intValue(forKey: kSlashZeros) != 0)

        //  v0.73
        (dominoSmoothScrollCheckbox as? NSButton)?.state = (pref.intValue(forKey: kDominoSmoothScroll) != 0) ? .on : .off
        (dominoBeaconEchoCheckbox as? NSButton)?.state = (pref.intValue(forKey: kDominoEchoBeacon) != 0) ? .on : .off
        setDominoReceiveBeaconState()
        (dominoReceiveCheckbox as? NSButton)?.state = (pref.intValue(forKey: kDominoRcvrEnable) != 0) ? .on : .off
        (dominoSendCheckbox as? NSButton)?.state = (pref.intValue(forKey: kDominoSendEnable) != 0) ? .on : .off
        let beaconString = pref.stringValue(forKey: kDominoBeacon)
        if beaconString == nil { (dominoSendField as? NSTextField)?.stringValue = "" }
        else { (dominoSendField as? NSTextField)?.stringValue = beaconString! }
        dominoTransmitBeaconChanged()
        waterfall?.setNoiseReductionState(pref.intValue(forKey: kMFSKWaterfallNR) != 0)

        let tag = pref.intValue(forKey: kMFSKSelection)
        (mfskModeMenu as? NSPopUpButton)?.selectItem(withTag: Int(tag))
        if ((mfskModeMenu as? NSPopUpButton)?.indexOfSelectedItem ?? -1) < 0 {
            (mfskModeMenu as? NSPopUpButton)?.selectItem(at: 0)
        }
        setMFSKMode()

        //  decoder parameters
        //  NOTE: Trellis depth can be changed by modifying the Plist file
        demodulator?.setTrellisDepth(pref.intValue(forKey: kMFSKTrellisDepth))

        i = 0                                       //  (silence unused-mutation warning)
        _ = i
        plistHasBeenUpdated = true                  //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }  //  v0.53d
        super.retrieveForPlist(pref)

        if let font = receiveView?.font {
            pref.setString(font.fontName, forKey: kMFSKFont)
            pref.setFloat(Float(font.pointSize), forKey: kMFSKFontSize)
        }
        if let font = transmitView?.font {
            pref.setString(font.fontName, forKey: kMFSKTxFont)
            pref.setFloat(Float(font.pointSize), forKey: kMFSKTxFontSize)
        }
        if let font = dominoReceiveView?.font {
            pref.setString(font.fontName, forKey: kDominoFont)
            pref.setFloat(Float(font.pointSize), forKey: kDominoFontSize)
        }

        let i = (squelchSlider as? NSSlider)?.intValue ?? 0
        pref.setInt(i, forKey: kMFSKSquelch)

        pref.setInt(((dominoSmoothScrollCheckbox as? NSButton)?.state == .on) ? 1 : 0, forKey: kDominoSmoothScroll)
        pref.setInt(((dominoReceiveCheckbox as? NSButton)?.state == .on) ? 1 : 0, forKey: kDominoRcvrEnable)
        pref.setInt(((dominoBeaconEchoCheckbox as? NSButton)?.state == .on) ? 1 : 0, forKey: kDominoEchoBeacon)
        pref.setInt(((dominoSendCheckbox as? NSButton)?.state == .on) ? 1 : 0, forKey: kDominoSendEnable)
        pref.setString((dominoSendField as? NSTextField)?.stringValue, forKey: kDominoBeacon)
        pref.setInt((waterfall?.noiseReductionState() == true) ? 1 : 0, forKey: kMFSKWaterfallNR)

        let tag = Int32((mfskModeMenu as? NSPopUpButton)?.selectedItem?.tag ?? 0)
        pref.setInt(tag, forKey: kMFSKSelection)

        (config as? MFSKConfig)?.retrieveForPlist(pref)
        for j in 0..<3 {
            if let sheet = macroSheet(Int32(j)) as? MFSKMacros {
                sheet.retrieveForPlist(pref, option: Int32(j))
            }
        }
    }

    //  delegates
    @objc func textViewDidChangeSelection(_ notify: Notification) {
        let obj = notify.object as AnyObject?
        if let obj = obj, obj === receiveView {
            captureSelection(receiveView)
        }
        callsignClickSuccessful(enableClick)
    }

    //  Delegate of receiveView and transmitView
    func textView(_ textView: NSTextView, shouldChangeTextIn original: NSRange, replacementString replace: String?) -> Bool {
        let replaceLength = (replace as NSString?)?.length ?? 0

        if (textView as AnyObject) === receiveView {
            if replaceLength != 0 {
                NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                _ = Messages.alert(withMessageText: NSLocalizedString("text is write only", comment: ""),
                                   informativeText: NSLocalizedString("cannot insert text", comment: ""))
                return false
            }
            return true
        }
        if (textView as AnyObject) === transmitView {
            if slashZero {
                guard let s = replace?.cString(using: .isoLatin1) else {
                    Messages.alertWithHiraganaError()
                    return false
                }
                var hasZero = false
                for ch in s {
                    if ch == 0 { break }
                    if ch == CChar(UInt8(ascii: "0")) { hasZero = true }
                }
                if hasZero {
                    let length = s.count - 1        //  strlen
                    if length < 32 {
                        var replacement = s
                        for i in 0..<replacement.count {
                            if replacement[i] == CChar(UInt8(ascii: "0")) {
                                replacement[i] = CChar(truncatingIfNeeded: kPhi)
                            }
                        }
                        //  replace zeros with phi and try again
                        let str = (NSString(cString: replacement, encoding: String.Encoding.isoLatin1.rawValue) as String?) ?? ""
                        transmitView?.replaceCharacters(in: original, with: str)
                        return false
                    }
                }
            }
            transmitViewLock?.lock()                //  v0.64
            let total = transmitView?.textStorage?.length ?? 0
            let start = original.location
            let length = original.length

            if length == total && replaceLength == 0 && transmitState == false {
                transmitView?.clearAll()
                indexOfUntransmittedText = 0
                transmitViewLock?.unlock()
                return false
            }
            if length > 0 {
                if (start + length) == total {
                    //  deleting <length> characters from end
                    if transmitState == true {
                        for _ in 0..<length { modulator?.appendASCII(0x08) }
                        indexOfUntransmittedText -= Int32(length)
                    }
                    transmitViewLock?.unlock()
                    return true
                }
                if transmitState == true {
                    transmitView?.insertAtEnd(replace ?? "")
                    NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                    transmitViewLock?.unlock()
                    return false
                }
                //  not yet transmitted
                if original.location < Int(indexOfUntransmittedText) {
                    NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                    _ = Messages.alert(withMessageText: NSLocalizedString("text already sent", comment: ""),
                                       informativeText: NSLocalizedString("cannot insert after sending", comment: ""))
                    transmitViewLock?.unlock()
                    return false
                }
                transmitViewLock?.unlock()
                return true
            }

            //  insertion length = 0
            if start != total {
                //  inserting in the middle of the transmitView
                if transmitState == true {
                    //  always insert text at the end when in transmit state
                    NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                    transmitView?.insertAtEnd(replace ?? "")
                    transmitViewLock?.unlock()
                    return false
                } else {
                    if original.location < Int(indexOfUntransmittedText) {
                        //  attempt to insert into text that has already been transmitted
                        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                        _ = Messages.alert(withMessageText: NSLocalizedString("text already sent", comment: ""),
                                           informativeText: NSLocalizedString("cannot insert after sending", comment: ""))
                        transmitViewLock?.unlock()
                        return false
                    }
                    transmitViewLock?.unlock()
                    return true
                }
            }
            //  inserting at the end of buffer (-checkTransmitBuffer will pick it up)
            if replaceLength != 0 {
                transmitViewLock?.unlock()
                return true
            }
        }
        transmitViewLock?.unlock()
        return true
    }

    //  -- AppleScript support --

    @objc(setModulationCodeFor:to:)
    override func setModulationCode(for transceiver: Transceiver!, to code: Int32) {
        var menuTag: Int32
        switch code {
        default:    //  'mf16'
            menuTag = kMFSK16Mode
        }
        _ = menuTag
        //  [ modeMenu selectItemWithTag:menuTag ] / [ self modeChanged ] were commented out
    }

    @objc(modulationCodeFor:)
    override func modulationCode(for transceiver: Transceiver!) -> Int32 {
        return kMF16Code        //  'mf16'
    }

    //  AppleScript support (callbacks from Modules)
    @objc(frequencyFor:)
    override func frequencyFor(_ module: Module!) -> Float {
        if module?.isReceiver() == true { return receiveFrequency() }
        return transmitFrequency()
    }

    @objc(setFrequency:module:)
    override func setFrequency(_ freq: Float, module: Module!) {
        if module?.isReceiver() == true {
            setRxFrequency(freq)
            enabled = true
            receiver?.selectFrequency(freq, fromWaterfall: true)  //  mimic a click
            clickedFrequency = freq
            receiver?.clicked(0)
        } else {
            setTxFrequency(freq)
        }
    }

    //  this is called from the AppleScript module
    @objc(transmitString:)
    override func transmitString(_ s: UnsafePointer<CChar>!) {
        guard var p = s else { return }
        while p.pointee != 0 {
            let uch = unichar(bitPattern: Int16(p.pointee))
            modulator?.appendASCII(Int32(uch))
            p = p.advanced(by: 1)
        }
    }

    @objc(setInvert:module:)
    override func setInvert(_ state: Bool, module: Module!) {
        //  do nothing in MFSK
    }

    @objc(invertFor:)
    override func invertFor(_ module: Module!) -> Bool {
        return false
    }

    //  v0.96c
    @objc(selectView:)
    override func selectView(_ index: Int32) {
        var pview: NSView? = nil
        switch index {
        case 1:
            pview = (mfskMode == kMFSK16Mode) ? receiveView : dominoReceiveView
        case 0:
            pview = transmitView
        default:
            break
        }
        if let pview = pview { _ = pview.window?.makeFirstResponder(pview) }
    }

    //  directly open sound file (Shift-Cmd-F)
    @objc(openFile:)
    func openFile(_ sender: Any!) {
        (config as? MFSKConfig)?.directOpenSoundFile()
    }

    //  =======================================================================

    //  append a single character (C "char buffer[2]" idiom) to an AYTextView
    private func append(_ c: Int32, to view: AYTextView?) {
        var buffer: [CChar] = [CChar(truncatingIfNeeded: c), 0]
        buffer.withUnsafeMutableBufferPointer { view?.append($0.baseAddress!) }
    }
}
