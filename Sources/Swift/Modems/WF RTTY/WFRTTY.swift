//
//  WFRTTY.swift
//  cocoaModem
//
//  Created by Kok Chen on Jan 11 2006.
//  Swift port of WFRTTY.m / WFRTTY.h.
//
//  WFRTTY : RTTYInterface : ContestInterface : MacroInterface : Modem : CMPipe.
//  The two-receiver "Wideband RTTY" waterfall mode tab and the base class of
//  ASCII / LiteRTTY / SITOR / WBCW.  StdManager instantiates it via
//  `WFRTTY(into:manager:)` (@objc selector `initIntoTabView:manager:`), loading
//  the "WFRTTY" nib.
//
//  Port notes:
//   * Every original WFRTTY ivar is an `internal` (or @objc, for the nib-connected
//     `id` outlets) stored property with its EXACT original name, EXCEPT the
//     `WFRTTYConfig *configObj[2]` ivar which collides with the overridden
//     `-configObj:` method (Swift forbids a property and method of the same base
//     name); the STORED array is renamed `configObjs` (the method keeps the
//     `configObj:` selector).  Subclasses in this batch use `configObjs`.
//   * The C struct RTTYConfigSet has NSString* members which the Swift importer
//     maps to Unmanaged<NSString> (see RTTYConfig.swift's cmKey), so it is built
//     in raw memory with the verified LP64 layout (makeWFRTTYConfigSet), exactly
//     as RTTY.swift does.  The key strings are file-scope NSString constants so
//     the unretained pointers copied into the config objects stay valid.
//   * The original split construction (two-arg -initIntoTabView:manager: forwarding
//     to a three-arg -initIntoTabView:manager:nib: workhorse) is collapsed into the
//     single designated `init?(into:manager:)`; the three-arg was only ever called
//     by the two-arg.  Subclasses override `init?(into:manager:)` and reach the
//     plain base nib-loader through `super.init(into:nib:manager:)` — the original
//     WFRTTY workhorse used the DIFFERENT selector `initIntoTabView:manager:nib:`
//     precisely so it did not shadow the base `initIntoTabView:nib:manager:`.
//   * `id` outlets/collaborators are reached through AnyObject optional-chaining
//     message sends (`x?.selector?(...)`); never force-unwrapped (NIL-TOLERANCE).
//   * `isLite` is WFRTTY's own stored property (default false); LiteRTTY sets it
//     true right after super.init.
//

import Cocoa

//  ModemSource.h channel constants
private let LEFTCHANNEL: Int32 = 0
private let RIGHTCHANNEL: Int32 = 1

//  --- Plist keys (Plist.h #define'd @"..." macros; NSString so the unretained
//      pointers stored into RTTYConfigSet stay valid for the life of the app) ---
private let kWFRTTYMainDevice: NSString          = "WFRTTY Input Device A"
private let kWFRTTYSubDevice: NSString           = "WFRTTY Input Device B"
private let kWFRTTYOutputDevice: NSString        = "WFRTTY Output Device"
private let kWFRTTYOutputLevel: NSString         = "WFRTTY Output Sound Level"
private let kWFRTTYOutputAttenuator: NSString    = "WFRTTY Output Attenuator"
private let kWFRTTYMainTone: NSString            = "WFRTTY Main Tone Select"
private let kWFRTTYMainMark: NSString            = "WFRTTY Main Mark Frequencies"
private let kWFRTTYMainSpace: NSString           = "WFRTTY Main Space Frequencies"
private let kWFRTTYMainBaud: NSString            = "WFRTTY Main Baud Rate"
private let kWFRTTYMainControlWindow: NSString   = "WFRTTY Control Window A"
private let kWFRTTYMainSquelch: NSString         = "WFRTTY Squelch A"
private let kWFRTTYMainActive: NSString          = "WFRTTY Active A"
private let kWFRTTYMainStopBits: NSString        = "WFRTTY Stop Bits A"
private let kWFRTTYMainMode: NSString            = "WFRTTY Mode A"
private let kWFRTTYMainRxPolarity: NSString      = "WFRTTY Main Rx Polarity"
private let kWFRTTYMainTxPolarity: NSString      = "WFRTTY Main Tx Polarity"
private let kWFRTTYMainPrefs: NSString           = "WFRTTY Prefs A"
private let kWFRTTYMainTextColor: NSString       = "WFRTTY Text Color 1"
private let kWFRTTYMainSentColor: NSString       = "WFRTTY Sent Color 1"
private let kWFRTTYMainBackgroundColor: NSString = "WFRTTY Background Color 1"
private let kWFRTTYMainPlotColor: NSString       = "WFRTTY Plot Color 1"
private let kWFRTTYMainOffset: NSString          = "WFRTTY Offset A"
private let kWFRTTYMainFSKSelection: NSString    = "WFRTTY FSK Selection A"
private let kWFRTTYMainAuralMonitor: NSString    = "WFRTTY Aural Monitor A"

