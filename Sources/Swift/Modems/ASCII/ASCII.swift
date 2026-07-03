//
//  ASCII.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/28/10.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of ASCII.m / ASCII.h.  ASCII : WFRTTY : RTTYInterface :
//  ContestInterface : MacroInterface : Modem : CMPipe.  ASCII is the 7/8-bit
//  ASCII-RTTY mode tab and the base class of LiteASCII.
//
//  Port notes:
//   * StdManager instantiates the mode with `ASCII(into:manager:)`
//     (@objc selector `initIntoTabView:manager:`), loading the "ASCII" nib.
//   * The Objective-C original split construction across a two-arg
//     -initIntoTabView:manager: and a three-arg
//     -initIntoTabView:manager:nib: workhorse (the two-arg only supplied the
//     nib name and forwarded to the three-arg).  Because the three-arg was
//     never called from anywhere else, the two are collapsed here into the
//     single designated `init?(into:manager:)` (matching the shipped SynchAM
//     pattern) whose body is the former three-arg body.
//   * All original ASCII ivars are `@objc var` with their exact names.
//   * `id` IBOutlets (declared in WFRTTY as `id`) are reached through AnyObject
//     optional-chaining message sends; never force-unwrapped.
//   * Text-view / tab-view delegate wiring is done with KVC
//     (`setValue(_:forKey:"delegate")`) so it does not depend on where in the
//     RTTYInterface/WFRTTY hierarchy the NSTextViewDelegate/NSTabViewDelegate
//     conformance is declared; the delegate callbacks are @objc and dispatch by
//     selector at runtime exactly as in the MRC original.
//

import Cocoa

//  Channel constants (ModemSource.h: #define LEFTCHANNEL 0 / RIGHTCHANNEL 1)
private let LEFTCHANNEL: Int32 = 0
private let RIGHTCHANNEL: Int32 = 1

//  --- Plist keys (Plist.h #define'd @"..." macros, invisible to Swift) ---
private let kASCIIMainDevice          = "ASCII Input Device A"
private let kASCIISubDevice           = "ASCII Input Device B"
private let kASCIIOutputDevice        = "ASCII Output Device"
private let kASCIIOutputLevel         = "ASCII Output Sound Level"
private let kASCIIOutputAttenuator    = "ASCII Output Attenuator"
private let kASCIIMainTone            = "ASCII Main Tone Select"
private let kASCIIMainMark            = "ASCII Main Mark Frequencies"
private let kASCIIMainSpace           = "ASCII Main Space Frequencies"
private let kASCIIMainBaud            = "ASCII Main Baud Rate"
private let kASCIIMainControlWindow   = "ASCII Control Window A"
private let kASCIIMainSquelch         = "ASCII Squelch A"
private let kASCIIMainActive          = "ASCII Active A"
private let kASCIIMainStopBits        = "ASCII Stop Bits A"
private let kASCIIMainMode            = "ASCII Mode A"
private let kASCIIMainRxPolarity      = "ASCII Main Rx Polarity"
private let kASCIIMainTxPolarity      = "ASCII Main Tx Polarity"
private let kASCIIMainPrefs           = "ASCII Prefs A"
private let kASCIIMainTextColor       = "ASCII Text Color 1"
private let kASCIIMainSentColor       = "ASCII Sent Color 1"
private let kASCIIMainBackgroundColor = "ASCII Background Color 1"
private let kASCIIMainPlotColor       = "ASCII Plot Color 1"
private let kASCIIMainOffset          = "ASCII Offset A"
private let kASCIIMainFSKSelection    = "ASCII FSK Selection A"
private let kASCIIMainAuralMonitor    = "ASCII Aural Monitor A"

private let kASCIISubTone             = "ASCII Sub Tone Select"
private let kASCIISubMark             = "ASCII Sub Mark Frequencies"
private let kASCIISubSpace            = "ASCII Sub Space Frequencies"
private let kASCIISubBaud             = "ASCII Sub Baud Rate"
private let kASCIISubControlWindow    = "ASCII Control Window B"
private let kASCIISubSquelch          = "ASCII Squelch B"
private let kASCIISubActive           = "ASCII Active B"
private let kASCIISubStopBits         = "ASCII Stop Bits B"
private let kASCIISubMode             = "ASCII Mode B"
private let kASCIISubRxPolarity       = "ASCII Sub Rx Polarity"
private let kASCIISubTxPolarity       = "ASCII Sub Tx Polarity"
private let kASCIISubPrefs            = "ASCII Prefs B"
private let kASCIISubTextColor        = "ASCII Text Color 2"
private let kASCIISubSentColor        = "ASCII Sent Color 2"
private let kASCIISubBackgroundColor  = "ASCII Background Color 2"
private let kASCIISubPlotColor        = "ASCII Plot Color 2"
private let kASCIISubOffset           = "ASCII Offset B"
private let kASCIISubFSKSelection     = "ASCII FSK Selection B"
private let kASCIISubAuralMonitor     = "ASCII Aural Monitor B"

