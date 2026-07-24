//
//  DualRTTY.swift
//  cocoaModem
//
//  Created by Kok Chen on Sun May 30 2004.
//  Swift port of DualRTTY.m / DualRTTY.h.
//
//  The dual-channel RTTY mode tab.  DualRTTY : RTTYInterface : ContestInterface :
//  MacroInterface : Modem : CMPipe.  Instantiated by StdManager via
//  -initIntoTabView:manager:, loading the "DualRTTY" nib.
//
//  Port notes:
//   * The C struct RTTYConfigSet has NSString* members, so Swift cannot import
//     it; the -awakeFromModem: methods take it as an OpaquePointer.  We build the
//     struct in raw memory (verified LP64 layout; see makeRTTYConfigSet) with the
//     key strings held as file-scope NSString constants so the pointers copied
//     into the config objects stay valid.
//   * Plist keys are #define'd Obj-C string literals in Plist.h, not importable
//     to Swift, so they are re-declared here (matching Plist.h).
//   * Text attributes are UnsafeMutablePointer<TextAttribute> (TextAttribute is a
//     C struct; -newAttribute / -textAttribute return a pointer to it).
//

import Cocoa

//  --- Plist keys used in the RTTYConfigSet (must be stable NSString storage) ---
private let kDualRTTYMainDevice: NSString           = "DualRTTY Input Device A"
private let kDualRTTYSubDevice: NSString            = "DualRTTY Input Device B"
private let kDualRTTYOutputDevice: NSString         = "DualRTTY Output Device"
private let kDualRTTYOutputLevel: NSString          = "DualRTTY Output Sound Level"
private let kDualRTTYOutputAttenuator: NSString     = "DualRTTY Output Attenuator"
private let kDualRTTYMainControlWindow: NSString    = "DualRTTY Control Window A"
private let kDualRTTYSubControlWindow: NSString     = "DualRTTY Control Window B"
private let kDualRTTYMainTone: NSString             = "DualRTTY Main Tone Select"
private let kDualRTTYMainMark: NSString             = "DualRTTY Main Mark Frequencies"
private let kDualRTTYMainSpace: NSString            = "DualRTTY Main Space Frequencies"
private let kDualRTTYMainBaud: NSString             = "DualRTTY Main Baud Rate"
private let kDualRTTYMainSquelch: NSString          = "DualRTTY Squelch A"
private let kDualRTTYMainActive: NSString           = "DualRTTY Active A"
private let kDualRTTYMainStopBits: NSString         = "DualRTTY Stop Bits A"
private let kDualRTTYMainMode: NSString             = "DualRTTY Mode A"
private let kDualRTTYMainRxPolarity: NSString       = "DualRTTY Main Rx Polarity"
private let kDualRTTYMainTxPolarity: NSString       = "DualRTTY Main Tx Polarity"
private let kDualRTTYMainPrefs: NSString            = "DualRTTY Prefs A"
private let kDualRTTYMainTextColor: NSString        = "DualRTTY Text Color 1"
private let kDualRTTYMainSentColor: NSString        = "DualRTTY Sent Color 1"
private let kDualRTTYMainBackgroundColor: NSString  = "DualRTTY Background Color 1"
private let kDualRTTYMainPlotColor: NSString        = "DualRTTY Plot Color 1"
private let kDualRTTYMainFSKSelection: NSString     = "DualRTTY Main FSK Selection"
private let kDualRTTYMainAuralMonitor: NSString     = "DualRTTY Main Aural Monitor"
private let kDualRTTYSubTone: NSString              = "DualRTTY Sub Tone Select"
private let kDualRTTYSubMark: NSString              = "DualRTTY Sub Mark Frequencies"
private let kDualRTTYSubSpace: NSString             = "DualRTTY Sub Space Frequencies"
private let kDualRTTYSubBaud: NSString              = "DualRTTY Sub Baud Rate"
private let kDualRTTYSubSquelch: NSString           = "DualRTTY Squelch B"
private let kDualRTTYSubActive: NSString            = "DualRTTY Active B"
private let kDualRTTYSubStopBits: NSString          = "DualRTTY Stop Bits B"
private let kDualRTTYSubMode: NSString              = "DualRTTY Mode B"
private let kDualRTTYSubRxPolarity: NSString        = "DualRTTY Sub Rx Polarity"
private let kDualRTTYSubTxPolarity: NSString        = "DualRTTY Sub Tx Polarity"
private let kDualRTTYSubPrefs: NSString             = "DualRTTY Prefs B"
private let kDualRTTYSubTextColor: NSString         = "DualRTTY Text Color 2"
private let kDualRTTYSubSentColor: NSString         = "DualRTTY Sent Color 2"
private let kDualRTTYSubBackgroundColor: NSString   = "DualRTTY Background Color 2"
private let kDualRTTYSubPlotColor: NSString         = "DualRTTY Plot Color 2"
private let kDualRTTYSubFSKSelection: NSString      = "DualRTTY Sub FSK Selection"
private let kDualRTTYSubAuralMonitor: NSString      = "DualRTTY Sub Aural Monitor"