private let kWFRTTYSubTone: NSString             = "WFRTTY Sub Tone Select"
private let kWFRTTYSubMark: NSString             = "WFRTTY Sub Mark Frequencies"
private let kWFRTTYSubSpace: NSString            = "WFRTTY Sub Space Frequencies"
private let kWFRTTYSubBaud: NSString             = "WFRTTY Sub Baud Rate"
private let kWFRTTYSubControlWindow: NSString    = "WFRTTY Control Window B"
private let kWFRTTYSubSquelch: NSString          = "WFRTTY Squelch B"
private let kWFRTTYSubActive: NSString           = "WFRTTY Active B"
private let kWFRTTYSubStopBits: NSString         = "WFRTTY Stop Bits B"
private let kWFRTTYSubMode: NSString             = "WFRTTY Mode B"
private let kWFRTTYSubRxPolarity: NSString       = "WFRTTY Sub Rx Polarity"
private let kWFRTTYSubTxPolarity: NSString       = "WFRTTY Sub Tx Polarity"
private let kWFRTTYSubPrefs: NSString            = "WFRTTY Prefs B"
private let kWFRTTYSubTextColor: NSString        = "WFRTTY Text Color 2"
private let kWFRTTYSubSentColor: NSString        = "WFRTTY Sent Color 2"
private let kWFRTTYSubBackgroundColor: NSString  = "WFRTTY Background Color 2"
private let kWFRTTYSubPlotColor: NSString        = "WFRTTY Plot Color 2"
private let kWFRTTYSubOffset: NSString           = "WFRTTY Offset B"
private let kWFRTTYSubFSKSelection: NSString     = "WFRTTY FSK Selection B"
private let kWFRTTYSubAuralMonitor: NSString     = "WFRTTY Aural Monitor B"

private let kWFRTTYFontA          = "WFRTTY Font A"
private let kWFRTTYFontSizeA      = "WFRTTY Font Size A"
private let kWFRTTYFontB          = "WFRTTY Font B"
private let kWFRTTYFontSizeB      = "WFRTTY Font Size B"
private let kWFRTTYTxFont         = "WFRTTY Tx Font"
private let kWFRTTYTxFontSize     = "WFRTTY Tx Font Size"
private let kRTTYMainWaterfallNR  = "RTTY Waterfall Noise Reduction A"
private let kRTTYSubWaterfallNR   = "RTTY Waterfall Noise Reduction B"
private let kWFRTTYTransmitChannel = "WFRTTY TransmitChannel"
private let kWFRTTYLockA          = "WFRTTY Transmit Lock A"
private let kWFRTTYLockB          = "WFRTTY Transmit Lock B"
private let kSlashZeros           = "Null for Zero"

//  ---------------------------------------------------------------------------
//  RTTYConfigSet builder (verified LP64 layout, matching RTTY.swift):
//     int channel        @0
//     NSString* [22]     @8,16, ... 176   (inputDevice ... fskSelection)
//     Boolean usesAural  @184
//     NSString* aural    @192
//     sizeof == 200
//  Returns a typed pointer; the caller must .deallocate() it after the
//  -awakeFromModem: calls have copied the struct out.
//  ---------------------------------------------------------------------------
private let kRTTYConfigSetSize = 200

func makeWFRTTYConfigSet(channel: Int32, _ fields: [NSString?],
                         usesRTTYAuralMonitor: Bool, auralMonitor: NSString?) -> UnsafeMutablePointer<RTTYConfigSet> {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: kRTTYConfigSetSize, alignment: 8)
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: kRTTYConfigSetSize)
    raw.storeBytes(of: channel, toByteOffset: 0, as: Int32.self)
    for (i, s) in fields.enumerated() {
        let bits = s.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        raw.storeBytes(of: bits, toByteOffset: 8 &+ i &* 8, as: UInt.self)
    }
    raw.storeBytes(of: usesRTTYAuralMonitor ? UInt8(1) : UInt8(0), toByteOffset: 184, as: UInt8.self)
    let ab = auralMonitor.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
    raw.storeBytes(of: ab, toByteOffset: 192, as: UInt.self)
    return raw.assumingMemoryBound(to: RTTYConfigSet.self)
}