private let kASCIIFontA               = "ASCII Font A"
private let kASCIIFontSizeA           = "ASCII Font Size A"
private let kASCIIFontB               = "ASCII Font B"
private let kASCIIFontSizeB           = "ASCII Font Size B"
private let kASCIITxFont              = "ASCII Tx Font"
private let kASCIITxFontSize          = "ASCII Tx Font Size"
private let kASCIIMainWaterfallNR     = "ASCII Waterfall Noise Reduction A"
private let kASCIISubWaterfallNR      = "ASCII Waterfall Noise Reduction B"
private let kASCIIBitsPerCharacter    = "ASCII BitsPerCharacter"
private let kASCIITransmitChannel     = "ASCII TransmitChannel"
private let kASCIILockA               = "ASCII Transmit Lock A"
private let kASCIILockB               = "ASCII Transmit Lock B"

private let kSlashZeros               = "Null for Zero"

@objc(ASCII)
class ASCII: WFRTTY {

    //  --- ASCII ivars (exact names) ---
    @objc var dataBits: AnyObject!                  //  IBOutlet id
    @objc var hardLimitForBackspace: Int32 = 0

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    //  Forward the nib-loading designated init so LiteASCII can pass its nib.
    override init?(into tabview: NSTabView!, nib: String!, manager mgr: ModemManager!) {
        super.init(into: tabview, nib: nib, manager: mgr)
    }

    //  ASCII : WFRTTY -- loads the "ASCII" nib.  (Merges the original two-arg
    //  -initIntoTabView:manager: and its three-arg workhorse.)
    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        //  (was the two-arg initIntoTabView:manager: preamble)
        mgr?.showSplash("Creating ASCII Modem")

        super.init(into: tabview, nib: "ASCII", manager: mgr)

        //  isLite is a WFRTTY (super) property — must be set after super.init.
        isLite = false

        //  ---- former -initIntoTabView:manager:nib: body ----
        let ellipseFatness: Float = 0.9

        var setA = RTTYConfigSet()
        setA.channel = LEFTCHANNEL
        setA.inputDevice = cmConfigKey(kASCIIMainDevice)
        setA.outputDevice = cmConfigKey(kASCIIOutputDevice)
        setA.outputLevel = cmConfigKey(kASCIIOutputLevel)
        setA.outputAttenuator = cmConfigKey(kASCIIOutputAttenuator)
        setA.tone = cmConfigKey(kASCIIMainTone)
        setA.mark = cmConfigKey(kASCIIMainMark)
        setA.space = cmConfigKey(kASCIIMainSpace)
        setA.baud = cmConfigKey(kASCIIMainBaud)
        setA.controlWindow = cmConfigKey(kASCIIMainControlWindow)
        setA.squelch = cmConfigKey(kASCIIMainSquelch)
        setA.active = cmConfigKey(kASCIIMainActive)
        setA.stopBits = cmConfigKey(kASCIIMainStopBits)
        setA.sideband = cmConfigKey(kASCIIMainMode)
        setA.rxPolarity = cmConfigKey(kASCIIMainRxPolarity)
        setA.txPolarity = cmConfigKey(kASCIIMainTxPolarity)
        setA.prefs = cmConfigKey(kASCIIMainPrefs)
        setA.textColor = cmConfigKey(kASCIIMainTextColor)
        setA.sentColor = cmConfigKey(kASCIIMainSentColor)
        setA.backgroundColor = cmConfigKey(kASCIIMainBackgroundColor)
        setA.plotColor = cmConfigKey(kASCIIMainPlotColor)
        setA.vfoOffset = cmConfigKey(kASCIIMainOffset)
        setA.fskSelection = cmConfigKey(kASCIIMainFSKSelection)
        setA.usesRTTYAuralMonitor = true
        setA.auralMonitor = cmConfigKey(kASCIIMainAuralMonitor)