//  --- Plist keys used only as preference keys ---
private let kDualRTTYFontA           = "DualRTTY Font A"
private let kDualRTTYFontSizeA       = "DualRTTY Font Size A"
private let kDualRTTYFontB           = "DualRTTY Font B"
private let kDualRTTYFontSizeB       = "DualRTTY Font Size B"
private let kDualRTTYTxFont          = "DualRTTY Tx Font"
private let kDualRTTYTxFontSize      = "DualRTTY Tx Font Size"
private let kDualRTTYSpectrumRange   = "DualRTTY Spectrum Range"
private let kDualRTTYSpectrumChannel = "DualRTTY Spectrum Channel"
private let kDualRTTYSpectrumDecay   = "DualRTTY Spectrum Decay"
private let kDualRTTYTransmitChannel = "DualRTTY TransmitChannel"
private let kSlashZeros              = "Null for Zero"

//  ModemSource.h: LEFTCHANNEL 0, RIGHTCHANNEL 1
private let kLeftChannel: Int32  = 0
private let kRightChannel: Int32 = 1

//  ---------------------------------------------------------------------------
//  RTTYConfigSet builder.  Verified LP64 layout:
//     int channel        @0
//     NSString* [22]     @8, 16, ... 176   (inputDevice ... fskSelection)
//     Boolean usesAural  @184
//     NSString* aural    @192
//     sizeof == 200
//  Caller must .deallocate() the returned buffer after -awakeFromModem: has
//  copied the struct out.
//  ---------------------------------------------------------------------------
private let kRTTYConfigSetSize = 200

private func makeRTTYConfigSet(channel: Int32, _ fields: [NSString?],
                               usesRTTYAuralMonitor: Bool, auralMonitor: NSString?) -> UnsafeMutablePointer<UInt8> {
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: kRTTYConfigSetSize)
    buf.initialize(repeating: 0, count: kRTTYConfigSetSize)
    let raw = UnsafeMutableRawPointer(buf)
    raw.storeBytes(of: channel, toByteOffset: 0, as: Int32.self)
    for (i, s) in fields.enumerated() {
        let bits = s.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        raw.storeBytes(of: bits, toByteOffset: 8 &+ i &* 8, as: UInt.self)
    }
    raw.storeBytes(of: usesRTTYAuralMonitor ? UInt8(1) : UInt8(0), toByteOffset: 184, as: UInt8.self)
    let ab = auralMonitor.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
    raw.storeBytes(of: ab, toByteOffset: 192, as: UInt.self)
    return buf
}

//  spectrum decay time constants / dynamic ranges (from DualRTTY.m statics)
private let timeConstants: [Float] = [ 0.0, 0.2, 0.5, 1.5, 4.0 ]
private let ranges: [Float]        = [ 40.0, 50.0, 60.0, 70.0, 80.0 ]

@objc(DualRTTY)
class DualRTTY: RTTYInterface, NSTextViewDelegate, NSTabViewDelegate, NSWindowDelegate {

