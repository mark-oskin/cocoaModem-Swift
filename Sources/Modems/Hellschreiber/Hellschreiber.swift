//
//  Hellschreiber.swift
//  cocoaModem
//
//  Created by Kok Chen on Wed Jul 27 2005.
//  Swift port of Hellschreiber.m / Hellschreiber.h.
//
//  Hellschreiber : ContestInterface : MacroInterface : Modem : CMPipe.  This is
//  the Feld-Hell / FM-Hell mode tab.  It is instantiated by StdManager via
//  -initIntoTabView:manager: and loads the "Hellschreiber" nib.
//
//  Port notes:
//   * Every original ivar is preserved with its EXACT name.  C object-pointer
//     ivars that never collide are `@objc var`; the C-struct-pointer ivars
//     (transmitAttribute / textAttribute) and the C pointer-array `font[10]`
//     are declared plain `internal` (they cannot be @objc).
//   * The outlet `inputAttenuator` collides with the inherited method
//     -inputAttenuator: so it is renamed `inputAttenuatorOutlet` and given the
//     exact nib key via @objc(inputAttenuator) (same treatment as SynchAM).
//   * The `vuMeter` outlet and the -vuMeter accessor are unified into one @objc
//     property (the getter IS the method).
//   * `frequencyUpdatedTo:` maps to the Swift name `frequencyUpdated(to:)` and
//     `addColumn:index:xScale:` to `addColumn(_:index:xScale:)` so the already
//     shipped HellReceiver.swift (which calls those Swift names) resolves.
//   * The mode tags HELLFELD/HELLFM245/HELLFM105 were #defined in the retired
//     Hellschreiber.h; they are re-declared here at module scope so HellReceiver
//     and HellModulator continue to see them.
//   * MRC retain/release in -setTextColor:... dropped (ARC).
//

import Cocoa

//  modeMenu tags (were in Hellschreiber.h, now module-scope Swift constants)
let HELLFELD: Int32 = 0
let HELLFM245: Int32 = 1
let HELLFM105: Int32 = 2

//  transmit light state (local #defines in Hellschreiber.m)
private let TxOff: Int32 = 0
private let TxReady: Int32 = 1
private let TxWait: Int32 = 2
private let TxActive: Int32 = 3

//  --- Plist keys (defined in Plist.h, which is not in the bridging header) ---
private let kHellAlignedFont   = "Hell Aligned Font"
private let kHellUnalignedFont = "Hell Unaligned Font"
private let kHellTxFont        = "Hell Tx Font"
private let kHellTxFontSize    = "Hell Tx Font Size"
private let kHellFont          = "Hell Font"            // deprecated
private let kHellFontSize      = "Hell Font Size"       // deprecated
private let kSlashZeros        = "Null for Zero"

@objc(Hellschreiber)
class Hellschreiber: ContestInterface, NSTextViewDelegate {

    //  --- IBOutlets (were IBOutlet id) ---
    @objc var waterfall: AnyObject!
    @objc var transmitButton: NSButton!
    @objc var transmitLight: AnyObject!

    @objc var slopeSlider: NSSlider!
    @objc var upButton: NSButton!
    @objc var downButton: NSButton!
    @objc var fontMenu: NSPopUpButton!
    @objc var modeMenu: NSPopUpButton!

    //  the outlet is named "inputAttenuator"; the accessor -inputAttenuator: has
    //  the same base name so the stored property is renamed and given the exact
    //  nib key via @objc.
    @objc(inputAttenuator) var inputAttenuatorOutlet: NSSlider!
    //  outlet + -vuMeter accessor unified into one property
    @objc var vuMeter: VUMeter!

    //  AudioPipes
    @objc var rx: HellReceiver!

    @objc var thread: Thread!

    //  demodulator
    @objc var vfoOffset: Float = 0
    @objc var sideband: Int32 = 0
    @objc var frequencyLocked: Bool = false

    //  Prefs
    @objc var sidebandState: Bool = false
    var alignedFont: Int32 = 0
    var unalignedFont: Int32 = 0