        var setB = RTTYConfigSet()
        setB.channel = RIGHTCHANNEL
        setB.inputDevice = cmConfigKey(kASCIISubDevice)
        setB.outputDevice = nil
        setB.outputLevel = nil
        setB.outputAttenuator = nil
        setB.tone = cmConfigKey(kASCIISubTone)
        setB.mark = cmConfigKey(kASCIISubMark)
        setB.space = cmConfigKey(kASCIISubSpace)
        setB.baud = cmConfigKey(kASCIISubBaud)
        setB.controlWindow = cmConfigKey(kASCIISubControlWindow)
        setB.squelch = cmConfigKey(kASCIISubSquelch)
        setB.active = cmConfigKey(kASCIISubActive)
        setB.stopBits = cmConfigKey(kASCIISubStopBits)
        setB.sideband = cmConfigKey(kASCIISubMode)
        setB.rxPolarity = cmConfigKey(kASCIISubRxPolarity)
        setB.txPolarity = cmConfigKey(kASCIISubTxPolarity)
        setB.prefs = cmConfigKey(kASCIISubPrefs)
        setB.textColor = cmConfigKey(kASCIISubTextColor)
        setB.sentColor = cmConfigKey(kASCIISubSentColor)
        setB.backgroundColor = cmConfigKey(kASCIISubBackgroundColor)
        setB.plotColor = cmConfigKey(kASCIISubPlotColor)
        setB.vfoOffset = cmConfigKey(kASCIISubOffset)
        setB.fskSelection = cmConfigKey(kASCIISubFSKSelection)
        setB.usesRTTYAuralMonitor = true
        setB.auralMonitor = cmConfigKey(kASCIISubAuralMonitor)

        manager = mgr
        isASCIIModem = true
        bitsPerCharacter = 7
        hardLimitForBackspace = 0

        //  initialize txConfig before rxConfigs (rttyRxControls undefined here)
        txConfig?.awakeFromModem?(&setA, rttyRxControl: nil)
        ptt = txConfig?.pttObject?() ?? nil

        //  --- main receiver (a) ---
        a.isAlive = true
        a.control = RTTYRxControl(intoView: receiverA as? NSView, client: self, index: 0)
        a.receiver = a.control?.receiver
        a.receiver?.createClickBuffer()
        a.view = a.control?.view()
        currentRxView = a.view
        a.view?.setValue(self, forKey: "delegate")          //  text selections, etc
        a.textAttribute = a.control?.textAttribute()
        a.control?.setName(NSLocalizedString("Main Receiver", comment: ""))
        a.control?.setEllipseFatness(ellipseFatness)
        configA?.awakeFromModem?(&setA, rttyRxControl: a.control, txConfig: txConfig as? RTTYTxConfig)
        configA?.setChannel?(0)
        control[0] = a.control
        configObjs[0] = configA as? WFRTTYConfig
        txLocked[0] = false

        //  v0.78
        txConfig?.setRTTYAuralMonitor?(a.receiver?.rttyAuralMonitor)

        if let ctrl = a.control {
            var tonepair = ctrl.baseTonePair()
            waterfallA?.setTonePairMarker?(&tonepair, index: 0)
        }

        //  --- sub receiver (b) ---
        b.isAlive = true
        b.control = RTTYRxControl(intoView: receiverB as? NSView, client: self, index: 1)
        b.receiver = b.control?.receiver
        b.receiver?.createClickBuffer()
        b.view = b.control?.view()
        b.view?.setValue(self, forKey: "delegate")          //  text selections, etc
        b.textAttribute = b.control?.textAttribute()
        b.control?.setName(NSLocalizedString("Sub Receiver", comment: ""))
        b.control?.setEllipseFatness(ellipseFatness)
        configB?.awakeFromModem?(&setB, rttyRxControl: b.control, txConfig: txConfig as? RTTYTxConfig)   // shared txConfig
        configB?.setChannel?(1)
        control[1] = b.control
        configObjs[1] = configB as? WFRTTYConfig
        txLocked[1] = false
        if let ctrl = b.control {
            var tonepair = ctrl.baseTonePair()
            waterfallB?.setTonePairMarker?(&tonepair, index: 1)
        }

        (configTab as? NSTabView)?.setValue(self, forKey: "delegate")

