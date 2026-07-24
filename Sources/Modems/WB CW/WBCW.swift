//
//  WBCW.swift
//  cocoaModem
//
//  Created by Kok Chen on Dec 1 2006.
//  Swift port of WBCW.m / WBCW.h.
//
//  WBCW : WFRTTY : RTTYInterface : ContestInterface : MacroInterface : Modem :
//  CMPipe.  The two-receiver "Wideband CW" waterfall mode tab (Morse decode with
//  a break-in keyer and CW sidetone monitor).  StdManager instantiates it via
//  `WBCW(into:manager:)` (@objc selector `initIntoTabView:manager:`), loading the
//  "WBCW" nib.
//
//  Port notes:
//   * All CW collaborators (CWRxControl, CWReceiver, CWTxConfig, CWMonitor,
//     CWConfig, CWMacros) are Swift (parallel wave); no bridging-header change is
//     needed.  CW-specific methods are dispatched by exact @objc selector through
//     AnyObject optional-chaining (NIL-TOLERANCE), or via typed casts to the Swift
//     collaborator classes where a struct/pointer return is needed.
//   * The two original C arrays are kept: `lockedTonePair[2]` becomes a Swift
//     `[CMTonePair]` (CMTonePair is a value type) and the `transmittedBuffer[512]`
//     float scratch buffer becomes an UnsafeMutablePointer<Float> freed in deinit.
//   * Construction is done in the single designated `init?(into:manager:)`, which
//     reaches the base nib loader through `super.init(into:nib:manager:)`.
//

import Cocoa

//  ModemSource.h
private let LEFTCHANNEL: Int32 = 0
private let RIGHTCHANNEL: Int32 = 1

//  --- Plist keys (Plist.h) ---
private let kWBCWMainDevice: NSString          = "WBCW Input Device A"
private let kWBCWSubDevice: NSString           = "WBCW Input Device B"
private let kWBCWOutputDevice: NSString        = "WBCW Output Device"
private let kWBCWOutputLevel: NSString         = "WBCW Output Sound Level"
private let kWBCWOutputAttenuator: NSString    = "WBCW Output Attenuator"
private let kWBCWMainControlWindow: NSString   = "WBCW Control Window A"
private let kWBCWMainSquelch: NSString         = "WBCW Squelch A"
private let kWBCWMainActive: NSString          = "WBCW Active A"
private let kWBCWMainMode: NSString            = "WBCW Mode A"
private let kWBCWMainPrefs: NSString           = "WBCW Prefs A"
private let kWBCWMainTextColor: NSString       = "WBCW Text Color 1"
private let kWBCWMainSentColor: NSString       = "WBCW Sent Color 1"
private let kWBCWMainBackgroundColor: NSString = "WBCW Background Color 1"
private let kWBCWMainPlotColor: NSString       = "WBCW Plot Color 1"
private let kWBCWMainOffset: NSString          = "WBCW Offset A"

private let kWBCWSubControlWindow: NSString    = "WBCW Control Window B"
private let kWBCWSubSquelch: NSString          = "WBCW Squelch B"
private let kWBCWSubActive: NSString           = "WBCW Active B"
private let kWBCWSubMode: NSString             = "WBCW Mode B"
private let kWBCWSubPrefs: NSString            = "WBCW Prefs B"
private let kWBCWSubTextColor: NSString        = "WBCW Text Color 2"
private let kWBCWSubSentColor: NSString        = "WBCW Sent Color 2"
private let kWBCWSubBackgroundColor: NSString  = "WBCW Background Color 2"
private let kWBCWSubPlotColor: NSString        = "WBCW Plot Color 2"
private let kWBCWSubOffset: NSString           = "WBCW Offset B"

private let kWBCWFontA          = "WBCW Font A"
private let kWBCWFontSizeA      = "WBCW Font Size A"
private let kWBCWFontB          = "WBCW Font B"
private let kWBCWFontSizeB      = "WBCW Font Size B"
private let kWBCWTxFont         = "WBCW Tx Font"
private let kWBCWTxFontSize     = "WBCW Tx Font Size"
private let kWBCWTransmitChannel = "WBCW TransmitChannel"
private let kWBCWMainWaterfallNR = "WBCW Waterfall Noise Reduction A"
private let kWBCWSubWaterfallNR  = "WBCW Waterfall Noise Reduction B"
private let kWBCWBreakin        = "WBCW Breakin"
private let kWBCWRisetime       = "WBCW Risetime"
private let kWBCWWeight         = "WBCW Weight"
private let kWBCWRatio          = "WBCW Ratio"
private let kWBCWFarnsworth     = "WBCW Farnsworth"
private let kWBCWSpeed          = "WBCW Speed"
private let kWBCWModulation     = "WBCW Modulation"
private let kWBCWPTTLeadIn      = "WBCW PTT Lead in"
private let kWBCWPTTRelease     = "WBCW PTT Release"
private let kWBCWTxSidetoneLevel = "WBCW Tx Sidetone Level"
private let kSlashZeros         = "Null for Zero"

//  Phi (slashed-zero glyph), #define Phi 0xd8 in cocoaModemParams.h
private let Phi: Int32 = 0xd8

@objc(WBCW)
class WBCW: WFRTTY {

    //  --- IBOutlets (id) ---
    @objc var monitor: AnyObject!
    @objc var risetimeSlider: AnyObject!
    @objc var weightSlider: AnyObject!
    @objc var ratioSlider: AnyObject!
    @objc var farnsworthSlider: AnyObject!
    @objc var sidetoneSlider: AnyObject!
    @objc var speedMenu: AnyObject!
    @objc var modulationMenu: AnyObject!            //  v0.85 -- J2A / OOK