    //  outlets from DualRTTY.nib
    @objc var spectrum: AnyObject!
    @objc var waterfall: AnyObject!

    @objc var receiverA: AnyObject!
    @objc var configA: AnyObject!

    @objc var receiverB: AnyObject!
    @objc var configB: AnyObject!

    @objc var timeConstant: AnyObject!
    @objc var dynamicRange: AnyObject!
    @objc var channel: AnyObject!

    @objc var configTab: AnyObject!

    @objc var transmitSelect: AnyObject!
    @objc var contestTransmitSelect: AnyObject!
    @objc var restoreToneButton: AnyObject!

    @objc var receiveFrame = NSRect.zero        //  frame of receive-only receiver
    @objc var transceiveFrame = NSRect.zero     //  frame of receive-transmit receiver

    //  DualRTTY : ContestInterface : MacroPanel : Modem : NSObject
    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr.showSplash("Creating Dual RTTY Modem")

        super.init(into: tabview, nib: "DualRTTY", manager: mgr)

        manager = mgr

        let setA = makeRTTYConfigSet(channel: kLeftChannel,
            [ kDualRTTYMainDevice, kDualRTTYOutputDevice, kDualRTTYOutputLevel, kDualRTTYOutputAttenuator,
              kDualRTTYMainTone, kDualRTTYMainMark, kDualRTTYMainSpace, kDualRTTYMainBaud,
              kDualRTTYMainControlWindow, kDualRTTYMainSquelch, kDualRTTYMainActive, kDualRTTYMainStopBits,
              kDualRTTYMainMode, kDualRTTYMainRxPolarity, kDualRTTYMainTxPolarity, kDualRTTYMainPrefs,
              kDualRTTYMainTextColor, kDualRTTYMainSentColor, kDualRTTYMainBackgroundColor, kDualRTTYMainPlotColor,
              nil, kDualRTTYMainFSKSelection ],
            usesRTTYAuralMonitor: true, auralMonitor: kDualRTTYMainAuralMonitor)

        let setB = makeRTTYConfigSet(channel: kRightChannel,
            [ kDualRTTYSubDevice, nil, nil, nil,
              kDualRTTYSubTone, kDualRTTYSubMark, kDualRTTYSubSpace, kDualRTTYSubBaud,
              kDualRTTYSubControlWindow, kDualRTTYSubSquelch, kDualRTTYSubActive, kDualRTTYSubStopBits,
              kDualRTTYSubMode, kDualRTTYSubRxPolarity, kDualRTTYSubTxPolarity, kDualRTTYSubPrefs,
              kDualRTTYSubTextColor, kDualRTTYSubSentColor, kDualRTTYSubBackgroundColor, kDualRTTYSubPlotColor,
              nil, kDualRTTYSubFSKSelection ],
            usesRTTYAuralMonitor: true, auralMonitor: kDualRTTYSubAuralMonitor)

        //  initialize txConfig before rxConfigs
        (txConfig as? RTTYTxConfig)?.awakeFromModem(UnsafeMutableRawPointer(setA).assumingMemoryBound(to: RTTYConfigSet.self), rttyRxControl: a.control)
        ptt = (txConfig as? RTTYTxConfig)?.pttObject()
        transmitChannel = 0

        a.isAlive = true
        a.control = RTTYRxControl(intoView: receiverA as? NSView, client: self, index: 0)
        a.receiver = a.control?.receiver
        currentRxView = a.control?.view()
        a.view = currentRxView
        a.view?.delegate = self             //  text selections, etc
        a.textAttribute = a.control?.textAttribute()
        a.control?.setName(NSLocalizedString("Main Receiver", comment: ""))
        (configA as? DualRTTYConfig)?.awakeFromModem(UnsafeMutableRawPointer(setA).assumingMemoryBound(to: RTTYConfigSet.self), rttyRxControl: a.control,
                                            txConfig: txConfig as? RTTYTxConfig)