    //  transmit
    @objc var transmitViewLock: NSLock!
    @objc var transmitBufferCheck: Timer!
    @objc var indexOfUntransmittedText: Int32 = 0
    var transmitAttribute: TextAttribute!          //  C-struct pointer: non-@objc
    @objc var frequencyDefined: Bool = false
    //  receive
    @objc var receiveWait: Timer!
    var textAttribute: TextAttribute!              //  C-struct pointer: non-@objc

    @objc var fonts: Int32 = 0
    //  font[10] -- borrowed HellschreiberFontHeader pointers (owned elsewhere)
    var font = [UnsafeMutablePointer<HellschreiberFontHeader>?](repeating: nil, count: 10)
    @objc var modeNeedsAlignedFont: Bool = false

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    //  Hellschreiber : ContestInterface : MacroInterface : Modem : NSObject
    @objc(initIntoTabView:manager:)
    init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr.showSplash("Creating Hellschreiber Modem")

        super.init(into: tabview, nib: "Hellschreiber", manager: mgr)

        manager = mgr
        frequencyLocked = false
    }

    override func transmissionMode() -> Int32 {
        return HELLMODE
    }

    //  v0.87
    override func switchModemIn() {
        if config != nil { (config as? HellConfig)?.setKeyerMode() }
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("Hellschreiber", comment: "")

        fonts = 0
        (config as? HellConfig)?.awakeFromModem(self)
        ptt = (config as? HellConfig)?.pttObject()
        alignedFont = 0
        unalignedFont = 0
        modeNeedsAlignedFont = false

        awakeFromContest()
        initCallsign()
        initColors()
        initMacros()
        sidebandState = false

        //  use QSO transmitview
        (contestTab as? NSTabView)?.selectTabViewItem(at: 0)

        waterfall?.awakeFromModem?()
        waterfall?.enableIndicator?(self)
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

        //  set up the scroller for the input view
        let sview = (receiveView as? NSView)?.superview?.superview as? NSScrollView
        let scroller = sview?.verticalScroller
        scroller?.floatValue = 1.0
        scroller?.knobProportion = 0.125

        vuMeter?.setup()

        //  create receiver
        rx = HellReceiver(fromModem: self)
        modeChanged()

        setInterface(slopeSlider, to: #selector(slopeChanged))
        setInterface(transmitButton, to: #selector(transmitButtonChanged))
        setInterface(inputAttenuatorOutlet, to: #selector(inputAttenuatorChanged))
        setInterface(upButton, to: #selector(positionButtonPushed(_:)))
        setInterface(downButton, to: #selector(positionButtonPushed(_:)))
        setInterface(fontMenu, to: #selector(fontChanged))
        setInterface(modeMenu, to: #selector(modeChanged))
    }

    //  Application sends this through the ModemManager when quitting
    override func applicationTerminating() {
        ptt?.applicationTerminating()               //  v0.89
    }

    override func initMacros() {
        currentSheet = 0
        check = 0
        let application = manager?.appObject()
        for i in 0..<3 {
            let sheet = HellMacros(sheet: ())
            macroSheet[i] = sheet
            sheet.setUserInfo(application?.userInfoObject(),
                              qso: (manager as? StdManager)?.qsoObject(),
                              modem: self, canImport: true)
        }
    }

    @objc(configObj)
    func configObj() -> HellConfig! {
        return config as? HellConfig
    }

    //  overide base class to change AudioPipe pipeline (assume source is normalized)
    //		source
    //		. self(importData)
    //			. waterfall
    //			. receiver
    //			. VU Meter
    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating Hellschreiber sound source")
        //  send data to distribution box for concurrent display on waterfall
        (config as? HellConfig)?.setClient(self)
        (config as? HellConfig)?.checkActive()
    }

    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    //  process the new data buffer
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        //  send data to users
        rx?.importData(pipe)
        waterfall?.importData?(pipe)
        vuMeter?.importData(pipe)
    }

    override func shouldEndTransmission() -> Bool {
        //  first decrement transmit count
        decrementTransmitCount()
        return transmitCount <= 0
    }

    //  check if capable of transmitting on waterfall
    @objc func checkTx() -> Bool {
        return rx?.canTransmit() ?? false
    }

    @objc func transmitFrequency() -> Float {
        return rx?.lockedFrequency ?? 0
    }

    //  this is called from the waterfall when it is shift clicked.
    @objc(turnOffReceiver:option:)
    override func turnOffReceiver(_ ident: Int32, option: Bool) {
        rx?.enableReceiver(false)
    }

    //  waterfall clicked
    //  Note: for USB left edge is always 400 Hz no matter what the VFO offset is
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    override func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID index: Int32) {
        //  check if already in transmit mode, if so, don't change frequency
        if transmitState == false {
            frequencyDefined = true
            rx?.selectFrequency(freq, fromWaterfall: acquire)
            rx?.enableReceiver(true)
        }
    }

    //  receive frequency set not by clicking, but by direct entry
    @objc(receiveFrequency:)
    func receiveFrequency(_ freq: Float) {
        frequencyUpdated(to: freq)
        clicked(freq, secondsAgo: 0, option: false, fromWaterfall: false, waterfallID: 0)
    }

    //  frequency update from HellReceiver
    @objc(frequencyUpdatedTo:)
    func frequencyUpdated(to tone: Float) {
        waterfall?.forceToneTo?(tone, receiver: 0)
    }

    @objc(setWaterfallOffset:sideband:)
    func setWaterfallOffset(_ freq: Float, sideband polarity: Int32) {
        let offset = abs(freq)

        vfoOffset = offset
        sideband = polarity

        waterfall?.setOffset?(freq, sideband: sideband)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)

        pref.setString("none", forKey: kHellAlignedFont)
        pref.setString("none", forKey: kHellUnalignedFont)

        pref.setString("Verdana", forKey: kHellTxFont)
        pref.setFloat(14.0, forKey: kHellTxFontSize)
        (config as? HellConfig)?.setupDefaultPreferences(pref)

        for i in 0..<3 {
            if let m = macroSheet[i] as? HellMacros { m.setupDefaultPreferences(pref, option: Int32(i)) }
        }
    }

    override func updateColorsInViews() {
        (receiveView as? HellDisplay)?.updateColorsInView()
    }

    //  column is an array of 28 half pixels
    @objc(addColumn:index:xScale:)
    func addColumn(_ column: UnsafeMutablePointer<Float>!, index: Int32, xScale scale: Int32) {
        (receiveView as? HellDisplay)?.addColumn(column, index: index, xScale: scale)
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = super.updateFromPlist(pref)

        setAlignedFont(pref.stringValue(forKey: kHellAlignedFont))
        setUnalignedFont(pref.stringValue(forKey: kHellUnalignedFont))

        let txFontName = pref.stringValue(forKey: kHellTxFont)
        let fontSize = pref.floatValue(forKey: kHellTxFontSize)
        transmitView?.setTextFont(txFontName ?? "", size: fontSize, attribute: transmitTextAttribute!)

        manager?.showSplash("Updating Hellschreiber configurations")
        _ = (config as? HellConfig)?.updateFromPlist(pref)

        manager?.showSplash("Loading Hellschreiber macros")
        for i in 0..<3 {
            if let m = macroSheet[i] as? HellMacros { _ = m.updateFromPlist(pref, option: Int32(i)) }
        }

        //  check slashed zero key
        useSlashedZero(pref.intValue(forKey: kSlashZeros) != 0)

        plistHasBeenUpdated = true                       //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }       //  v0.53d
        super.retrieveForPlist(pref)

        //  remove deprecated keys
        pref.removeKey(kHellFont)
        pref.removeKey(kHellFontSize)

        //  get the current fonts
        if let f = font[Int(alignedFont)] { pref.setString(fontName(f), forKey: kHellAlignedFont) }
        if let f = font[Int(unalignedFont)] { pref.setString(fontName(f), forKey: kHellUnalignedFont) }

        let fnt = transmitView?.font
        pref.setString(fnt?.fontName, forKey: kHellTxFont)
        pref.setFloat(Float(fnt?.pointSize ?? 0), forKey: kHellTxFontSize)

        (config as? HellConfig)?.retrieveForPlist(pref)
        for i in 0..<3 {
            if let m = macroSheet[i] as? HellMacros { m.retrieveForPlist(pref, option: Int32(i)) }
        }
    }

    //  sideband state (set from PSKConfig's LSB/USB button)
    //  NO = LSB
    @objc(selectAlternateSideband:)
    func selectAlternateSideband(_ state: Bool) {
        sidebandState = state
        rx?.setSidebandState(state)
        waterfall?.setSideband?(state ? 1 : 0)
    }

    override func sendMessageImmediately() {
        transmitCountLock?.lock()
        transmitCount += 1
        transmitCountLock?.unlock()
    }

    /* local */
    //  this gets periodically called
    @objc(timedOut:)
    func timedOut(_ timer: Timer!) {
        if charactersSinceTimerStarted == 0 {
            //  timed out!
            changeTransmitStateTo(false)
        }
        charactersSinceTimerStarted = 0
    }

    //  allow receive data to flush through the pipeline before changing text color
    //  and sending transmit buffer
    @objc(delayTransmit:)
    func delayTransmit(_ timer: Timer!) {
        transmitView?.select()
        //  send any pending storage
        transmitViewLock?.lock()
        let storage = transmitView?.textStorage
        let total = Int(storage?.length ?? 0)
        let string = storage?.string as NSString?

        while Int(indexOfUntransmittedText) < total {
            let uch = string?.character(at: Int(indexOfUntransmittedText)) ?? 0
            indexOfUntransmittedText += 1
            (config as? HellConfig)?.transmitCharacter(Int32(uch))
            charactersSinceTimerStarted += 1
        }
        transmitViewLock?.unlock()
    }

    @objc(checkTransmitBuffer:)
    func checkTransmitBuffer(_ timer: Timer!) {
        transmitViewLock?.lock()
        let storage = transmitView?.textStorage
        let total = Int(storage?.length ?? 0)
        if Int(indexOfUntransmittedText) < total {
            let string = storage?.string as NSString?
            while Int(indexOfUntransmittedText) < total {
                let uch = string?.character(at: Int(indexOfUntransmittedText)) ?? 0
                indexOfUntransmittedText += 1
                (config as? HellConfig)?.transmitCharacter(Int32(uch))
                charactersSinceTimerStarted += 1
            }
        }
        transmitViewLock?.unlock()
    }

    @objc func transmitting() -> Bool {
        return transmitState
    }

    @objc(useSlashedZero:)
    override func useSlashedZero(_ state: Bool) {
        super.useSlashedZero(state)
        // rx1?.useSlashedZero(state)
    }

    @objc(changeTransmitStateTo:)
    override func changeTransmitStateTo(_ state: Bool) {
        let indicatorColor: NSColor

        transmitState = (config as? HellConfig)?.turnOnTransmission(state, button: transmitButton) ?? false

        if transmitState == true {
            executePTT(true)
            indicatorColor = NSColor.red
            transmitView?.window?.makeFirstResponder(transmitView)
            timeout?.invalidate()
            charactersSinceTimerStarted = 0
            if manager?.useWatchdog() == true {
                timeout = Timer.scheduledTimer(timeInterval: 150, target: self, selector: #selector(timedOut(_:)), userInfo: self, repeats: true)
            }
            transmitBufferCheck = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(checkTransmitBuffer(_:)), userInfo: self, repeats: true)
            //  set text color in receive view and turn on transmit
            _ = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(delayTransmit(_:)), userInfo: self, repeats: false)
        } else {
            executePTT(false)
            timeout?.invalidate()
            timeout = nil
            receiveWait?.invalidate()
            receiveWait = nil
            transmitBufferCheck?.invalidate()
            transmitBufferCheck = nil
            transmitCountLock?.lock()
            transmitCount = 0
            transmitCountLock?.unlock()
            indicatorColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
            setSentColor(false, view: receiveView as? ExchangeView, textAttribute: receiveTextAttribute)
            transmitView?.select()
        }
        transmitLight?.setBackgroundColor?(indicatorColor)
    }

    //  this overrides the method in Modem.m that is called from the app
    @objc(enterTransmitMode:)
    override func enterTransmitMode(_ state: Bool) {
        if !frequencyDefined { return }         //  return if the waterfall has not been previously clicked

        if state != transmitState {
            if state == true {
                //  immediately change state to transmit
                changeTransmitStateTo(state)
            } else {
                //  enter a %[rx] character into the stream
                transmitView?.insertInTextStorage(String(format: "%c", 5) /*^E*/)
                transmitLight?.setBackgroundColor?(NSColor.yellow)
            }
        }
    }

    @objc func flushOutput() {
        transmitCountLock?.lock()
        transmitCount = 0
        transmitCountLock?.unlock()
        //  flush transmit view also
        indexOfUntransmittedText = Int32(transmitView?.textStorage?.length ?? 0)
        //  now flush whatever is in the afsk bit buffer
        (config as? HellConfig)?.flushTransmitBuffer()
    }

    //  this overrides the method in Modem.m
    override func flushAndLeaveTransmit() {
        flushOutput()
        enterTransmitMode(false)
    }

    @objc(inputAttenuator:)
    override func inputAttenuator(_ config: ModemConfig!) -> NSSlider! {
        return inputAttenuatorOutlet
    }

    @objc func transmitButtonChanged() {
        let state = ((transmitButton?.state ?? .off) == .on)

        if state {
            if !((config as? HellConfig)?.soundInputActive() ?? false) {
                //  check if A/D is active
                transmitButton?.state = .off
                _ = Messages.alert(withMessageText: NSLocalizedString("Sound Card not active", comment: ""), informativeText: NSLocalizedString("Select Sound Card", comment: ""))
                return
            }
            if !(rx?.canTransmit() ?? false) {
                //  check if receive frequency has been selected
                transmitButton?.state = .off
                _ = Messages.alert(withMessageText: NSLocalizedString("Hellschreiber not on", comment: ""), informativeText: NSLocalizedString("Click on waterfall", comment: ""))
                flushOutput()
                return
            }
        }
        enterTransmitMode(state)
    }

    @objc(flushTransmitStream:)
    func flushTransmitStream(_ sender: Any!) {
        flushOutput()
    }

    @objc func inputAttenuatorChanged() {
        (config as? HellConfig)?.inputSource()?.setDeviceLevel(inputAttenuatorOutlet)
    }

    //  Delegate of receiveView and transmitView
    @objc(textView:shouldChangeTextInRange:replacementString:)
    func textView(_ textView: NSTextView, shouldChangeTextIn original: NSRange, replacementString replace: String?) -> Bool {
        if textView === receiveView {
            if ((replace ?? "") as NSString).length != 0 {
                NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                _ = Messages.alert(withMessageText: NSLocalizedString("text is write only", comment: ""), informativeText: NSLocalizedString("cannot insert text", comment: ""))
                return false
            }
            return true
        }
        if textView === transmitView {
            if slashZero {
                guard var chars = replace?.cString(using: .isoLatin1) else {
                    Messages.alertWithHiraganaError()
                    return false
                }
                var hasZero = false
                for c in chars {
                    if c == 0 { break }
                    if c == 48 /* '0' */ { hasZero = true }
                }
                if hasZero {
                    let length = chars.firstIndex(of: 0) ?? chars.count
                    if length < 32 {
                        for k in 0..<length {
                            if chars[k] == 48 { chars[k] = CChar(truncatingIfNeeded: Phi) }
                        }
                        //  replace zeros with phi and try again
                        let phiString = NSString(cString: chars, encoding: String.Encoding.isoLatin1.rawValue) as String? ?? ""
                        transmitView?.replaceCharacters(in: original, with: phiString)
                        return false
                    }
                }
            }
            let storage = transmitView?.textStorage
            let total = Int(storage?.length ?? 0)
            let start = original.location
            let length = original.length

            if length == total && ((replace ?? "") as NSString).length == 0 && transmitState == false {
                transmitView?.clearAll()
                indexOfUntransmittedText = 0
                return false
            }
            if length > 0 {
                if (start + length) == total {
                    //  allow deletion at end to replace umlauts, etc  v0.35
                    let replacement = Int((storage?.string as NSString?)?.character(at: total - 1) ?? 0)
                    if replacement == 168 ||        // opt U
                       replacement == 710 ||        // opt I
                       replacement == 96  ||        // opt `
                       replacement == 180 ||        // opt e
                       replacement == 732 {         // opt n
                        return true
                    }
                    //  deleting <length> characters from end
                    if transmitState == true {
                        for _ in 0..<length { (config as? HellConfig)?.transmitCharacter(0x08) }
                        indexOfUntransmittedText -= Int32(length)
                    }
                    return true
                }
                if transmitState == true {
                    transmitView?.insertAtEnd(replace ?? "")
                    NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                    return false
                }
                //  not yet transmitted
                if original.location < Int(indexOfUntransmittedText) {
                    NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                    _ = Messages.alert(withMessageText: NSLocalizedString("text already sent", comment: ""), informativeText: NSLocalizedString("cannot insert after sending", comment: ""))
                    return false
                }
                return true
            }

            //  insertion length = 0
            if start != total {
                //  inserting in the middle of the transmitView
                if transmitState == true {
                    //  always insert text at the end when in transmit state
                    NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                    transmitView?.insertAtEnd(replace ?? "")
                    return false
                } else {
                    if original.location < Int(indexOfUntransmittedText) {
                        //  attempt to insert into text that has already been transmitted
                        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                        _ = Messages.alert(withMessageText: NSLocalizedString("text already sent", comment: ""), informativeText: NSLocalizedString("cannot insert after sending", comment: ""))
                        return false
                    }
                    return true
                }
            }
            //  inserting at the end of buffer (-checkTransmitBuffer will pick it up)
            if ((replace ?? "") as NSString).length != 0 { return true }
        }
        return true
    }

    @objc(setTextColor:sentColor:backgroundColor:plotColor:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!) {
        textColor = inTextColor
        sentTextColor = sentTColor
        backgroundColor = bgColor
        plotColor = pColor

        (receiveView as? HellDisplay)?.setBackgroundColor(backgroundColor)
        transmitView?.backgroundColor = backgroundColor

        (receiveView as? HellDisplay)?.setTextColors(textColor, transmit: sentTextColor)
        transmitView?.setViewTextColor(textColor, attribute: transmitTextAttribute!)
    }

    @objc func slopeChanged() {
        rx?.slopeChanged(slopeSlider?.floatValue ?? 0)
    }

    @objc(positionButtonPushed:)
    func positionButtonPushed(_ sender: Any!) {
        let direction: Int32 = ((sender as AnyObject?) === upButton) ? 1 : -1
        rx?.positionChanged(direction)
    }

    //  one bit per pixel fonts
    @objc(setAlignedFont:)
    func setAlignedFont(_ name: String!) {
        //  walk through all fonts to find name
        for i in 0..<Int(fonts) {
            if let f = font[i], name == fontName(f) {
                //  found matching name, check that it is aligned font
                if (Int(f.pointee.version) & Int(STEMALIGNED)) != 0 {
                    alignedFont = Int32(i)
                    return
                }
                //  otherwise go find any aligned font
                break
            }
        }
        //  font either not found of is not an aligned font, pick the first available aligned font
        for i in 0..<Int(fonts) {
            if let f = font[i], (Int(f.pointee.version) & Int(STEMALIGNED)) != 0 {
                alignedFont = Int32(i)
                return
            }
        }
    }

    //  two bit per pixel fonts
    @objc(setUnalignedFont:)
    func setUnalignedFont(_ name: String!) {
        fontMenu?.selectItem(withTitle: name ?? "")
        unalignedFont = Int32(fontMenu?.indexOfSelectedItem ?? 0)
        if unalignedFont < 0 { unalignedFont = 0 }
        // select for use
        (config as? HellConfig)?.selectFont(unalignedFont)
    }

    func addFont(_ inFont: UnsafeMutablePointer<HellschreiberFontHeader>!, index: Int32) {
        if index == 0 {
            fonts = 1
            fontMenu?.removeAllItems()
        }
        if (index + 1) > fonts { fonts = index + 1 }
        font[Int(index)] = inFont

        fontMenu?.insertItem(withTitle: fontName(inFont), at: Int(index))
    }

    // NSMenuValidation for fontMenu
    @objc(validateMenuItem:)
    func validateMenuItem(_ item: NSMenuItem!) -> Bool {
        if modeNeedsAlignedFont == false { return true }    //  use any font

        for i in 0..<Int(fonts) {
            if fontMenu?.item(at: i) === item {
                if let f = font[i] { return (Int(f.pointee.version) & Int(STEMALIGNED)) != 0 }
                return false
            }
        }
        return true
    }

    @objc func fontChanged() {
        let index = Int32(fontMenu?.indexOfSelectedItem ?? 0)
        (config as? HellConfig)?.selectFont(index)
        if modeNeedsAlignedFont { alignedFont = index } else { unalignedFont = index }
    }

    @objc func modeChanged() {
        let mode = Int32(modeMenu?.selectedItem?.tag ?? 0)

        //  take care of fonts when mode changes
        modeNeedsAlignedFont = (mode == HELLFM105)
        fontMenu?.selectItem(at: Int(modeNeedsAlignedFont ? alignedFont : unalignedFont))
        fontChanged()

        rx?.setMode(mode)
        (config as? HellConfig)?.setMode(mode)
    }

    //  -- AppleScript support --

    @objc(setModulationCodeFor:to:)
    override func setModulationCode(for transceiver: Transceiver!, to code: Int32) {
        let mode: Int32
        switch code {
        case 0x68313035:            // 'h105'
            mode = HELLFM105
        case 0x68323435:            // 'h245'
            mode = HELLFM245
        default:                    // 'Feld' and default
            mode = HELLFELD
        }
        modeMenu?.selectItem(withTag: Int(mode))
        modeChanged()
    }

    @objc(modulationCodeFor:)
    override func modulationCode(for transceiver: Transceiver!) -> Int32 {
        let mode = Int32(modeMenu?.selectedItem?.tag ?? 0)
        if mode == HELLFM245 { return 0x68323435 }  // 'h245'
        if mode == HELLFM105 { return 0x68313035 }  // 'h105'
        return 0x46656c64                           // 'Feld'
    }

    //  AppleScript support (callbacks from Modules)
    @objc(frequencyFor:)
    override func frequencyFor(_ module: Module!) -> Float {
        //  no RIT for now
        return transmitFrequency()
    }

    @objc(setFrequency:module:)
    override func setFrequency(_ freq: Float, module: Module!) {
        //  no RIT for now
        frequencyUpdated(to: freq)
        clicked(freq, secondsAgo: 0, option: false, fromWaterfall: false, waterfallID: 0)
    }

    //  this is called from the AppleScript module
    @objc(transmitString:)
    override func transmitString(_ s: UnsafePointer<CChar>!) {
        var p = s
        while let cp = p, cp.pointee != 0 {
            let uch = unichar(truncatingIfNeeded: Int32(cp.pointee))
            (config as? HellConfig)?.transmitCharacter(Int32(uch))
            p = cp + 1
        }
    }

    //  =======================================================================
    //  Helper -- read a HellschreiberFontHeader C name[32] as a String (kTextEncoding
    //  == NSISOLatin1StringEncoding).
    //  =======================================================================
    private func fontName(_ hdr: UnsafeMutablePointer<HellschreiberFontHeader>) -> String {
        var header = hdr.pointee
        return withUnsafeBytes(of: &header.name) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return NSString(cString: base, encoding: String.Encoding.isoLatin1.rawValue) as String? ?? ""
        }
    }
}
