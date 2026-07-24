//
//  SITOR.swift
//  cocoaModem
//
//  Created by Kok Chen on Feb 6 2006.
//  Swift port of SITOR.m / SITOR.h.
//
//  SITOR : WFRTTY.  The two-receiver SITOR-B (Baudot / Moore ARQ) mode tab.
//  Receive-only (no transmitter): -enterTransmitMode: and -flushAndLeaveTransmit
//  do nothing and no txConfig is initialised.  StdManager instantiates it via
//  `SITOR(into:manager:)` (@objc selector `initIntoTabView:manager:`), loading the
//  "SITOR" nib.
//
//  Port notes:
//   * SITORRxControl / SITORReceiver / SITORDemodulator are all Swift (parallel
//     wave), so they are referenced directly; no bridging-header change needed.
//   * As with the other WFRTTY subclasses the original construction is done in the
//     single designated `init?(into:manager:)`, reaching the base nib loader via
//     `super.init(into:nib:manager:)`.  The original SITOR init did NOT populate
//     the inherited control[]/configObjs[]/txLocked[] arrays, so this port does
//     not either (its overridden methods use a/b directly).
//   * `id` outlets are @objc AnyObject!, reached through optional-chaining message
//     sends (NIL-TOLERANCE).
//

import Cocoa

//  ModemSource.h
private let LEFTCHANNEL: Int32 = 0
private let RIGHTCHANNEL: Int32 = 1

//  --- Plist keys (Plist.h) ---
private let kSitorMainDevice: NSString          = "SITOR-B Input Device A"
private let kSitorSubDevice: NSString           = "SITOR-B Input Device B"
private let kSitorMainTone: NSString            = "SITOR-B Main Tone Select"
private let kSitorMainMark: NSString            = "SITOR-B Main Mark Frequencies"
private let kSitorMainSpace: NSString           = "SITOR-B Main Space Frequencies"
private let kSitorMainBaud: NSString            = "SITOR-B Main Baud Rate"
private let kSitorMainControlWindow: NSString   = "SITOR-B Control Window A"
private let kSitorMainSquelch: NSString         = "SITOR-B Squelch A"
private let kSitorMainActive: NSString          = "SITOR-B Active A"
private let kSitorMainMode: NSString            = "SITOR-B Mode A"
private let kSitorMainRxPolarity: NSString      = "SITOR-B Main Rx Polarity"
private let kSitorMainPrefs: NSString           = "SITOR-B Prefs A"
private let kSitorMainTextColor: NSString       = "SITOR-B Text Color 1"
private let kSitorMainBackgroundColor: NSString = "SITOR-B Background Color 1"
private let kSitorMainPlotColor: NSString       = "SITOR-B Plot Color 1"
private let kSitorMainOffset: NSString          = "SITOR-B Offset A"

private let kSitorSubTone: NSString             = "SITOR-B Sub Tone Select"
private let kSitorSubMark: NSString             = "SITOR-B Sub Mark Frequencies"
private let kSitorSubSpace: NSString            = "SITOR-B Sub Space Frequencies"
private let kSitorSubBaud: NSString             = "SITOR-B Sub Baud Rate"
private let kSitorSubControlWindow: NSString    = "SITOR-B Control Window B"
private let kSitorSubSquelch: NSString          = "SITOR-B Squelch B"
private let kSitorSubActive: NSString           = "SITOR-B Active B"
private let kSitorSubStopBits: NSString         = "SITOR-B Stop Bits B"
private let kSitorSubMode: NSString             = "SITOR-B Mode B"
private let kSitorSubRxPolarity: NSString       = "SITOR-B Sub Rx Polarity"
private let kSitorSubPrefs: NSString            = "SITOR-B Prefs B"
private let kSitorSubTextColor: NSString        = "SITOR-B Text Color 2"
private let kSitorSubBackgroundColor: NSString  = "SITOR-B Background Color 2"
private let kSitorSubPlotColor: NSString        = "SITOR-B Plot Color 2"
private let kSitorSubOffset: NSString           = "SITOR-B Offset B"

private let kSitorFontA          = "SITOR-B Font A"
private let kSitorFontSizeA      = "SITOR-B Font Size A"
private let kSitorFontB          = "SITOR-B Font B"
private let kSitorFontSizeB      = "SITOR-B Font Size B"
private let kSlashZeros          = "Null for Zero"

@objc(SITOR)
class SITOR: WFRTTY {

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr?.showSplash("Creating SITOR-B Modem")
        super.init(into: tabview, nib: "SITOR", manager: mgr)
        manager = mgr

        let ellipseFatness: Float = 0.9