@objc(WFRTTY)
class WFRTTY: RTTYInterface {

    //  --- IBOutlets (id) ---
    @objc var groupA: AnyObject!
    @objc var waterfallA: AnyObject!
    @objc var receiverA: AnyObject!
    @objc var configA: AnyObject!
    @objc var restoreToneA: AnyObject!
    @objc var dynamicRangeA: AnyObject!

    @objc var groupB: AnyObject!
    @objc var waterfallB: AnyObject!
    @objc var receiverB: AnyObject!
    @objc var configB: AnyObject!
    @objc var restoreToneB: AnyObject!
    @objc var dynamicRangeB: AnyObject!

    @objc var configTab: AnyObject!
    @objc var transmitSelect: AnyObject!
    @objc var transmitLock: AnyObject!
    @objc var contestTransmitSelect: AnyObject!

    //  isLite belongs to WFRTTY; LiteRTTY sets it true after super.init
    internal var isLite: Bool = false

    internal var waterfall = [AnyObject?](repeating: nil, count: 2)
    internal var control = [RTTYRxControl?](repeating: nil, count: 2)
    //  renamed from the original `configObj` array (collides with -configObj:)
    internal var configObjs = [AnyObject?](repeating: nil, count: 2)
    internal var txLocked = [Bool](repeating: false, count: 2)