        //  AppleScript text callback
        a.receiver?.registerModule(transceiver1?.receiver())
        a.transmitModule = transceiver1?.transmitter()
        if !isLite {
            b.receiver?.registerModule(transceiver2?.receiver())
            b.transmitModule = transceiver2?.transmitter()
        }
    }

    @objc(setInterface:to:)
    override func setInterface(_ object: NSControl!, to selector: Selector!) {
        object?.action = selector
        object?.target = self
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("ASCII", comment: "")
        setInterface(dataBits as? NSControl, to: #selector(numberOfBitsChanged(_:)))
        commonAwakeFromNib()
    }

    @objc(numberOfBitsChanged:)
    func numberOfBitsChanged(_ sender: Any!) {
        bitsPerCharacter = ((sender as? NSMatrix)?.selectedRow == 0) ? 7 : 8
        a.receiver?.demodulator?.setBitsPerCharacter(bitsPerCharacter)
        b.receiver?.demodulator?.setBitsPerCharacter(bitsPerCharacter)
        txConfig?.setBitsPerCharacter?(bitsPerCharacter)
    }

    @objc(changeTransmitStateTo:)
    override func changeTransmitStateTo(_ state: Bool) {
        if state == false {
            //  state changed back to receive -- mark the backspace limit
            hardLimitForBackspace = indexOfUntransmittedText
        }
        super.changeTransmitStateTo(state)
    }

    //  Delegate of receiveView and transmitView
    @objc(textView:shouldChangeTextInRange:replacementString:)
    override func textView(_ textView: NSTextView, shouldChangeTextIn original: NSRange, replacementString replace: String?) -> Bool {
        //  check if backspacing at the end of the transmit view while transmitting
        if textView === transmitView && transmitState == true && ((replace as NSString?)?.length ?? 0) == 0 {
            transmitViewLock?.lock()
            if let storage = transmitView?.textStorage {
                let total = storage.length
                let start = original.location
                let length = original.length
                if (start + length) >= total {
                    //  deleting <length> characters from the end
                    if (total - original.length) < Int(hardLimitForBackspace) {
                        //  deleting past the transmitted text
                        NSSound.beep()
                        transmitViewLock?.unlock()
                        return false
                    }
                    for _ in 0..<length {
                        txConfig?.transmitCharacter?(0x08)
                    }
                    if transmitView?.hasMarkedText() == false {
                        indexOfUntransmittedText -= Int32(length)
                    }
                }
                transmitViewLock?.unlock()
                return true
            }
            transmitViewLock?.unlock()
        }
        //  if not backspacing while transmitting, just call the base class
        return super.textView(textView, shouldChangeTextIn: original, replacementString: replace)
    }

    //  =======================================================================
    //  Plist
    //  =======================================================================

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)

        pref?.setString("Verdana", forKey: kASCIIFontA)
        pref?.setFloat(14.0, forKey: kASCIIFontSizeA)
        pref?.setString("Verdana", forKey: kASCIIFontB)
        pref?.setFloat(14.0, forKey: kASCIIFontSizeB)

        pref?.setString("Verdana", forKey: kASCIITxFont)
        pref?.setFloat(14.0, forKey: kASCIITxFontSize)
        pref?.setInt(1, forKey: kASCIIMainWaterfallNR)
        pref?.setInt(1, forKey: kASCIISubWaterfallNR)
        pref?.setInt(bitsPerCharacter, forKey: kASCIIBitsPerCharacter)

        pref?.setInt(0, forKey: kASCIITransmitChannel)
        pref?.setInt(0, forKey: kASCIILockA)
        pref?.setInt(0, forKey: kASCIILockB)

        pref?.setRed(1.0, green: 0.8, blue: 0.0, forKey: kASCIIMainTextColor)
        pref?.setRed(0.0, green: 0.8, blue: 1.0, forKey: kASCIIMainSentColor)
        pref?.setRed(0.0, green: 0.0, blue: 0.0, forKey: kASCIIMainBackgroundColor)
        pref?.setRed(0.0, green: 1.0, blue: 0.0, forKey: kASCIIMainPlotColor)
        pref?.setRed(1.0, green: 0.8, blue: 0.0, forKey: kASCIISubTextColor)
        pref?.setRed(0.0, green: 0.8, blue: 1.0, forKey: kASCIISubSentColor)
        pref?.setRed(0.0, green: 0.0, blue: 0.0, forKey: kASCIISubBackgroundColor)
        pref?.setRed(0.0, green: 1.0, blue: 0.0, forKey: kASCIISubPlotColor)

        configA?.setupDefaultPreferences?(pref, rttyRxControl: a.control)
        configB?.setupDefaultPreferences?(pref, rttyRxControl: b.control)

        for i in 0..<3 {
            if let sheet = macroSheet[i] {
                (sheet as? RTTYMacros)?.setupDefaultPreferences(pref, option: Int32(i))
            }
        }
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = super.updateFromPlist(pref)

        var fontName = pref?.stringValue(forKey: kASCIIFontA)
        var fontSize = pref?.floatValue(forKey: kASCIIFontSizeA) ?? 0
        a.view?.setTextFont(fontName ?? "", size: fontSize, attribute: a.control.textAttribute())

        fontName = pref?.stringValue(forKey: kASCIIFontB)
        fontSize = pref?.floatValue(forKey: kASCIIFontSizeB) ?? 0
        b.view?.setTextFont(fontName ?? "", size: fontSize, attribute: b.control.textAttribute())

        fontName = pref?.stringValue(forKey: kASCIITxFont)
        fontSize = pref?.floatValue(forKey: kASCIITxFontSize) ?? 0
        transmitView?.setTextFont(fontName ?? "", size: fontSize, attribute: transmitTextAttribute!)

        let txChannel = pref?.intValue(forKey: kASCIITransmitChannel) ?? 0
        transmitFrom(txChannel)
        (transmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: Int(txChannel))
        (contestTransmitSelect as? NSMatrix)?.selectCell(atRow: 0, column: Int(txChannel))
        //  update visual interfaces
        transmitSelectChanged()

        var locked = (pref?.intValue(forKey: kASCIILockA) ?? 0) != 0
        setTransmitLockButton(0, toState: locked)
        control[0]?.setTransmitLock(locked)
        txLocked[0] = locked

        locked = (pref?.intValue(forKey: kASCIILockB) ?? 0) != 0
        setTransmitLockButton(1, toState: locked)
        control[1]?.setTransmitLock(locked)
        txLocked[1] = locked

        waterfallA?.setNoiseReductionState?((pref?.intValue(forKey: kASCIIMainWaterfallNR) ?? 0) != 0)
        waterfallB?.setNoiseReductionState?((pref?.intValue(forKey: kASCIISubWaterfallNR) ?? 0) != 0)

        (dataBits as? NSMatrix)?.selectCell(atRow: (pref?.intValue(forKey: kASCIIBitsPerCharacter) == 8) ? 1 : 0, column: 0)
        numberOfBitsChanged(dataBits)

        manager?.showSplash("Updating ASCII configurations")
        configA?.updateFromPlist?(pref, rttyRxControl: a.control)
        configB?.updateFromPlist?(pref, rttyRxControl: b.control)
        //  check slashed zero key
        useSlashedZero((pref?.intValue(forKey: kSlashZeros) ?? 0) != 0)

        plistHasBeenUpdated = true
        return true
    }

    //  retrieve the preferences before exiting
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }

        super.retrieveForPlist(pref)

        var font = a.view?.font
        pref?.setString(font?.fontName ?? "", forKey: kASCIIFontA)
        pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kASCIIFontSizeA)
        font = b.view?.font
        pref?.setString(font?.fontName ?? "", forKey: kASCIIFontB)
        pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kASCIIFontSizeB)

        font = transmitView?.font
        pref?.setString(font?.fontName ?? "", forKey: kASCIITxFont)
        pref?.setFloat(Float(font?.pointSize ?? 0), forKey: kASCIITxFontSize)

        pref?.setInt(transmitChannel, forKey: kASCIITransmitChannel)

        pref?.setInt(transmitIsLocked(0) ? 1 : 0, forKey: kASCIILockA)
        pref?.setInt(transmitIsLocked(1) ? 1 : 0, forKey: kASCIILockB)

        pref?.setInt((waterfallA?.noiseReductionState?() ?? false) ? 1 : 0, forKey: kASCIIMainWaterfallNR)
        pref?.setInt((waterfallB?.noiseReductionState?() ?? false) ? 1 : 0, forKey: kASCIISubWaterfallNR)
        pref?.setInt(((dataBits as? NSMatrix)?.selectedRow == 0) ? 7 : 8, forKey: kASCIIBitsPerCharacter)

        configA?.retrieveForPlist?(pref, rttyRxControl: a.control)
        configB?.retrieveForPlist?(pref, rttyRxControl: b.control)
    }

    //  Application sends this through the ModemManager when quitting
    @objc(applicationTerminating)
    override func applicationTerminating() {
        ptt?.applicationTerminating()               //  v0.89
    }
}