        let setA = makeWFRTTYConfigSet(channel: LEFTCHANNEL,
            [ kSitorMainDevice, nil, nil, nil,
              kSitorMainTone, kSitorMainMark, kSitorMainSpace, kSitorMainBaud, kSitorMainControlWindow,
              kSitorMainSquelch, kSitorMainActive, nil, kSitorMainMode, kSitorMainRxPolarity,
              nil, kSitorMainPrefs, kSitorMainTextColor, nil,
              kSitorMainBackgroundColor, kSitorMainPlotColor, kSitorMainOffset, nil ],
            usesRTTYAuralMonitor: false, auralMonitor: nil)

        let setB = makeWFRTTYConfigSet(channel: RIGHTCHANNEL,
            [ kSitorSubDevice, nil, nil, nil,
              kSitorSubTone, kSitorSubMark, kSitorSubSpace, kSitorSubBaud, kSitorSubControlWindow,
              kSitorSubSquelch, kSitorSubActive, kSitorSubStopBits, kSitorSubMode, kSitorSubRxPolarity,
              nil, kSitorSubPrefs, kSitorSubTextColor, nil,
              kSitorSubBackgroundColor, kSitorSubPlotColor, kSitorSubOffset, nil ],
            usesRTTYAuralMonitor: false, auralMonitor: nil)

        a.isAlive = true
        a.control = SITORRxControl(intoView: receiverA as? NSView, client: self, index: 0)
        a.receiver = a.control?.receiver_()
        a.view = a.control?.view()
        currentRxView = a.view
        a.view?.setValue(self, forKey: "delegate")          //  text selections, etc
        a.textAttribute = a.control?.textAttribute()
        a.control?.setName("Receiver A")
        a.control?.setEllipseFatness(ellipseFatness)
        (configA as AnyObject?)?.awakeFromModem?(setA, rttyRxControl: a.control, txConfig: nil)
        (configA as AnyObject?)?.setChannel?(0)

        if let ctrl = a.control {
            var tonepair = ctrl.baseTonePair()
            (waterfallA as AnyObject?)?.setTonePairMarker?(&tonepair, index: 0)
        }

        b.isAlive = true
        b.control = SITORRxControl(intoView: receiverB as? NSView, client: self, index: 1)
        b.receiver = b.control?.receiver_()
        b.view = b.control?.view()
        b.view?.setValue(self, forKey: "delegate")          //  text selections, etc
        b.textAttribute = b.control?.textAttribute()
        b.control?.setName("Receiver B")
        b.control?.setEllipseFatness(ellipseFatness)
        (configB as AnyObject?)?.awakeFromModem?(setB, rttyRxControl: b.control, txConfig: nil)
        (configB as AnyObject?)?.setChannel?(1)

        if let ctrl = b.control {
            var tonepair = ctrl.baseTonePair()
            (waterfallB as AnyObject?)?.setTonePairMarker?(&tonepair, index: 1)
        }

        (configTab as AnyObject?)?.setValue(self, forKey: "delegate")

        //  AppleScript text callback
        a.receiver?.registerModule(transceiver1?.receiver())
        b.receiver?.registerModule(transceiver2?.receiver())

        setA.deallocate()
        setB.deallocate()
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("SITOR-B", comment: "")

        awakeFromContest()
        //  use QSO transmitview
        (contestTab as? NSTabView)?.selectTabViewItem(at: 0)

        initColors()

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

        (waterfallA as AnyObject?)?.awakeFromModem?()
        (waterfallA as AnyObject?)?.enableIndicator?(self)
        (waterfallA as AnyObject?)?.setWaterfallID?(0)

        (waterfallB as AnyObject?)?.awakeFromModem?()
        (waterfallB as AnyObject?)?.enableIndicator?(self)
        (waterfallB as AnyObject?)?.setWaterfallID?(1)