        //  v0.78
        (txConfig as? RTTYTxConfig)?.setRTTYAuralMonitor(a.receiver?.rttyAuralMonitor)

        b.isAlive = true
        b.control = RTTYRxControl(intoView: receiverB as? NSView, client: self, index: 1)
        b.receiver = b.control?.receiver
        b.view = b.control?.view()
        b.view?.delegate = self             //  text selections, etc
        b.textAttribute = b.control?.textAttribute()
        b.control?.setName(NSLocalizedString("Sub Receiver", comment: ""))
        (configB as? DualRTTYConfig)?.awakeFromModem(UnsafeMutableRawPointer(setB).assumingMemoryBound(to: RTTYConfigSet.self), rttyRxControl: b.control,
                                            txConfig: txConfig as? RTTYTxConfig)   // note: shared txConfig

        (configTab as? NSTabView)?.delegate = self
        setInterface(timeConstant as? NSControl, to: #selector(spectrumOptionChanged))
        setInterface(dynamicRange as? NSControl, to: #selector(spectrumOptionChanged))
        setInterface(channel as? NSControl, to: #selector(spectrumOptionChanged))
        setInterface(transmitSelect as? NSControl, to: #selector(transmitSelectChanged))
        setInterface(contestTransmitSelect as? NSControl, to: #selector(contestTransmitSelectChanged))
        setInterface(restoreToneButton as? NSControl, to: #selector(restoreTonePairs))

        //  AppleScript text callback
        a.receiver?.registerModule(transceiver1?.receiver())
        b.receiver?.registerModule(transceiver2?.receiver())
        a.transmitModule = transceiver1?.transmitter()
        b.transmitModule = transceiver2?.transmitter()

        setA.deallocate()
        setB.deallocate()
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("Dual RTTY", comment: "")

        awakeFromContest()
        //  use QSO transmitview
        (contestTab as? NSTabView)?.selectTabViewItem(at: 0)

        receiveFrame = (receiverB as? NSView)?.frame ?? .zero
        transceiveFrame = (receiverA as? NSView)?.frame ?? .zero

        //  actions
        (transmitButton as? NSControl)?.action = #selector(transmitButtonChanged)
        (transmitButton as? NSControl)?.target = self

        initCallsign()
        initColors()
        //  application will set our macros to single RTTY macros

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

        transmitTextAttribute = transmitView?.newAttribute()
        transmitView?.delegate = self

        let wf = waterfall as? RTTYWaterfall
        wf?.awakeFromModem()
        wf?.setIgnoreSideband(true)
        wf?.setIgnoreArrowKeys(true)
        wf?.enableIndicator(self)
    }

    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        //  mirror the Objective-C cast (CMTappedPipe*)self
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    @objc func setupSpectrum() {
        switch (channel as? NSPopUpButton)?.indexOfSelectedItem ?? 0 {
        case 0:
            b.control?.setSpectrumView(nil)
            b.control?.setWaterfall(nil)
            a.control?.setSpectrumView(spectrum as? Spectrum)
            a.control?.setWaterfall(waterfall as? RTTYWaterfall)
        case 1:
            a.control?.setSpectrumView(nil)
            a.control?.setWaterfall(nil)
            b.control?.setSpectrumView(spectrum as? Spectrum)
            b.control?.setWaterfall(waterfall as? RTTYWaterfall)
        default:
            //  off
            a.control?.setSpectrumView(nil)
            a.control?.setWaterfall(nil)
            b.control?.setSpectrumView(nil)
            b.control?.setWaterfall(nil)
        }
        //  clamp popup indices to the static tables (indexOfSelectedItem can be -1)
        let t = min(max((timeConstant as? NSPopUpButton)?.indexOfSelectedItem ?? 0, 0), timeConstants.count - 1)
        var tc = timeConstants[t]
        if tc < timeConstants[1] {
            //  waterfall
            tc = timeConstants[1]
            (dynamicRange as? NSView)?.isHidden = true
            (spectrum as? NSView)?.isHidden = true
            (waterfall as? NSView)?.isHidden = false
            (restoreToneButton as? NSView)?.isHidden = true  /* NO if we allow clicking */
        } else {
            (dynamicRange as? NSView)?.isHidden = false
            (waterfall as? NSView)?.isHidden = true
            (restoreToneButton as? NSView)?.isHidden = true
            (spectrum as? NSView)?.isHidden = false
            let dr = min(max((dynamicRange as? NSPopUpButton)?.indexOfSelectedItem ?? 0, 0), ranges.count - 1)
            (spectrum as? Spectrum)?.setTimeConstant(tc, dynamicRange: ranges[dr])
            (spectrum as? Spectrum)?.clearPlot()
        }
    }

    @objc func spectrumOptionChanged() {
        setupSpectrum()
    }

    @objc(setIgnoreNewline:)
    override func setIgnoreNewline(_ state: Bool) {
        a.view?.setIgnoreNewline(state)
        b.view?.setIgnoreNewline(state)
    }

    @objc(setVisibleState:)
    override func setVisibleState(_ visible: Bool) {
        //  update things in the contest interface
        if contestBar != nil { contestBar?.cancel() }
        if visible == true {
            if contestManager != nil {
                contestManager?.setActiveContestInterface(self)
            }
            //  setup repeating macro bar
            if contestBar != nil { contestBar?.setModem(self) }
            updateContestMacroButtons()
        }
        //  update both configA and configB visibility
        (configA as? DualRTTYConfig)?.updateVisibleState(visible)
        (configB as? DualRTTYConfig)?.updateVisibleState(visible)

        //  v0.78 -- aural monitor
        if a.receiver != nil { a.receiver?.makeReceiverActive(visible) }
        if b.receiver != nil { b.receiver?.makeReceiverActive(visible) }
    }

    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating Dual RTTY sound source")
        a.control?.setupRTTYReceiver()
        b.control?.setupRTTYReceiver()
        setupSpectrum()
        (txConfig as? RTTYTxConfig)?.checkActive()
        (configA as? DualRTTYConfig)?.checkActive()
        (configB as? DualRTTYConfig)?.checkActive()
    }

    @objc(setSentColor:)
    override func setSentColor(_ state: Bool) {
        if (transmitSelect as? NSMatrix)?.selectedColumn == 0 {
            setSentColor(state, view: a.view, textAttribute: a.textAttribute)
        } else {
            setSentColor(state, view: b.view, textAttribute: b.textAttribute)
        }
    }

    @objc func configChannelSelected() -> Int32 {
        guard let tab = configTab as? NSTabView, let item = tab.selectedTabViewItem else { return 0 }
        return Int32(tab.indexOfTabViewItem(item))
    }

    @objc(configObj:)
    override func configObj(_ index: Int32) -> ModemConfig! {
        return (index == 0) ? (configA as? ModemConfig) : (configB as? ModemConfig)
    }

    //  return the input attenuator (NSSlider) of the appropriate receiver bank
    @objc(inputAttenuator:)
    override func inputAttenuator(_ configp: ModemConfig!) -> NSSlider! {
        if (configp as AnyObject) === (configA as AnyObject), a.control != nil {
            return a.control?.inputAttenuator
        }
        if (configp as AnyObject) === (configB as AnyObject), b.control != nil {
            return b.control?.inputAttenuator
        }
        return nil
    }

    @objc(transmitFrom:)
    func transmitFrom(_ index: Int32) {
        transmitChannel = index

        if transmitChannel == 0 {
            a.control?.useAsTransmitTonePair(true)
            b.control?.useAsTransmitTonePair(false)
            (txConfig as? RTTYTxConfig)?.setupTones(from: a.control, lockTone: false)
            currentRxView = a.view
        } else {
            a.control?.useAsTransmitTonePair(false)
            b.control?.useAsTransmitTonePair(true)
            (txConfig as? RTTYTxConfig)?.setupTones(from: b.control, lockTone: false)
            currentRxView = b.view
        }
    }

    @objc(setTextColor:sentColor:backgroundColor:plotColor:forReceiver:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!, forReceiver rx: Int32) {
        if rx == 0 {
            super.setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)
            a.view?.backgroundColor = bgColor
            if let attr = a.control?.textAttribute() { a.view?.setTextColor(inTextColor, attribute: attr) }
            a.control?.setPlotColor(pColor)
        } else {
            b.view?.backgroundColor = bgColor
            if let attr = b.control?.textAttribute() { b.view?.setTextColor(inTextColor, attribute: attr) }
            b.control?.setPlotColor(pColor)
        }
    }

    @objc(setTextColor:sentColor:backgroundColor:plotColor:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!) {
        super.setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)

        a.view?.backgroundColor = bgColor
        b.view?.backgroundColor = bgColor

        if let attr = a.control?.textAttribute() { a.view?.setTextColor(textColor, attribute: attr) }
        if let attr = b.control?.textAttribute() { b.view?.setTextColor(textColor, attribute: attr) }

        a.control?.setPlotColor(plotColor)
        b.control?.setPlotColor(plotColor)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)

        pref.setString("Verdana", forKey: kDualRTTYFontA)
        pref.setFloat(14.0, forKey: kDualRTTYFontSizeA)
        pref.setString("Verdana", forKey: kDualRTTYFontB)
        pref.setFloat(14.0, forKey: kDualRTTYFontSizeB)

        pref.setString("Verdana", forKey: kDualRTTYTxFont)
        pref.setFloat(14.0, forKey: kDualRTTYTxFontSize)

        pref.setInt(1, forKey: kDualRTTYSpectrumRange)
        pref.setInt(1, forKey: kDualRTTYSpectrumChannel)
        pref.setInt(0, forKey: kDualRTTYSpectrumDecay)
        pref.setInt(0, forKey: kDualRTTYTransmitChannel)

        pref.setRed(1.0, green: 0.8, blue: 0.0, forKey: kDualRTTYMainTextColor as String)
        pref.setRed(0.0, green: 0.8, blue: 1.0, forKey: kDualRTTYMainSentColor as String)
        pref.setRed(0.0, green: 0.0, blue: 0.0, forKey: kDualRTTYMainBackgroundColor as String)
        pref.setRed(0.0, green: 1.0, blue: 0.0, forKey: kDualRTTYMainPlotColor as String)
        pref.setRed(1.0, green: 0.8, blue: 0.0, forKey: kDualRTTYSubTextColor as String)
        pref.setRed(0.0, green: 0.8, blue: 1.0, forKey: kDualRTTYSubSentColor as String)
        pref.setRed(0.0, green: 0.0, blue: 0.0, forKey: kDualRTTYSubBackgroundColor as String)
        pref.setRed(0.0, green: 1.0, blue: 0.0, forKey: kDualRTTYSubPlotColor as String)

        (configA as? DualRTTYConfig)?.setupDefaultPreferences(pref, rttyRxControl: a.control)
        (configB as? DualRTTYConfig)?.setupDefaultPreferences(pref, rttyRxControl: b.control)

        for i in Int32(0)..<3 {
            (macroSheet(i) as? RTTYMacros)?.setupDefaultPreferences(pref, option: i)
        }
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        manager?.showSplash("Updating DualRTTY configurations")
        _ = super.updateFromPlist(pref)

        var fontName = pref.stringValue(forKey: kDualRTTYFontA)
        var fontSize = pref.floatValue(forKey: kDualRTTYFontSizeA)
        if let attr = a.control?.textAttribute() { a.view?.setTextFont(fontName ?? "", size: fontSize, attribute: attr) }

        fontName = pref.stringValue(forKey: kDualRTTYFontB)
        fontSize = pref.floatValue(forKey: kDualRTTYFontSizeB)
        if let attr = b.control?.textAttribute() { b.view?.setTextFont(fontName ?? "", size: fontSize, attribute: attr) }

        fontName = pref.stringValue(forKey: kDualRTTYTxFont)
        fontSize = pref.floatValue(forKey: kDualRTTYTxFontSize)
        transmitView?.setTextFont(fontName ?? "", size: fontSize, attribute: transmitTextAttribute!)

        (timeConstant as? NSPopUpButton)?.selectItem(at: Int(pref.intValue(forKey: kDualRTTYSpectrumDecay)))
        (dynamicRange as? NSPopUpButton)?.selectItem(at: Int(pref.intValue(forKey: kDualRTTYSpectrumRange)))
        (channel as? NSPopUpButton)?.selectItem(at: Int(pref.intValue(forKey: kDualRTTYSpectrumChannel)))

        _ = (configA as? DualRTTYConfig)?.updateFromPlist(pref, rttyRxControl: a.control)
        _ = (configB as? DualRTTYConfig)?.updateFromPlist(pref, rttyRxControl: b.control)
        //  check slashed zero key
        useSlashedZero(pref.intValue(forKey: kSlashZeros) != 0)

        //  preferred transmit channel
        let txChannel = pref.intValue(forKey: kDualRTTYTransmitChannel)
        transmitFrom(txChannel)
        (transmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: Int(txChannel))
        (contestTransmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: Int(txChannel))
        transmitSelectChanged()

        plistHasBeenUpdated = true                      //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }      //  v0.53d
        super.retrieveForPlist(pref)

        if let font = a.view?.font {
            pref.setString(font.fontName, forKey: kDualRTTYFontA)
            pref.setFloat(Float(font.pointSize), forKey: kDualRTTYFontSizeA)
        }
        if let font = b.view?.font {
            pref.setString(font.fontName, forKey: kDualRTTYFontB)
            pref.setFloat(Float(font.pointSize), forKey: kDualRTTYFontSizeB)
        }
        if let font = transmitView?.font {
            pref.setString(font.fontName, forKey: kDualRTTYTxFont)
            pref.setFloat(Float(font.pointSize), forKey: kDualRTTYTxFontSize)
        }

        pref.setInt(Int32((timeConstant as? NSPopUpButton)?.indexOfSelectedItem ?? 0), forKey: kDualRTTYSpectrumDecay)
        pref.setInt(Int32((dynamicRange as? NSPopUpButton)?.indexOfSelectedItem ?? 0), forKey: kDualRTTYSpectrumRange)
        pref.setInt(Int32((channel as? NSPopUpButton)?.indexOfSelectedItem ?? 0), forKey: kDualRTTYSpectrumChannel)
        pref.setInt(transmitChannel, forKey: kDualRTTYTransmitChannel)

        (configA as? DualRTTYConfig)?.retrieveForPlist(pref, rttyRxControl: a.control)
        (configB as? DualRTTYConfig)?.retrieveForPlist(pref, rttyRxControl: b.control)
    }

    // ----------------------------------------------------------------

    override func showConfigPanel() {
        //  turn off transmit and open config panel
        if transmitState == true { changeTransmitStateTo(false) }
        (configA as? DualRTTYConfig)?.openPanel()        //  use configA to open the same common panel
        if configChannelSelected() == 0 {
            (configA as? DualRTTYConfig)?.setConfigOpen(true)
        } else {
            (configB as? DualRTTYConfig)?.setConfigOpen(true)
        }
    }

    override func closeConfigPanel() {
        (configA as? DualRTTYConfig)?.closePanel()
        (configB as? DualRTTYConfig)?.closePanel()
    }

    //  waterfall clicked
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    override func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID index: Int32) {
        //  don't allow clicks for this version
        return
        //  (disabled in the original; retained here for reference)
        //  if transmitState { return }
        //  let waterfallChannel = ([channel indexOfSelectedItem] == 0)
        //  let transceiver = waterfallChannel ? a : b
        //  var tonepair = transceiver.control.baseTonePair()
        //  let shift = fabs(tonepair.mark - tonepair.space)
        //  tonepair.mark = freq
        //  tonepair.space = freq + shift
        //  transceiver.control.setTonePair(&tonepair)
    }