    //  C float transmittedBuffer[512]; kept as an UnsafeMutablePointer (float*)
    internal let transmittedBuffer: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        p.initialize(repeating: 0, count: 512); return p
    }()
    internal var sidetoneGain: Float = 1.0
    internal var lockedTonePair = [CMTonePair](repeating: CMTonePair(), count: 2)

    deinit {
        transmittedBuffer.deinitialize(count: 512)
        transmittedBuffer.deallocate()
    }

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr?.showSplash("Creating Wideband CW Modem")
        super.init(into: tabview, nib: "WBCW", manager: mgr)
        manager = mgr

        let ellipseFatness: Float = 0.9

        //  break-in keying support
        isBreakin = false
        breakinTimer = nil
        breakinTimeout = 0
        breakinRelease = 500
        breakinLeadin = 30
        for i in 0..<512 { transmittedBuffer[i] = 0.0 }
        sidetoneGain = 1.0

        let setA = makeWFRTTYConfigSet(channel: LEFTCHANNEL,
            [ kWBCWMainDevice, kWBCWOutputDevice, kWBCWOutputLevel, kWBCWOutputAttenuator,
              nil, nil, nil, nil, kWBCWMainControlWindow,
              kWBCWMainSquelch, kWBCWMainActive, nil, kWBCWMainMode, nil,
              nil, kWBCWMainPrefs, kWBCWMainTextColor, kWBCWMainSentColor,
              kWBCWMainBackgroundColor, kWBCWMainPlotColor, kWBCWMainOffset, nil ],
            usesRTTYAuralMonitor: false, auralMonitor: nil)

        let setB = makeWFRTTYConfigSet(channel: RIGHTCHANNEL,
            [ kWBCWSubDevice, nil, nil, nil,
              nil, nil, nil, nil, kWBCWSubControlWindow,
              kWBCWSubSquelch, kWBCWSubActive, nil, kWBCWSubMode, nil,
              nil, kWBCWSubPrefs, kWBCWSubTextColor, kWBCWSubSentColor,
              kWBCWSubBackgroundColor, kWBCWSubPlotColor, kWBCWSubOffset, nil ],
            usesRTTYAuralMonitor: false, auralMonitor: nil)

        //  initialize txConfig before rxConfigs
        (txConfig as AnyObject?)?.awakeFromModem?(setA, rttyRxControl: a.control)
        ptt = (txConfig as? RTTYTxConfig)?.pttObject()

        a.isAlive = true
        a.control = CWRxControl(intoView: receiverA as? NSView, client: self, index: 0)
        a.receiver = a.control?.receiver_()
        a.receiver?.createClickBuffer()
        a.view = a.control?.view()
        currentRxView = a.view
        a.view?.setValue(self, forKey: "delegate")          //  text selections, etc
        a.textAttribute = a.control?.textAttribute()
        a.control?.setName(NSLocalizedString("Main Receiver", comment: ""))
        a.control?.setEllipseFatness(ellipseFatness)
        (configA as AnyObject?)?.awakeFromModem?(setA, rttyRxControl: a.control, txConfig: txConfig as? RTTYTxConfig)
        (configA as AnyObject?)?.setChannel?(0)
        config = configA
        control[0] = a.control
        configObjs[0] = configA
        txLocked[0] = false

        if let ctrl = a.control {
            var tonepair = ctrl.baseTonePair()
            tonepair.space = 0
            (waterfallA as AnyObject?)?.setTonePairMarker?(&tonepair, index: 0)
        }

        b.isAlive = true
        b.control = CWRxControl(intoView: receiverB as? NSView, client: self, index: 1)
        b.receiver = b.control?.receiver_()
        b.receiver?.createClickBuffer()
        b.view = b.control?.view()
        b.view?.setValue(self, forKey: "delegate")          //  text selections, etc
        b.textAttribute = b.control?.textAttribute()
        b.control?.setName(NSLocalizedString("Sub Receiver", comment: ""))
        b.control?.setEllipseFatness(ellipseFatness)
        (configB as AnyObject?)?.awakeFromModem?(setB, rttyRxControl: b.control, txConfig: txConfig as? RTTYTxConfig)   //  shared txConfig
        (configB as AnyObject?)?.setChannel?(1)
        control[1] = b.control
        configObjs[1] = configB
        txLocked[1] = false

        if let ctrl = b.control {
            var tonepair = ctrl.baseTonePair()
            tonepair.space = 0
            (waterfallB as AnyObject?)?.setTonePairMarker?(&tonepair, index: 1)
        }

        //  CW Monitor
        (monitor as AnyObject?)?.setupMonitor?(NSLocalizedString("CW Sidetone", comment: ""),
                                               modem: self, main: a.receiver as? CWReceiver, sub: b.receiver as? CWReceiver)

        (configTab as AnyObject?)?.setValue(self, forKey: "delegate")

        //  AppleScript text callback
        a.receiver?.registerModule(transceiver1?.receiver())
        b.receiver?.registerModule(transceiver2?.receiver())
        a.transmitModule = transceiver1?.transmitter()
        b.transmitModule = transceiver2?.transmitter()

        setA.deallocate()
        setB.deallocate()
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("Wideband CW", comment: "")

        awakeFromContest()
        //  use QSO transmitview
        (contestTab as? NSTabView)?.selectTabViewItem(at: 0)

        initCallsign()
        initColors()
        initMacros()

        receiveFrame = (groupB as? NSView)?.frame ?? .zero
        transceiveFrame = (groupA as? NSView)?.frame ?? .zero

        //  prefs
        usos = false; robust = false
        bell = true
        charactersSinceTimerStarted = 0
        timeout = nil
        transmitBufferCheck = nil
        thread = Thread.current
        //  transmit view
        indexOfUntransmittedText = 0
        transmitState = false; sentColor = false
        transmitCount = 0
        transmitCountLock = NSLock()

        if transmitView != nil {
            transmitTextAttribute = transmitView?.newAttribute()
            transmitView?.setValue(self, forKey: "delegate")
        }

        waterfall[0] = waterfallA
        waterfall[1] = waterfallB
        for i in 0..<2 {
            (waterfall[i] as AnyObject?)?.awakeFromModem?()
            (waterfall[i] as AnyObject?)?.enableIndicator?(self)
            (waterfall[i] as AnyObject?)?.setWaterfallID?(Int32(i))
        }

        //  actions
        if transmitButton != nil { setInterface(transmitButton as? NSControl, to: #selector(transmitButtonChanged)) }
        if breakinButton != nil {
            setInterface(breakinButton as? NSControl, to: #selector(breakinButtonChanged))
            setInterface(sidetoneSlider as? NSControl, to: #selector(sidetoneLevelChanged))
        }
        if transmitSelect != nil { setInterface(transmitSelect as? NSControl, to: #selector(transmitSelectChanged)) }
        if contestTransmitSelect != nil { setInterface(contestTransmitSelect as? NSControl, to: #selector(contestTransmitSelectChanged)) }
        if risetimeSlider != nil {
            setInterface(risetimeSlider as? NSControl, to: #selector(cwParametersChanged))
            setInterface(weightSlider as? NSControl, to: #selector(cwParametersChanged))
            setInterface(ratioSlider as? NSControl, to: #selector(cwParametersChanged))
            setInterface(farnsworthSlider as? NSControl, to: #selector(cwParametersChanged))
        }
        if speedMenu != nil { setInterface(speedMenu as? NSControl, to: #selector(sendingSpeedChanged)) }
        if leadinField != nil {
            setInterface(leadinField as? NSControl, to: #selector(breakinParamsChanged))
            setInterface(releaseField as? NSControl, to: #selector(breakinParamsChanged))
        }

        setInterface(restoreToneA as? NSControl, to: #selector(restoreTone(_:)))
        setInterface(restoreToneB as? NSControl, to: #selector(restoreTone(_:)))
        setInterface(dynamicRangeA as? NSControl, to: #selector(dynamicRangeChanged(_:)))
        setInterface(dynamicRangeB as? NSControl, to: #selector(dynamicRangeChanged(_:)))
        setInterface(transmitLock as? NSControl, to: #selector(txLockChanged))

        setInterface(modulationMenu as? NSControl, to: #selector(modulationChanged))    //  v0.85
    }

    @objc override func initMacros() {
        currentSheet = 0; check = 0
        let application = manager?.appObject()
        for i in 0..<3 {
            macroSheet[i] = CWMacros(sheet: ())
            (macroSheet[i] as? CWMacros)?.setUserInfo(application?.userInfoObject(),
                                                      qso: (manager as? StdManager)?.qsoObject(),
                                                      modem: self, canImport: true)
        }
    }

    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    @objc(setupSpectrum)
    override func setupSpectrum() {
        for i in 0..<2 { control[i]?.setWaterfall(waterfall[i] as? RTTYWaterfall) }
    }

    @objc(setVisibleState:)
    override func setVisibleState(_ visible: Bool) {
        //  update things in the contest interface
        contestBar?.cancel()
        if visible {
            if contestManager != nil { contestManager.setActiveContestInterface(self) }
            //  setup repeating macro bar
            contestBar?.setModem(self)
            updateContestMacroButtons()
        }
        //  update both configA and configB visibility
        (configA as AnyObject?)?.updateVisibleState?(visible)
        (configB as AnyObject?)?.updateVisibleState?(visible)

        (monitor as AnyObject?)?.setVisibleState?(visible)
    }

    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating Wideband CW sound source")
        (a.control as? CWRxControl)?.setupCWReceiverWithMonitor(monitor as? CWMonitor)
        (b.control as? CWRxControl)?.setupCWReceiverWithMonitor(monitor as? CWMonitor)
        setupSpectrum()
        (txConfig as? RTTYTxConfig)?.checkActive()      //  setup txConfig first
        (configA as AnyObject?)?.checkActive?()
        (configB as AnyObject?)?.checkActive?()
    }

    @objc(setSentColor:)
    override func setSentColor(_ state: Bool) {
        if ((transmitSelect as? NSMatrix)?.selectedColumn ?? 0) == 0 {
            setSentColor(state, view: a.view, textAttribute: a.textAttribute)
        } else {
            setSentColor(state, view: b.view, textAttribute: b.textAttribute)
        }
    }

    @objc(configChannelSelected)
    override func configChannelSelected() -> Int32 {
        guard let tab = configTab as? NSTabView, let sel = tab.selectedTabViewItem else { return 0 }
        return Int32(tab.indexOfTabViewItem(sel))
    }

    @objc(configObj:)
    override func configObj(_ index: Int32) -> ModemConfig! {
        return ((index == 0) ? configA : configB) as? ModemConfig
    }

    //  return the input attenuator (NSSlider) of the appropriate receiver bank
    @objc(inputAttenuator:)
    override func inputAttenuator(_ configp: ModemConfig!) -> NSSlider! {
        if (configp as AnyObject?) === (configA as AnyObject?), let ctrl = a.control { return ctrl.inputAttenuator }
        if (configp as AnyObject?) === (configB as AnyObject?), let ctrl = b.control { return ctrl.inputAttenuator }
        return nil
    }

    @objc(enableWide:index:)
    func enableWide(_ state: Bool, index n: Int32) {
        (monitor as AnyObject?)?.enableWide?(state, index: n)
    }

    @objc(enablePano:index:)
    func enablePano(_ state: Bool, index n: Int32) {
        (monitor as AnyObject?)?.enablePano?(state, index: n)
    }

    @objc(changeSpeedTo:index:)
    func changeSpeedTo(_ speed: Int32, index n: Int32) {
        if n == 0 { (a.receiver as AnyObject?)?.changeCodeSpeed?(to: speed) }
        if n == 1 { (b.receiver as AnyObject?)?.changeCodeSpeed?(to: speed) }
    }

    @objc(changeSquelchTo:fastQSB:slowQSB:index:)
    func changeSquelchTo(_ squelch: Float, fastQSB fast: Float, slowQSB slow: Float, index n: Int32) {
        if n == 0 { (a.receiver as AnyObject?)?.changeSquelch?(to: squelch, fastQSB: fast, slowQSB: slow) }
        if n == 1 { (b.receiver as AnyObject?)?.changeSquelch?(to: squelch, fastQSB: fast, slowQSB: slow) }
    }

    @objc(enableMonitor:index:)
    func enableMonitor(_ state: Bool, index n: Int32) {
        (monitor as AnyObject?)?.setEnabled?(state, index: n)
    }

    @objc(monitorLevel:index:)
    func monitorLevel(_ value: Float, index n: Int32) {
        (monitor as AnyObject?)?.monitorLevel?(value, index: n)
    }

    @objc(sidebandChanged:index:)
    func sidebandChanged(_ state: Int32, index n: Int32) {
        (monitor as AnyObject?)?.sidebandChanged?(state, index: n)
    }

    //  Application sends this through the ModemManager when quitting
    @objc override func applicationTerminating() {
        (monitor as? CWMonitor)?.terminate()
        (configA as AnyObject?)?.applicationTerminating?()      //  v0.78 configA/configB, not (common) config
        (configB as AnyObject?)?.applicationTerminating?()      //  v0.78
        ptt?.applicationTerminating()                           //  v0.89
    }

    @objc func startBreakinTimer() {
        breakinTimer = Timer.scheduledTimer(timeInterval: 0.010, target: self, selector: #selector(breakinCheck(_:)), userInfo: self, repeats: true)
    }

    @objc func cannotTransmit() {
        if contestBar != nil {
            contestBar.cancel()
            flushOutput()
        }
        Messages.alert(withMessageText: NSLocalizedString("Carrier frequency not selected.", comment: ""),
                       informativeText: NSLocalizedString("Frequency not set", comment: ""))
    }

    @objc override func transmitButtonChanged() {
        let state = ((transmitButton as? NSButton)?.state == .on)
        if state == false {
            //  unconditionally turn transmitter off
            super.transmitButtonChanged()
            if isBreakin && breakinTimer == nil {
                //  turn on break-in timer if the breakin button is active
                startBreakinTimer()
            }
            return
        }
        let rxControl = (((transmitSelect as? NSMatrix)?.selectedColumn ?? 0) == 0) ? control[0] : control[1]
        let tonepair = rxControl?.txTonePair() ?? CMTonePair()

        if tonepair.mark > 10.0 {
            if breakinTimer != nil {
                //  turn off break-in timer if manually transmitting
                breakinTimer.invalidate()
                breakinTimer = nil
            }
            super.transmitButtonChanged()
        } else {
            (transmitButton as? NSButton)?.state = .off
            cannotTransmit()
        }
    }

    /* local */
    @objc(transmitFrom:)
    override func transmitFrom(_ index: Int32) {
        transmitChannel = index
        if transmitChannel == 0 {
            a.control?.useAsTransmitTonePair(true)
            b.control?.useAsTransmitTonePair(false)
            (txConfig as? RTTYTxConfig)?.setupTones(from: a.control, lockTone: txLocked[0])
            currentRxView = a.view
        } else {
            a.control?.useAsTransmitTonePair(false)
            b.control?.useAsTransmitTonePair(true)
            (txConfig as? RTTYTxConfig)?.setupTones(from: b.control, lockTone: txLocked[1])
            currentRxView = b.view
        }
    }

    @objc override func txLockChanged() {
        for channel in 0..<2 {
            let wasLocked = txLocked[channel]
            guard let ctrl = control[channel] else { continue }
            var nowLocked = (((transmitLock as? NSMatrix)?.cell(atRow: 0, column: channel) as? NSCell)?.state == .on)
            txLocked[channel] = nowLocked
            if wasLocked != nowLocked {
                lockedTonePair[channel] = ctrl.rxTonePair()
                if nowLocked {
                    if lockedTonePair[channel].mark < 10.0 {
                        Messages.alert(withMessageText: NSLocalizedString("You have not yet selected a frequency in the waterfall!", comment: ""),
                                       informativeText: NSLocalizedString("First select frequency", comment: ""))
                        nowLocked = false
                    }
                    (ctrl as? CWRxControl)?.lockTonePairToCurrentTone()
                } else {
                    lockedTonePair[channel].mark = 0.0; lockedTonePair[channel].space = 0.0
                }
                ctrl.setTransmitLock(nowLocked)
                (waterfall[channel] as AnyObject?)?.setTransmitTonePairMarker?(&lockedTonePair[channel], index: Int32(channel))
            }
        }
    }

    @objc(changeTransmitStateTo:)
    override func changeTransmitStateTo(_ state: Bool) {
        (monitor as AnyObject?)?.changeTransmitStateTo?(state)

        if state {
            let channel = (((transmitSelect as? NSMatrix)?.selectedColumn ?? 0) == 0) ? 0 : 1
            let tonepair = txLocked[channel] ? lockedTonePair[channel] : (control[channel]?.rxTonePair() ?? CMTonePair())
            if tonepair.mark < 10.0 { return }
            (txConfig as AnyObject?)?.setCarrier?(Float(tonepair.mark))
        }
        changeNonAuralTransmitStateTo(state)
    }

    @objc(setTextColor:sentColor:backgroundColor:plotColor:forReceiver:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!, forReceiver rx: Int32) {
        if rx == 0 {
            super.setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)
            (a.view as AnyObject?)?.setBackgroundColor?(bgColor)
            a.view?.setTextColor(inTextColor, attribute: (a.control?.textAttribute())!)
            a.control?.setPlotColor(pColor)
        } else {
            (b.view as AnyObject?)?.setBackgroundColor?(bgColor)
            b.view?.setTextColor(inTextColor, attribute: (b.control?.textAttribute())!)
            b.control?.setPlotColor(pColor)
        }
    }

    @objc(setTextColor:sentColor:backgroundColor:plotColor:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!) {
        super.setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)
        (a.view as AnyObject?)?.setBackgroundColor?(bgColor)
        (b.view as AnyObject?)?.setBackgroundColor?(bgColor)
        a.view?.setTextColor(textColor, attribute: (a.control?.textAttribute())!)
        b.view?.setTextColor(textColor, attribute: (b.control?.textAttribute())!)
        a.control?.setPlotColor(plotColor)
        b.control?.setPlotColor(plotColor)
    }

    //  whenever break-in button is set, this timer runs every 10 ms in the main thread
    @objc(breakinCheck:)
    func breakinCheck(_ timer: Timer!) {
        //  check transmitView to see if there are any untransmitted characters
        let total = Int32(transmitView?.textStorage?.length ?? 0)

        let bufferEmpty = ((txConfig as AnyObject?)?.bufferEmpty?() ?? true)
        if indexOfUntransmittedText < total || bufferEmpty == false {
            breakinTimeout = 0
            if transmitState == false {
                (txConfig as AnyObject?)?.holdOff?(breakinLeadin)
                changeTransmitStateTo(true)
            }
        } else {
            //  no text, start the time-out count (fixed 800 ms timeout)
            if transmitState == true {
                breakinTimeout += 10
                if breakinTimeout > breakinRelease {
                    changeTransmitStateTo(false)
                }
            }
        }
    }

    //  callback from Morse generator to keep break-in alive
    @objc(keepBreakinAlive:)
    func keepBreakinAlive(_ duration: Int32) {
        //  reset break-in timeout
        breakinTimeout = -(duration + 10)
    }

    @objc func breakinButtonChanged() {
        let wasBreakin = isBreakin
        isBreakin = ((breakinButton as? NSButton)?.state == .on)
        if wasBreakin != isBreakin {
            if isBreakin {
                //  create breakin timer in main thread
                performSelector(onMainThread: #selector(startBreakinTimer), with: nil, waitUntilDone: false)
            } else {
                //  breakin disabled
                breakinTimer?.invalidate()
                breakinTimer = nil
            }
        }
    }

    //  v0.85
    @objc(ook:)
    override func ook(_ configr: RTTYConfig!) -> Int32 {
        let tag = (modulationMenu as? NSPopUpButton)?.selectedItem?.tag ?? 0
        return (tag != 0) ? 1 : 0
    }

    @objc(switchCWModemIn:)
    func switchCWModemIn(_ tag: Int32) {
        (configA as AnyObject?)?.setCWKeyerMode?(tag, ptt: ptt)
        (configB as AnyObject?)?.setCWKeyerMode?(tag, ptt: ptt)
    }

    //  v0.85
    @objc func modulationChanged() {
        let tag = Int32((modulationMenu as? NSPopUpButton)?.selectedItem?.tag ?? 0)
        (txConfig as AnyObject?)?.setModulationMode?(tag)
        switchCWModemIn(tag)
    }

    //  v0.87  switchModemIn for a modem with two configs
    @objc override func switchModemIn() {
        let tag = Int32((modulationMenu as? NSPopUpButton)?.selectedItem?.tag ?? 0)
        switchCWModemIn(tag)
    }

    @objc func cwParametersChanged() {
        let risetime = (risetimeSlider as? NSControl)?.floatValue ?? 0
        let weight = (weightSlider as? NSControl)?.floatValue ?? 0
        let ratio = (ratioSlider as? NSControl)?.floatValue ?? 0
        let farnsworth = (farnsworthSlider as? NSControl)?.floatValue ?? 0
        (txConfig as AnyObject?)?.setRisetime?(risetime, weight: weight, ratio: ratio, farnsworth: farnsworth)
    }

    @objc func sendingSpeedChanged() {
        (txConfig as AnyObject?)?.setSpeed?(Float((speedMenu as? NSPopUpButton)?.selectedItem?.tag ?? 0))
    }

    @objc func breakinParamsChanged() {
        breakinLeadin = Int32((leadinField as? NSControl)?.intValue ?? 0)
        breakinRelease = Int32((releaseField as? NSControl)?.intValue ?? 0)
    }

    @objc func sidetoneLevelChanged() {
        let v = (sidetoneSlider as? NSControl)?.floatValue ?? 0
        sidetoneGain = (v < -39.0) ? 0.0 : powf(10.0, v / 20.0)
    }

    //  transmitted audio buffer
    @objc(sendSidetoneBuffer:)
    func sendSidetoneBuffer(_ buf: UnsafeMutablePointer<Float>!) {
        for i in 0..<512 { transmittedBuffer[i] = (buf?[i] ?? 0) * sidetoneGain }
        (monitor as AnyObject?)?.transmitted?(transmittedBuffer, samples: 512)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        setupDefaultPreferencesFromSuper(pref)

        pref?.setString("Verdana", forKey: kWBCWFontA)
        pref?.setFloat(14.0, forKey: kWBCWFontSizeA)
        pref?.setString("Verdana", forKey: kWBCWFontB)
        pref?.setFloat(14.0, forKey: kWBCWFontSizeB)

        pref?.setString("Verdana", forKey: kWBCWTxFont)
        pref?.setFloat(14.0, forKey: kWBCWTxFontSize)

        pref?.setInt(0, forKey: kWBCWTransmitChannel)
        pref?.setInt(1, forKey: kWBCWMainWaterfallNR)
        pref?.setInt(1, forKey: kWBCWSubWaterfallNR)

        //  default CW keying parameters
        pref?.setInt(0, forKey: kWBCWBreakin)
        pref?.setFloat(5.0, forKey: kWBCWRisetime)
        pref?.setFloat(0.5, forKey: kWBCWWeight)
        pref?.setFloat(3.0, forKey: kWBCWRatio)
        pref?.setFloat(1.0, forKey: kWBCWFarnsworth)
        pref?.setInt(25, forKey: kWBCWSpeed)

        pref?.setInt(0, forKey: kWBCWModulation)        //  v0.85

        pref?.setInt(30, forKey: kWBCWPTTLeadIn)
        pref?.setInt(500, forKey: kWBCWPTTRelease)

        pref?.setFloat(0.0, forKey: kWBCWTxSidetoneLevel)

        pref?.setRed(1.0, green: 0.8, blue: 0.0, forKey: kWBCWMainTextColor as String)
        pref?.setRed(0.0, green: 0.8, blue: 1.0, forKey: kWBCWMainSentColor as String)
        pref?.setRed(0.0, green: 0.0, blue: 0.0, forKey: kWBCWMainBackgroundColor as String)
        pref?.setRed(0.0, green: 1.0, blue: 0.0, forKey: kWBCWMainPlotColor as String)
        pref?.setRed(1.0, green: 0.8, blue: 0.0, forKey: kWBCWSubTextColor as String)
        pref?.setRed(0.0, green: 0.8, blue: 1.0, forKey: kWBCWSubSentColor as String)
        pref?.setRed(0.0, green: 0.0, blue: 0.0, forKey: kWBCWSubBackgroundColor as String)
        pref?.setRed(0.0, green: 1.0, blue: 0.0, forKey: kWBCWSubPlotColor as String)

        (configA as AnyObject?)?.setupDefaultPreferences?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.setupDefaultPreferences?(pref, rttyRxControl: b.control)

        for i in 0..<3 {
            if let sheet = macroSheet[i] { (sheet as? RTTYMacros)?.setupDefaultPreferences(pref, option: Int32(i)) }
        }

        (monitor as AnyObject?)?.setupDefaultPreferences?(pref)
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = updateFromPlistFromSuper(pref)

        //  v0.73
        (waterfallA as AnyObject?)?.setNoiseReductionState?((pref?.intValue(forKey: kWBCWMainWaterfallNR) ?? 0) != 0)
        (waterfallB as AnyObject?)?.setNoiseReductionState?((pref?.intValue(forKey: kWBCWSubWaterfallNR) ?? 0) != 0)

        var fontName = pref?.stringValue(forKey: kWBCWFontA)
        var fontSize = pref?.floatValue(forKey: kWBCWFontSizeA) ?? 0
        a.view?.setTextFont(fontName ?? "", size: fontSize, attribute: (a.control?.textAttribute())!)

        fontName = pref?.stringValue(forKey: kWBCWFontB)
        fontSize = pref?.floatValue(forKey: kWBCWFontSizeB) ?? 0
        b.view?.setTextFont(fontName ?? "", size: fontSize, attribute: (b.control?.textAttribute())!)

        fontName = pref?.stringValue(forKey: kWBCWTxFont)
        fontSize = pref?.floatValue(forKey: kWBCWTxFontSize) ?? 0
        transmitView?.setTextFont(fontName ?? "", size: fontSize, attribute: transmitTextAttribute!)

        let txChannel = pref?.intValue(forKey: kWBCWTransmitChannel) ?? 0
        transmitFrom(txChannel)
        (transmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: Int(txChannel))
        (contestTransmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: Int(txChannel))
        transmitSelectChanged()

        (breakinButton as? NSButton)?.state = ((pref?.intValue(forKey: kWBCWBreakin) ?? 0) != 0) ? .on : .off
        breakinButtonChanged()
        (risetimeSlider as? NSControl)?.floatValue = pref?.floatValue(forKey: kWBCWRisetime) ?? 0
        (weightSlider as? NSControl)?.floatValue = pref?.floatValue(forKey: kWBCWWeight) ?? 0
        (ratioSlider as? NSControl)?.floatValue = pref?.floatValue(forKey: kWBCWRatio) ?? 0
        (farnsworthSlider as? NSControl)?.floatValue = pref?.floatValue(forKey: kWBCWFarnsworth) ?? 0
        cwParametersChanged()

        //  v0.85
        (modulationMenu as? NSPopUpButton)?.selectItem(at: Int(pref?.intValue(forKey: kWBCWModulation) ?? 0))
        modulationChanged()

        (sidetoneSlider as? NSControl)?.floatValue = pref?.floatValue(forKey: kWBCWTxSidetoneLevel) ?? 0
        sidetoneLevelChanged()

        (speedMenu as? NSPopUpButton)?.selectItem(withTag: Int(pref?.intValue(forKey: kWBCWSpeed) ?? 0))
        sendingSpeedChanged()

        (speedMenu as? NSPopUpButton)?.selectItem(withTag: Int(pref?.intValue(forKey: kWBCWSpeed) ?? 0))

        (leadinField as? NSControl)?.intValue = Int32(pref?.intValue(forKey: kWBCWPTTLeadIn) ?? 0)
        (releaseField as? NSControl)?.intValue = Int32(pref?.intValue(forKey: kWBCWPTTRelease) ?? 0)
        breakinParamsChanged()

        manager?.showSplash("Updating WBCW configurations")
        (configA as AnyObject?)?.updateFromPlist?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.updateFromPlist?(pref, rttyRxControl: b.control)
        //  check slashed zero key
        useSlashedZero((pref?.intValue(forKey: kSlashZeros) ?? 0) != 0)

        _ = (monitor as? CWMonitor)?.updateFromPlist(pref)
        for i in 0..<3 {
            if let sheet = macroSheet[i] { (sheet as? CWMacros)?.updateFromPlist(pref, option: Int32(i)) }
        }
        plistHasBeenUpdated = true                  //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }  //  v0.53d

        retrieveForPlistFromSuper(pref)

        var font = a.view?.font
        pref?.setString(font?.fontName, forKey: kWBCWFontA)
        pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kWBCWFontSizeA)
        font = b.view?.font
        pref?.setString(font?.fontName, forKey: kWBCWFontB)
        pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kWBCWFontSizeB)

        font = transmitView?.font
        pref?.setString(font?.fontName, forKey: kWBCWTxFont)
        pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kWBCWTxFontSize)

        pref?.setInt(transmitChannel, forKey: kWBCWTransmitChannel)
        pref?.setInt(isBreakin ? 1 : 0, forKey: kWBCWBreakin)

        pref?.setFloat((risetimeSlider as? NSControl)?.floatValue ?? 0, forKey: kWBCWRisetime)
        pref?.setFloat((weightSlider as? NSControl)?.floatValue ?? 0, forKey: kWBCWWeight)
        pref?.setFloat((ratioSlider as? NSControl)?.floatValue ?? 0, forKey: kWBCWRatio)
        pref?.setFloat((farnsworthSlider as? NSControl)?.floatValue ?? 0, forKey: kWBCWFarnsworth)

        pref?.setInt(Int32((speedMenu as? NSPopUpButton)?.selectedItem?.tag ?? 0), forKey: kWBCWSpeed)
        pref?.setInt(Int32((leadinField as? NSControl)?.intValue ?? 0), forKey: kWBCWPTTLeadIn)
        pref?.setInt(Int32((releaseField as? NSControl)?.intValue ?? 0), forKey: kWBCWPTTRelease)

        pref?.setInt(Int32((modulationMenu as? NSPopUpButton)?.indexOfSelectedItem ?? 0), forKey: kWBCWModulation)   //  v0.85

        pref?.setFloat((sidetoneSlider as? NSControl)?.floatValue ?? 0, forKey: kWBCWTxSidetoneLevel)

        //  v0.73
        pref?.setInt(((waterfallA as AnyObject?)?.noiseReductionState?() ?? false) ? 1 : 0, forKey: kWBCWMainWaterfallNR)
        pref?.setInt(((waterfallB as AnyObject?)?.noiseReductionState?() ?? false) ? 1 : 0, forKey: kWBCWSubWaterfallNR)

        (configA as AnyObject?)?.retrieveForPlist?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.retrieveForPlist?(pref, rttyRxControl: b.control)

        (monitor as AnyObject?)?.retrieveForPlist?(pref)
        for i in 0..<3 {
            if let sheet = macroSheet[i] { (sheet as? CWMacros)?.retrieveForPlist(pref, option: Int32(i)) }
        }
    }

    // ----------------------------------------------------------------

    @objc(tonePairChanged:)
    override func tonePairChanged(_ ctrl: RTTYRxControl!) {
        let channel = ((ctrl as AnyObject?) === (control[0] as AnyObject?)) ? 0 : 1
        let sideband = ctrl?.sideband_() ?? 0
        var tonepair = txLocked[channel] ? (ctrl?.lockedTxTonePair() ?? CMTonePair()) : (ctrl?.baseTonePair() ?? CMTonePair())
        tonepair.space = 0

        (waterfall[channel] as AnyObject?)?.setSideband?(sideband)
        (waterfall[channel] as AnyObject?)?.setTonePairMarker?(&tonepair, index: Int32(channel))
    }

    //  called from the waterfall when it is shift clicked.  channel 0 = main receiver
    @objc(turnOffReceiver:option:)
    override func turnOffReceiver(_ channel: Int32, option: Bool) {
        let ctrl = control[Int(channel)] as? CWRxControl
        ctrl?.setFrequency(0.0)
        (waterfall[Int(channel)] as AnyObject?)?.display?()      //  force waterfall to erase marker
        ctrl?.enableCWReceiver(false)
    }

    //  waterfall clicked
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    override func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID waterfallChannel: Int32) {
        if (txConfig as? RTTYTxConfig)?.transmitActive() == true { return }     //  don't obey clicks when transmitting

        let cfg = configObjs[Int(waterfallChannel)]
        if ((cfg as AnyObject?)?.soundInputActive?() ?? false) == false {
            if waterfallChannel == 1 { (waterfallB as AnyObject?)?.clearMarkers?() } else { (waterfallA as AnyObject?)?.clearMarkers?() }
            Messages.alert(withMessageText: NSLocalizedString("Sound Card not active", comment: ""),
                           informativeText: NSLocalizedString("Cannot click on inactive waterfall", comment: ""))
            return
        }

        let ch = Int(waterfallChannel & 1)
        let ctrl = control[ch] as? CWRxControl
        let oldFreq = Float(control[ch]?.rxTonePair().mark ?? 0)
        ctrl?.setFrequency(freq)
        ctrl?.newClick(freq - oldFreq)

        if option {
            //  control clicked
            print("No RIT for now")
            (ctrl as AnyObject?)?.setRIT?(0)            //  no RIT for now
            return
        }
        //  clear RIT if not control clicked
        (ctrl as AnyObject?)?.setRIT?(0.0)

        if acquire {
            ctrl?.receiver_()?.clicked(secs)
        }
        ctrl?.enableCWReceiver(true)

        (NSApp.delegate as? AppDelegate)?.application()?.setDirectFrequencyFieldTo(freq)
    }

    @objc(defaultSliders:)
    func defaultSliders(_ sender: Any!) {
        (risetimeSlider as? NSControl)?.floatValue = 5.0
        (weightSlider as? NSControl)?.floatValue = 0.5
        (ratioSlider as? NSControl)?.floatValue = 3.0
        (farnsworthSlider as? NSControl)?.floatValue = 1.0
    }

    @objc override func updateMacroButtons() {
        updateModeMacroButtons()        //  overrides the RTTY updateMacroButtons
    }

    @objc(checkIfCanTransmit)
    override func checkIfCanTransmit() -> Bool {
        let rxControl = (((transmitSelect as? NSMatrix)?.selectedColumn ?? 0) == 0) ? control[0] : control[1]
        let tonepair = rxControl?.txTonePair() ?? CMTonePair()
        if tonepair.mark < 10.0 {
            cannotTransmit()
            return false
        }
        return true
    }

    //  AppleScript support
    @objc(setInvert:module:)
    override func setInvert(_ state: Bool, module: Module!) {
        //  do nothing in CW
    }

    @objc(invertFor:)
    override func invertFor(_ module: Module!) -> Bool {
        return false
    }

    @objc(breakinFor:)
    override func breakinFor(_ module: Module!) -> Bool {
        if module?.isReceiver() == true {
            //  receiver, no breakin function
            return false
        }
        //  transmitter
        return isBreakin
    }

    @objc(setBreakin:module:)
    override func setBreakin(_ state: Bool, module: Module!) {
        if module?.isReceiver() == true {
            //  receiver, no breakin
            return
        }
        //  set transmitter breakin state
        (breakinButton as? NSButton)?.state = state ? .on : .off
        breakinButtonChanged()
    }

    //  v0.56
    @objc override func selectedTransceiver() -> Int32 {
        return transmitChannel + 1
    }

    //  execute string
    @objc(executeMacroString:)
    override func executeMacroString(_ macro: String!) {
        if !checkIfCanTransmit() { return }

        if let macro = macro { transmitView?.insertAtEnd(macro) }

        if transmitCount > 0 {
            //  keep transmit on if needed
            if transmitState == false {
                changeTransmitStateTo(true)
            }
        }
    }

    //  execute a macro in a macroSheet
    @objc(executeMacro:macroSheet:fromContest:)
    override func executeMacro(_ index: Int32, macroSheet sheet: MacroSheet!, fromContest: Bool) {
        let macro = sheet?.expandMacro(index, modem: self)
        if fromContest { alwaysAllowMacro = 2 }
        executeMacroString(macro)
    }

    //  callback from AFSK generator (copy of RTTYInterface)
    @objc(transmittedCharacter:)
    override func transmittedCharacter(_ c: Int32) {
        var c = c
        if c <= 26 {
            //  control character in stream
            switch c + Int32(UInt8(ascii: "a")) - 1 {
            case Int32(UInt8(ascii: "e")):
                transmitCountLock?.lock()
                transmitCount -= 1
                transmitCountLock?.unlock()
                if transmitCount <= 0 {
                    changeTransmitStateTo(false)
                    transmitCountLock?.lock()
                    transmitCount = 0
                    transmitCountLock?.unlock()
                }
                //  is also end of macro
            case Int32(UInt8(ascii: "z")):
                //  end of macro transmitCount balance
                transmitCountLock?.lock()
                if transmitCount > 0 { transmitCount -= 1 }
                transmitCountLock?.unlock()
            default:
                //  for carriage return, newline, etc
                insertTransmittedCharacter(c)
                transmitView?.select()
            }
        } else {
            setSentColor(true)
            if c == Int32(UInt8(ascii: "0")) && slashZero { c = Phi }
            insertTransmittedCharacter(c)
            transmitView?.select()
        }
    }

    //  v0.87 NSMenuValidation for modulationMenu
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.tag == 2 && ptt != nil {
            //  check if we have a digiKeyer
            return (ptt as AnyObject?)?.hasQCW?() ?? false
        }
        return true
    }

    //  v1.02b
    @objc override func selectedFrequency() -> Float {
        guard let ctrl = control[0] else { return 0.0 }
        return ctrl.cwTone()
    }
}