    internal var receiveFrame = NSRect.zero      //  frame of receive-only receiver
    internal var transceiveFrame = NSRect.zero   //  frame of receive-transmit receiver

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    //  Forward the nib-loading designated init so ASCII / LiteRTTY / SITOR / WBCW
    //  can pass their own nib name up through WFRTTY (see RTTYInterface note).
    override init?(into tabview: NSTabView!, nib: String!, manager mgr: ModemManager!) {
        super.init(into: tabview, nib: nib, manager: mgr)
    }

    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr?.showSplash("Creating Wideband RTTY Modem")
        super.init(into: tabview, nib: "WFRTTY", manager: mgr)
        isLite = false
        manager = mgr
        setupReceivers()
    }

    //  the former -initIntoTabView:manager:nib: workhorse body (WFRTTY only)
    private func setupReceivers() {
        let ellipseFatness: Float = 0.9

        let setA = makeWFRTTYConfigSet(channel: LEFTCHANNEL,
            [ kWFRTTYMainDevice, kWFRTTYOutputDevice, kWFRTTYOutputLevel, kWFRTTYOutputAttenuator,
              kWFRTTYMainTone, kWFRTTYMainMark, kWFRTTYMainSpace, kWFRTTYMainBaud, kWFRTTYMainControlWindow,
              kWFRTTYMainSquelch, kWFRTTYMainActive, kWFRTTYMainStopBits, kWFRTTYMainMode, kWFRTTYMainRxPolarity,
              kWFRTTYMainTxPolarity, kWFRTTYMainPrefs, kWFRTTYMainTextColor, kWFRTTYMainSentColor,
              kWFRTTYMainBackgroundColor, kWFRTTYMainPlotColor, kWFRTTYMainOffset, kWFRTTYMainFSKSelection ],
            usesRTTYAuralMonitor: true, auralMonitor: kWFRTTYMainAuralMonitor)

        let setB = makeWFRTTYConfigSet(channel: RIGHTCHANNEL,
            [ kWFRTTYSubDevice, nil, nil, nil,
              kWFRTTYSubTone, kWFRTTYSubMark, kWFRTTYSubSpace, kWFRTTYSubBaud, kWFRTTYSubControlWindow,
              kWFRTTYSubSquelch, kWFRTTYSubActive, kWFRTTYSubStopBits, kWFRTTYSubMode, kWFRTTYSubRxPolarity,
              kWFRTTYSubTxPolarity, kWFRTTYSubPrefs, kWFRTTYSubTextColor, kWFRTTYSubSentColor,
              kWFRTTYSubBackgroundColor, kWFRTTYSubPlotColor, kWFRTTYSubOffset, kWFRTTYSubFSKSelection ],
            usesRTTYAuralMonitor: true, auralMonitor: kWFRTTYSubAuralMonitor)

        //  initialize txConfig before rxConfigs (rttyRxControls undefined here)
        (txConfig as AnyObject?)?.awakeFromModem?(setA, rttyRxControl: nil)
        ptt = (txConfig as? RTTYTxConfig)?.pttObject()

        //  --- main receiver (a) ---
        a.isAlive = true
        a.control = RTTYRxControl(intoView: receiverA as? NSView, client: self, index: 0)
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
        control[0] = a.control
        configObjs[0] = configA
        txLocked[0] = false

        //  v0.78
        (txConfig as? RTTYTxConfig)?.setRTTYAuralMonitor(a.receiver?.rttyAuralMonitor)

        if let ctrl = a.control {
            var tonepair = ctrl.baseTonePair()
            (waterfallA as AnyObject?)?.setTonePairMarker?(&tonepair, index: 0)
        }

        //  --- sub receiver (b) ---
        b.isAlive = true
        b.control = RTTYRxControl(intoView: receiverB as? NSView, client: self, index: 1)
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
            (waterfallB as AnyObject?)?.setTonePairMarker?(&tonepair, index: 1)
        }

        (configTab as AnyObject?)?.setValue(self, forKey: "delegate")

        //  AppleScript text callback
        a.receiver?.registerModule(transceiver1?.receiver())
        a.transmitModule = transceiver1?.transmitter()
        if !isLite {
            b.receiver?.registerModule(transceiver2?.receiver())
            b.transmitModule = transceiver2?.transmitter()
        }

        setA.deallocate()
        setB.deallocate()
    }

    //  v0.83  common to WFRTTY, SITOR and WBCW
    @objc func commonAwakeFromNib() {
        awakeFromContest()
        //  use QSO transmitview
        (contestTab as? NSTabView)?.selectTabViewItem(at: 0)

        initCallsign()
        initColors()
        //  application will set our macros to single RTTY macros ... initMacros()

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
            if let w = waterfall[i] {
                w.awakeFromModem?()
                w.enableIndicator?(self)
                w.setWaterfallID?(Int32(i))
                w.setFFTDelegate?(self)
            }
        }

        //  actions
        if transmitButton != nil { setInterface(transmitButton as? NSControl, to: #selector(transmitButtonChanged)) }
        if transmitSelect != nil { setInterface(transmitSelect as? NSControl, to: #selector(transmitSelectChanged)) }
        if contestTransmitSelect != nil { setInterface(contestTransmitSelect as? NSControl, to: #selector(contestTransmitSelectChanged)) }
        setInterface(restoreToneA as? NSControl, to: #selector(restoreTone(_:)))
        setInterface(restoreToneB as? NSControl, to: #selector(restoreTone(_:)))
        setInterface(dynamicRangeA as? NSControl, to: #selector(dynamicRangeChanged(_:)))
        setInterface(dynamicRangeB as? NSControl, to: #selector(dynamicRangeChanged(_:)))
        setInterface(transmitLock as? NSControl, to: #selector(txLockChanged))
    }

    override func awakeFromNib() {
        ident = isLite ? NSLocalizedString("RTTY", comment: "") : NSLocalizedString("Wideband RTTY", comment: "")
        commonAwakeFromNib()
    }

    //  v0.89  also called from AppleScript
    @objc override func flushClickBuffer() {
        a.receiver?.clearClickBuffer()
        if b.isAlive { b.receiver?.clearClickBuffer() }
    }

    //  ModemManager calls this when the app is terminating.  For a two-config
    //  modem call both configA and configB.
    @objc override func applicationTerminating() {
        (configA as AnyObject?)?.applicationTerminating?()
        (configB as AnyObject?)?.applicationTerminating?()
        ptt?.applicationTerminating()               //  v0.89
    }

    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    //  v0.87  switchModemIn for a modem with two configs
    @objc override func switchModemIn() {
        (configA as AnyObject?)?.setKeyerMode?()
        (configB as AnyObject?)?.setKeyerMode?()
    }

    @objc(setupSpectrum)
    func setupSpectrum() {
        for i in 0..<2 {
            if waterfall[i] != nil { control[i]?.setWaterfall(waterfall[i] as? RTTYWaterfall) }
        }
    }

    //  v1.02b
    @objc(directSetFrequency:)
    override func directSetFrequency(_ freq: Float) {
        clicked(freq, secondsAgo: 0.0, option: false, fromWaterfall: false, waterfallID: 0)
    }

    //  v1.02b
    @objc override func selectedFrequency() -> Float {
        guard let ctrl = control[0] else { return 0.0 }
        return Float(ctrl.rxTonePair().mark)
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
        //  v0.78 to turn AuralMonitor on and off
        a.receiver?.makeReceiverActive(visible)
        b.receiver?.makeReceiverActive(visible)
    }

    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating Wideband RTTY sound source")
        a.control?.setupRTTYReceiver()
        b.control?.setupRTTYReceiver()
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
    func configChannelSelected() -> Int32 {
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

    @objc(transmitFrom:)
    func transmitFrom(_ index: Int32) {
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

    @objc(setIgnoreNewline:)
    override func setIgnoreNewline(_ state: Bool) {
        (a.view as AnyObject?)?.setIgnoreNewline?(state)
        (b.view as AnyObject?)?.setIgnoreNewline?(state)
    }

    @objc(transmitIsLocked:)
    func transmitIsLocked(_ index: Int32) -> Bool {
        let cell = (transmitLock as? NSMatrix)?.cell(atRow: 0, column: Int(index)) as? NSCell
        return cell?.state == .on
    }

    //  v0.88b
    @objc(changeTransmitStateTo:)
    override func changeTransmitStateTo(_ state: Bool) {
        if state {
            let txFixed = transmitIsLocked(transmitChannel)
            //  if transmit tones are locked, set transmit with locked tone
            (txConfig as? RTTYTxConfig)?.setupTones(from: control[Int(transmitChannel)], lockTone: txFixed)
        }
        let index = (transmitSelect as? NSMatrix)?.selectedColumn ?? 0
        let cfg: AnyObject? = (index == 0) ? configA : configB
        let fsk = (cfg as AnyObject?)?.fsk as? FSK
        let ookValue = ook(cfg as? RTTYConfig)

        //  transmitType = 0:AFSK, 1:FSK, 2:OOK
        var transmitType: Int32
        if ookValue != 0 {
            transmitType = 2
        } else {
            if fsk == nil { transmitType = 0 } else { transmitType = ((fsk?.useSelectedPort() ?? 0) <= 0) ? 0 : 1 }
        }
        a.receiver?.rttyAuralMonitor?.setTransmitState(state, transmitType: transmitType)     //  v0.88b

        transmitState = (txConfig as? RTTYTxConfig)?.turnOnTransmission(state, button: transmitButton as? NSButton, fsk: fsk, ook: ookValue) ?? false   //  v0.85
        performSelector(onMainThread: #selector(RTTYInterface.finishTransmitStateChange), with: nil, waitUntilDone: true)    //  v0.65
    }

    //  v0.88  original -changeTransmitStateTo for WBCW
    @objc(changeNonAuralTransmitStateTo:)
    func changeNonAuralTransmitStateTo(_ state: Bool) {
        if state {
            let txFixed = transmitIsLocked(transmitChannel)
            (txConfig as? RTTYTxConfig)?.setupTones(from: control[Int(transmitChannel)], lockTone: txFixed)
        }
        let index = (transmitSelect as? NSMatrix)?.selectedColumn ?? 0
        let cfg: AnyObject? = (index == 0) ? configA : configB
        let fsk = (cfg as AnyObject?)?.fsk as? FSK

        transmitState = (txConfig as? RTTYTxConfig)?.turnOnTransmission(state, button: transmitButton as? NSButton, fsk: fsk, ook: ook(cfg as? RTTYConfig)) ?? false   //  v0.85
        performSelector(onMainThread: #selector(RTTYInterface.finishTransmitStateChange), with: nil, waitUntilDone: true)    //  v0.65
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
        super.setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)
        (a.view as AnyObject?)?.setBackgroundColor?(bgColor)
        (b.view as AnyObject?)?.setBackgroundColor?(bgColor)
        a.view?.setTextColor(textColor, attribute: a.control!.textAttribute())
        b.view?.setTextColor(textColor, attribute: b.control!.textAttribute())
        a.control?.setPlotColor(plotColor)
        b.control?.setPlotColor(plotColor)
    }

    @objc(setupDefaultPreferencesFromSuper:)
    func setupDefaultPreferencesFromSuper(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)

        pref?.setString("Verdana", forKey: kWFRTTYFontA)
        pref?.setFloat(14.0, forKey: kWFRTTYFontSizeA)
        pref?.setString("Verdana", forKey: kWFRTTYFontB)
        pref?.setFloat(14.0, forKey: kWFRTTYFontSizeB)

        pref?.setString("Verdana", forKey: kWFRTTYTxFont)
        pref?.setFloat(14.0, forKey: kWFRTTYTxFontSize)
        pref?.setInt(1, forKey: kRTTYMainWaterfallNR)
        pref?.setInt(1, forKey: kRTTYSubWaterfallNR)

        pref?.setInt(0, forKey: kWFRTTYTransmitChannel)
        pref?.setInt(0, forKey: kWFRTTYLockA)
        pref?.setInt(0, forKey: kWFRTTYLockB)

        pref?.setRed(1.0, green: 0.8, blue: 0.0, forKey: kWFRTTYMainTextColor as String)
        pref?.setRed(0.0, green: 0.8, blue: 1.0, forKey: kWFRTTYMainSentColor as String)
        pref?.setRed(0.0, green: 0.0, blue: 0.0, forKey: kWFRTTYMainBackgroundColor as String)
        pref?.setRed(0.0, green: 1.0, blue: 0.0, forKey: kWFRTTYMainPlotColor as String)
        pref?.setRed(1.0, green: 0.8, blue: 0.0, forKey: kWFRTTYSubTextColor as String)
        pref?.setRed(0.0, green: 0.8, blue: 1.0, forKey: kWFRTTYSubSentColor as String)
        pref?.setRed(0.0, green: 0.0, blue: 0.0, forKey: kWFRTTYSubBackgroundColor as String)
        pref?.setRed(0.0, green: 1.0, blue: 0.0, forKey: kWFRTTYSubPlotColor as String)

        (configA as AnyObject?)?.setupDefaultPreferences?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.setupDefaultPreferences?(pref, rttyRxControl: b.control)

        for i in 0..<3 {
            if let sheet = macroSheet[i] { (sheet as? RTTYMacros)?.setupDefaultPreferences(pref, option: Int32(i)) }
        }
    }

    @objc(updateFromPlistFromSuper:)
    func updateFromPlistFromSuper(_ pref: Preferences!) -> Bool {
        return super.updateFromPlist(pref)
    }

    //  disable transmit lock buttons if FSK is used
    @objc(afskChanged:config:)
    override func afskChanged(_ order: Int32, config cfg: RTTYConfig!) {
        let index = ((cfg as AnyObject?) === (configA as AnyObject?)) ? 0 : 1
        ((transmitLock as? NSMatrix)?.cell(atRow: 0, column: index) as? NSCell)?.isEnabled = (order == 0)
    }

    @objc(setTransmitLockButton:toState:)
    func setTransmitLockButton(_ index: Int32, toState locked: Bool) {
        ((transmitLock as? NSMatrix)?.cell(atRow: 0, column: Int(index)) as? NSCell)?.state = locked ? .on : .off
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = super.updateFromPlist(pref)

        var fontName = pref?.stringValue(forKey: kWFRTTYFontA)
        var fontSize = pref?.floatValue(forKey: kWFRTTYFontSizeA) ?? 0
        a.view?.setTextFont(fontName ?? "", size: fontSize, attribute: a.control!.textAttribute())

        fontName = pref?.stringValue(forKey: kWFRTTYFontB)
        fontSize = pref?.floatValue(forKey: kWFRTTYFontSizeB) ?? 0
        b.view?.setTextFont(fontName ?? "", size: fontSize, attribute: b.control!.textAttribute())

        fontName = pref?.stringValue(forKey: kWFRTTYTxFont)
        fontSize = pref?.floatValue(forKey: kWFRTTYTxFontSize) ?? 0
        transmitView?.setTextFont(fontName ?? "", size: fontSize, attribute: transmitTextAttribute!)

        let txChannel = pref?.intValue(forKey: kWFRTTYTransmitChannel) ?? 0
        transmitFrom(txChannel)
        (transmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: Int(txChannel))
        (contestTransmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: Int(txChannel))
        //  update visual interfaces
        transmitSelectChanged()

        var locked = (pref?.intValue(forKey: kWFRTTYLockA) ?? 0) != 0
        setTransmitLockButton(0, toState: locked)
        control[0]?.setTransmitLock(locked)
        txLocked[0] = locked

        locked = (pref?.intValue(forKey: kWFRTTYLockB) ?? 0) != 0
        setTransmitLockButton(1, toState: locked)
        control[1]?.setTransmitLock(locked)
        txLocked[1] = locked

        //  v0.73
        (waterfallA as AnyObject?)?.setNoiseReductionState?((pref?.intValue(forKey: kRTTYMainWaterfallNR) ?? 0) != 0)
        (waterfallB as AnyObject?)?.setNoiseReductionState?((pref?.intValue(forKey: kRTTYSubWaterfallNR) ?? 0) != 0)

        manager?.showSplash("Updating WFRTTY configurations")
        (configA as AnyObject?)?.updateFromPlist?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.updateFromPlist?(pref, rttyRxControl: b.control)
        //  check slashed zero key
        useSlashedZero((pref?.intValue(forKey: kSlashZeros) ?? 0) != 0)

        plistHasBeenUpdated = true                  //  v0.53d
        return true
    }

    @objc(retrieveForPlistFromSuper:)
    func retrieveForPlistFromSuper(_ pref: Preferences!) {
        super.retrieveForPlist(pref)
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }      //  v0.53d

        super.retrieveForPlist(pref)

        if ((NSApp.delegate as AnyObject?)?.isLite?() ?? false) == false {    //  v0.64d don't play with fonts of Lite window
            var font = a.view?.font
            pref?.setString(font?.fontName, forKey: kWFRTTYFontA)
            pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kWFRTTYFontSizeA)
            font = b.view?.font
            pref?.setString(font?.fontName, forKey: kWFRTTYFontB)
            pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kWFRTTYFontSizeB)

            font = transmitView?.font
            pref?.setString(font?.fontName, forKey: kWFRTTYTxFont)
            pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kWFRTTYTxFontSize)
        }

        pref?.setInt(transmitChannel, forKey: kWFRTTYTransmitChannel)

        pref?.setInt(transmitIsLocked(0) ? 1 : 0, forKey: kWFRTTYLockA)
        pref?.setInt(transmitIsLocked(1) ? 1 : 0, forKey: kWFRTTYLockB)

        //  v0.73
        pref?.setInt(((waterfallA as AnyObject?)?.noiseReductionState?() ?? false) ? 1 : 0, forKey: kRTTYMainWaterfallNR)
        pref?.setInt(((waterfallB as AnyObject?)?.noiseReductionState?() ?? false) ? 1 : 0, forKey: kRTTYSubWaterfallNR)

        (configA as AnyObject?)?.retrieveForPlist?(pref, rttyRxControl: a.control)
        (configB as AnyObject?)?.retrieveForPlist?(pref, rttyRxControl: b.control)
    }

    // ----------------------------------------------------------------

    @objc(showConfigPanel)
    override func showConfigPanel() {
        //  turn off transmit and open config panel
        if transmitState == true { changeTransmitStateTo(false) }
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
        let channel = ((ctrl as AnyObject?) === (control[0] as AnyObject?)) ? 0 : 1
        let sideband = ctrl?.sideband_() ?? 0
        var tonepair = txLocked[channel] ? (ctrl?.lockedTxTonePair() ?? CMTonePair()) : (ctrl?.baseTonePair() ?? CMTonePair())

        if let w = waterfall[channel] {
            w.setSideband?(sideband)
            w.setTonePairMarker?(&tonepair, index: Int32(channel))
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

    //  v0.64e -- set click history from AppleScript
    @objc(setTimeOffset:index:)
    override func setTimeOffset(_ timeOffset: Float, index: Int32) {
        if transmitState == false {
            let ctrl = control[Int(index) & 1]
            ctrl?.receiver_()?.clicked(timeOffset)
        }
    }

    //  waterfall clicked
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    override func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID waterfallChannel: Int32) {
        if (txConfig as? RTTYTxConfig)?.transmitActive() == true { return }     //  don't obey clicks when transmitting

        let ch = Int(waterfallChannel & 1)
        guard let ctrl = control[ch] else { return }
        var rxTonepair = ctrl.baseTonePair()
        let shift = Double(abs(Float(rxTonepair.mark) - Float(rxTonepair.space)))
        let delta = Double(freq) - rxTonepair.mark
        let sideband = ctrl.sideband_()

        if option {
            //  control clicked
            (ctrl as AnyObject?)?.setRIT?(Float(delta))
            return
        }

        //  clear RIT if not control clicked
        (ctrl as AnyObject?)?.setRIT?(0.0)
        if sideband == 0 {
            rxTonepair.mark = Double(freq)
            rxTonepair.space = Double(freq) + shift
        } else {
            rxTonepair.mark = Double(freq) - shift
            rxTonepair.space = Double(freq)
        }
        (ctrl as AnyObject?)?.setTonePair?(&rxTonepair)

        if acquire {
            ctrl.receiver_()?.clicked(secs)
        }
        (NSApp.delegate as? AppDelegate)?.application()?.setDirectFrequencyFieldTo(freq)
    }

    @objc func txLockChanged() {
        for channel in 0..<2 {
            let wasLocked = txLocked[channel]
            guard let ctrl = control[channel] else { continue }
            let nowLocked = transmitIsLocked(Int32(channel))
            txLocked[channel] = nowLocked
            ctrl.setTransmitLock(nowLocked)
            if wasLocked != nowLocked {
                control[channel]?.setTransmitLock(nowLocked)
                var tonepair = ctrl.baseTonePair()
                if let w = waterfall[channel] { w.setTonePairMarker?(&tonepair, index: Int32(channel)) }
                if nowLocked {
                    //  show the locked Tx Tone pair
                    tonepair = ctrl.lockedTxTonePair()
                } else {
                    //  lock tx to rx
                    tonepair.mark = 0; tonepair.space = 0
                }
                if let w = waterfall[channel] { w.setTransmitTonePairMarker?(&tonepair, index: Int32(channel)) }
            }
        }
    }

    @objc(restoreTone:)
    func restoreTone(_ sender: Any!) {
        let transceiver = ((sender as AnyObject?) === (restoreToneA as AnyObject?)) ? a : b
        (transceiver.control as AnyObject?)?.setRIT?(0.0)
        (transceiver.control as AnyObject?)?.fetchTonePairFromMemory?()
        (transceiver.control as AnyObject?)?.updateTonePairInformation?()    //  resets tone to memory settings
    }

    @objc(dynamicRangeChanged:)
    func dynamicRangeChanged(_ sender: Any!) {
        let w = ((sender as AnyObject?) === (dynamicRangeA as AnyObject?)) ? waterfall[0] : waterfall[1]
        let tag = (sender as? NSPopUpButton)?.selectedItem?.tag ?? 0
        (w as AnyObject?)?.setDynamicRange?(Float(tag) * 1.0)
    }

    @objc func transmitSelectChanged() {
        let index = (transmitSelect as? NSMatrix)?.selectedColumn ?? 0

        //  move interfaces
        let transceiveBox: AnyObject?
        let receiveBox: AnyObject?
        if index == 0 {
            //  receiverA = transceive
            transceiveBox = groupA
            receiveBox = groupB
        } else {
            //  receiverB = transceive
            transceiveBox = groupB
            receiveBox = groupA
        }
        (transceiveBox as? NSView)?.frame = transceiveFrame
        (groupA as? NSView)?.needsDisplay = true

        if !isLite {
            (receiveBox as? NSView)?.frame = receiveFrame
            (groupB as? NSView)?.needsDisplay = true
        }

        (contestTransmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: index)
        transmitFrom(Int32(index))
    }

    @objc func contestTransmitSelectChanged() {
        let index = (contestTransmitSelect as? NSMatrix)?.selectedColumn ?? 0
        (transmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: index)
        transmitSelectChanged()
        transmitFrom(Int32(index))
    }

    //  delegate of WF RTTY's config window, disable config scopes
    @objc(windowShouldClose:)
    func windowShouldClose(_ sender: Any!) -> Bool {
        (configA as AnyObject?)?.setConfigOpen?(false)
        (configB as AnyObject?)?.setConfigOpen?(false)
        return true
    }

    //  delegate to WF RTTY's config panel tab (main/sub receivers)
    @objc(tabView:didSelectTabViewItem:)
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let selectA = (tabViewItem != nil) && (tabView.indexOfTabViewItem(tabViewItem!) == 0)
        (configA as AnyObject?)?.setConfigOpen?(selectA)
        (configB as AnyObject?)?.setConfigOpen?(!selectA)
    }

    //  v0.76 added RTTY Monitor to WFRTTY
    @objc(showScope)
    func showScope() {
        (a.control as AnyObject?)?.showMonitor?()
    }

    //  v0.96c
    @objc(selectView:)
    override func selectView(_ index: Int32) {
        var pview: NSView?
        switch index {
        case 1:
            pview = a.control?.view()
        case 2:
            pview = b.control?.view()
        case 0:
            pview = transmitView
        default:
            pview = nil
        }
        if let pview = pview { pview.window?.makeFirstResponder(pview) }
    }
}