    @objc func restoreTonePairs() {
        let waterfallChannel = ((channel as? NSPopUpButton)?.indexOfSelectedItem ?? 0) == 0
        let transceiver = waterfallChannel ? a : b

        transceiver.control?.fetchTonePairFromMemory()
        transceiver.control?.updateTonePairInformation()
    }

    @objc func transmitSelectChanged() {
        let index = (transmitSelect as? NSMatrix)?.selectedColumn ?? 0
        //  move interfaces
        let transceiveBox: NSView?
        let receiveBox: NSView?
        if index == 0 {
            //  receiverA = transceive
            transceiveBox = receiverA as? NSView
            receiveBox = receiverB as? NSView
        } else {
            //  receiverB = transceive
            transceiveBox = receiverB as? NSView
            receiveBox = receiverA as? NSView
        }
        transceiveBox?.frame = transceiveFrame
        receiveBox?.frame = receiveFrame
        (receiverA as? NSView)?.needsDisplay = true
        (receiverB as? NSView)?.needsDisplay = true

        (contestTransmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: index)
        transmitFrom(Int32(index))
    }

    @objc func contestTransmitSelectChanged() {
        let index = (contestTransmitSelect as? NSMatrix)?.selectedColumn ?? 0
        (transmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: index)
        transmitSelectChanged()
        transmitFrom(Int32(index))
    }