        setInterface(restoreToneA as? NSControl, to: #selector(restoreTone(_:)))
        setInterface(restoreToneB as? NSControl, to: #selector(restoreTone(_:)))
        setInterface(dynamicRangeA as? NSControl, to: #selector(dynamicRangeChanged(_:)))
        setInterface(dynamicRangeB as? NSControl, to: #selector(dynamicRangeChanged(_:)))
    }

    @objc(enterTransmitMode:)
    override func enterTransmitMode(_ state: Bool) {
        //  do nothing
    }

    @objc override func flushAndLeaveTransmit() {
        //  do nothing
    }

    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    @objc(setupSpectrum)
    override func setupSpectrum() {
        a.control?.setWaterfall(waterfallA as? RTTYWaterfall)
        b.control?.setWaterfall(waterfallB as? RTTYWaterfall)
    }

    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating SITOR-B sound source")
        a.control?.setupRTTYReceiver()
        b.control?.setupRTTYReceiver()
        setupSpectrum()
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

    @objc(setTextColor:sentColor:backgroundColor:plotColor:forReceiver:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!, forReceiver rx: Int32) {
        if rx == 0 {
            super.setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)
            (a.view as AnyObject?)?.setBackgroundColor?(bgColor)
            a.view?.setTextColor(inTextColor, attribute: a.control!.textAttribute())
            a.control?.setPlotColor(pColor)
        } else {
            (b.view as AnyObject?)?.setBackgroundColor?(bgColor)
            b.view?.setTextColor(inTextColor, attribute: b.control!.textAttribute())
            b.control?.setPlotColor(pColor)
        }
    }

    @objc(setTextColor:sentColor:backgroundColor:plotColor:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!) {
        (a.view as AnyObject?)?.setBackgroundColor?(bgColor)
        (b.view as AnyObject?)?.setBackgroundColor?(bgColor)
        a.control?.setPlotColor(plotColor)
        b.control?.setPlotColor(plotColor)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        setupDefaultPreferencesFromSuper(pref)

        pref?.setString("Verdana", forKey: kSitorFontA)
        pref?.setFloat(14.0, forKey: kSitorFontSizeA)
        pref?.setString("Verdana", forKey: kSitorFontB)
        pref?.setFloat(14.0, forKey: kSitorFontSizeB)

        pref?.setRed(1.0, green: 0.8, blue: 0.0, forKey: kSitorMainTextColor as String)
        pref?.setRed(0.0, green: 0.0, blue: 0.0, forKey: kSitorMainBackgroundColor as String)
        pref?.setRed(0.0, green: 1.0, blue: 0.0, forKey: kSitorMainPlotColor as String)
        pref?.setRed(1.0, green: 0.8, blue: 0.0, forKey: kSitorSubTextColor as String)
        pref?.setRed(0.0, green: 0.0, blue: 0.0, forKey: kSitorSubBackgroundColor as String)
        pref?.setRed(0.0, green: 1.0, blue: 0.0, forKey: kSitorSubPlotColor as String)

        (configA as AnyObject?)?.setupDefaultPreferences?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.setupDefaultPreferences?(pref, rttyRxControl: b.control)
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = updateFromPlistFromSuper(pref)

        var fontName = pref?.stringValue(forKey: kSitorFontA)
        var fontSize = pref?.floatValue(forKey: kSitorFontSizeA) ?? 0
        a.view?.setTextFont(fontName!, size: fontSize, attribute: a.control!.textAttribute())

        fontName = pref?.stringValue(forKey: kSitorFontB)
        fontSize = pref?.floatValue(forKey: kSitorFontSizeB) ?? 0
        b.view?.setTextFont(fontName!, size: fontSize, attribute: b.control!.textAttribute())

        (configA as AnyObject?)?.updateFromPlist?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.updateFromPlist?(pref, rttyRxControl: b.control)
        //  check slashed zero key
        useSlashedZero((pref?.intValue(forKey: kSlashZeros) ?? 0) != 0)

        plistHasBeenUpdated = true                  //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }  //  v0.53d

        retrieveForPlistFromSuper(pref)

        var font = a.view?.font
        pref?.setString(font?.fontName, forKey: kSitorFontA)
        pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kSitorFontSizeA)
        font = b.view?.font
        pref?.setString(font?.fontName, forKey: kSitorFontB)
        pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kSitorFontSizeB)

        (configA as AnyObject?)?.retrieveForPlist?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.retrieveForPlist?(pref, rttyRxControl: b.control)
    }

    // ----------------------------------------------------------------

    @objc(showConfigPanel)
    override func showConfigPanel() {
        //  turn off transmit and open config panel
        (configA as AnyObject?)?.openPanel?()               //  use configA to open the same common panel
        if configChannelSelected() == 0 { (configA as AnyObject?)?.setConfigOpen?(true) } else { (configB as AnyObject?)?.setConfigOpen?(true) }
    }

    @objc(closeConfigPanel)
    override func closeConfigPanel() {
        (configA as AnyObject?)?.closePanel?()
        (configB as AnyObject?)?.closePanel?()
    }

    @objc(tonePairChanged:)
    override func tonePairChanged(_ ctrl: RTTYRxControl!) {
        var tonepair = ctrl?.baseTonePair() ?? CMTonePair()
        let sideband = ctrl?.sideband_() ?? 0
        if (ctrl as AnyObject?) === (a.control as AnyObject?) {
            (waterfallA as AnyObject?)?.setSideband?(sideband)
            (waterfallA as AnyObject?)?.setTonePairMarker?(&tonepair, index: 0)
        } else {
            (waterfallB as AnyObject?)?.setSideband?(sideband)
            (waterfallB as AnyObject?)?.setTonePairMarker?(&tonepair, index: 1)
        }
    }