    //  delegate of dual RTTY's config window, disable config scopes
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        (configA as? DualRTTYConfig)?.setConfigOpen(false)
        (configB as? DualRTTYConfig)?.setConfigOpen(false)
        return true
    }

    //  delegate to dual RTTY's config panel tab (main/sub receivers)
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let selectA = (tabViewItem != nil) ? (tabView.indexOfTabViewItem(tabViewItem!) == 0) : false
        (configA as? DualRTTYConfig)?.setConfigOpen(selectA)
        (configB as? DualRTTYConfig)?.setConfigOpen(!selectA)
    }

    @objc(changeTransmitStateTo:)
    override func changeTransmitStateTo(_ state: Bool) {
        let index = (transmitSelect as? NSMatrix)?.selectedColumn ?? 0
        let cfg = (index == 0) ? (configA as? DualRTTYConfig) : (configB as? DualRTTYConfig)
        let fsk = cfg?.fsk
        let ook = self.ook(cfg)

        //  transmitType = 0:AFSK, 1:FSK, 2:OOK
        var transmitType: Int32
        if ook != 0 {
            transmitType = 2
        } else {
            if fsk == nil { transmitType = 0 } else { transmitType = ((fsk?.useSelectedPort() ?? 0) <= 0) ? 0 : 1 }
        }
        a.receiver?.rttyAuralMonitor?.setTransmitState(state, transmitType: transmitType)         //  v0.88b
        transmitState = (txConfig as? RTTYTxConfig)?.turnOnTransmission(state,
                                                          button: transmitButton as? NSButton,
                                                          fsk: fsk, ook: cfg?.ook() ?? 0) ?? false //  v0.85
        performSelector(onMainThread: #selector(finishTransmitStateChange), with: nil, waitUntilDone: true) //  v0.65
    }

    //  v0.76 added RTTY Monitor to WFRTTY
    @objc func showScope() {
        a.control?.showMonitor()
    }

    //  ModemManager calls cleanup to all modems when app is terminating.
    //  For Dual RTTY Interface, call both configA and configB
    override func applicationTerminating() {
        (configA as? DualRTTYConfig)?.applicationTerminating()
        (configB as? DualRTTYConfig)?.applicationTerminating()
        ptt?.applicationTerminating()                   //  v0.89
    }

    //  v0.96c
    @objc(selectView:)
    override func selectView(_ index: Int32) {
        var pview: NSView? = nil
        switch index {
        case 1:
            pview = a.control?.view()
        case 2:
            pview = b.control?.view()
        case 0:
            pview = transmitView
        default:
            break
        }
        if let pview = pview {
            pview.window?.makeFirstResponder(pview)
        }
    }
}