    @objc(activeChanged:)
    override func activeChanged(_ cfg: ModemConfig!) {
        let active = (cfg as AnyObject?)?.soundInputActive?() ?? false
        if (cfg as AnyObject?) === (configA as AnyObject?) {
            (waterfallA as AnyObject?)?.setActive?(active, index: 0)
        } else {
            (waterfallB as AnyObject?)?.setActive?(active, index: 0)
        }
    }

    //  waterfall clicked
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    override func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID waterfallChannel: Int32) {
        let transceiver = (waterfallChannel == 0) ? a : b
        guard let ctrl = transceiver.control else { return }
        var tonepair = ctrl.baseTonePair()
        let sideband = ctrl.sideband_()

        if option {
            //  control clicked
            let delta = Double(freq) - tonepair.mark
            (ctrl as AnyObject?)?.setRIT?(Float(delta))
            return
        }

        //  clear RIT if not control clicked
        (ctrl as AnyObject?)?.setRIT?(0.0)
        let shift = Double(abs(Float(tonepair.mark) - Float(tonepair.space)))
        if sideband == 0 {
            tonepair.mark = Double(freq)
            tonepair.space = Double(freq) + shift
        } else {
            tonepair.mark = Double(freq) - shift
            tonepair.space = Double(freq)
        }
        (ctrl as AnyObject?)?.setTonePair?(&tonepair)

        (NSApp.delegate as? AppDelegate)?.application()?.setDirectFrequencyFieldTo(freq)
    }

    @objc(restoreTone:)
    override func restoreTone(_ sender: Any!) {
        let transceiver = ((sender as AnyObject?) === (restoreToneA as AnyObject?)) ? a : b
        (transceiver.control as AnyObject?)?.setRIT?(0.0)
        (transceiver.control as AnyObject?)?.fetchTonePairFromMemory?()
        (transceiver.control as AnyObject?)?.updateTonePairInformation?()    //  resets tone to memory settings
    }

    @objc(dynamicRangeChanged:)
    override func dynamicRangeChanged(_ sender: Any!) {
        let w: AnyObject? = ((sender as AnyObject?) === (dynamicRangeA as AnyObject?)) ? waterfallA : waterfallB
        let tag = (sender as? NSPopUpButton)?.selectedItem?.tag ?? 0
        (w as AnyObject?)?.setDynamicRange?(Float(tag) * 1.0)
    }

    @objc override func transmitSelectChanged() {
    }

    @objc override func contestTransmitSelectChanged() {
    }

    //  NSMatrix of NSButtons from Preferences.  SITOR-B has a different pref matrix
    //  from the other RTTY modes.
    @objc(setRTTYPrefs:channel:)
    override func setRTTYPrefs(_ rttyPrefs: NSMatrix!, channel: Int32) {
        let rx: AnyObject? = (channel == 0) ? a.receiver : b.receiver

        let count = rttyPrefs.numberOfRows
        for i in 0..<count {
            let button = rttyPrefs.cell(atRow: i, column: 0) as? NSButtonCell
            if button?.state == .on {
                switch i {
                case 0:
                    //  Unshift On Space
                    usos = true
                    (rx as AnyObject?)?.setUSOS?(usos)
                case 1:
                    //  Disable Baudot BELL
                    bell = false
                    (rx as AnyObject?)?.setBell?(bell)
                case 2:
                    //  Enable error print
                    ((rx as? RTTYReceiver)?.demodulator as AnyObject?)?.setErrorPrint?(true)
                default:
                    break
                }
            } else {
                switch i {
                case 0:
                    //  Unshift On Space
                    usos = false
                    (rx as AnyObject?)?.setUSOS?(usos)
                case 1:
                    //  Don't disable Baudot BELL
                    bell = true
                    (rx as AnyObject?)?.setBell?(bell)
                case 2:
                    //  Disable error print
                    ((rx as? RTTYReceiver)?.demodulator as AnyObject?)?.setErrorPrint?(false)
                default:
                    break
                }
            }
        }
    }

    //  delegate of WF RTTY's config window, disable config scopes
    @objc(windowShouldClose:)
    override func windowShouldClose(_ sender: Any!) -> Bool {
        (configA as AnyObject?)?.setConfigOpen?(false)
        (configB as AnyObject?)?.setConfigOpen?(false)
        return true
    }

    //  delegate to WF RTTY's config panel tab (main/sub receivers)
    @objc(tabView:didSelectTabViewItem:)
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let selectA = (tabViewItem != nil) && (tabView.indexOfTabViewItem(tabViewItem!) == 0)
        (configA as AnyObject?)?.setConfigOpen?(selectA)
        (configB as AnyObject?)?.setConfigOpen?(!selectA)
    }
}
