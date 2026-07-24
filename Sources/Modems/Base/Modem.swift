//
//  Modem.swift
//  cocoaModem
//
//  Created by Kok Chen on Sun May 30 2004.
//  Swift port of Modem.m / Modem.h.
//
//  Base class of every mode/interface tab.  Modem : CMPipe.  It owns the DSP
//  pipeline entry point (-dataClient / -importData:), the AppleScript
//  transceivers, the transmit-count bookkeeping and the waterfall ring buffer.
//
//  Port notes:
//   * Every original ivar is an `internal` stored property with its EXACT name so
//     the 14+ Swift descendants resolve them across the module.  Most are `@objc`
//     so already-shipped Swift subclasses (e.g. SynchAM) can still reach them via
//     KVC (`setValue(forKey:"ident")`, etc.).
//   * `sentColor` (ivar) stays non-@objc: its synthesized `setSentColor:` would
//     collide with the -setSentColor: method.
//   * The `- (void)ptt:` method is exposed as `executePTT(_:)` (selector `ptt:`
//     preserved) so it does not collide with the `ptt` property.
//   * `- (float*)waterfallBuffer:` keeps its selector; its backing store is the
//     renamed `waterfallBufferStore` (the ivar `waterfallBuffer` name collides
//     with the method).
//   * C buffers callChar/exchChar/captured and the waterfall float ring are
//     UnsafeMutablePointers allocated here and freed in deinit.
//

import Cocoa

//  WATERFALLBUFFERMASK 0xf ; WaterfallBuffer float[1024]
private let kWaterfallBufferMask: Int32 = 0xf
private let kWaterfallRowLength = 1024

//  ---------------------------------------------------------------------------
//  RTTYTransceiver -- originally a C struct in Modem.h.  Because the code takes
//  its address (&a,&b), mutates fields in place and returns RTTYTransceiver*,
//  it is modelled as a Swift reference type.  Used by RTTYInterface (a,b) and
//  Analyze (a).
//  ---------------------------------------------------------------------------
final class RTTYTransceiver {
    var control: RTTYRxControl!
    var receiver: RTTYReceiver!
    var view: ExchangeView!
    //  TextAttribute is a C struct (TextAttribute.h) -- held by pointer, as in ObjC (TextAttribute*)
    var textAttribute: UnsafeMutablePointer<TextAttribute>?
    var isAlive: Bool = false
    var transmitModule: Module!
}

//  ---------------------------------------------------------------------------
//  Config-set key persistence.
//
//  The C aggregate RTTYConfigSet (and its siblings) carry __unsafe_unretained
//  NSString* key members, which Swift imports as Unmanaged<NSString>.  Modes
//  build these sets inline from the plist-key #defines (imported as String).
//  passUnretained on a transient String→NSString bridge would dangle before the
//  set is read synchronously by -awakeFromModem:, so bridged keys are held for
//  the process lifetime here.  The key set is a bounded pool of compile-time
//  constants, so this never grows without bound.
//  ---------------------------------------------------------------------------
private var gConfigSetKeyStore: [NSString] = []
func cmConfigKey(_ s: String) -> Unmanaged<NSString> {
    let ns = s as NSString
    gConfigSetKeyStore.append(ns)
    return Unmanaged.passUnretained(ns)
}

@objc(Modem)
class Modem: CMPipe {

    //  --- IBOutlets (id) ---
    @objc var config: AnyObject!
    @objc var txConfig: AnyObject!
    @objc var view: AnyObject!
    @objc var receiveView: AYTextView!
    @objc var transmitView: AYTextView!
    @objc var leadinField: AnyObject!
    @objc var releaseField: AnyObject!

    //  --- AppleScript transceiver class ---
    @objc var transceiver1: Transceiver!
    @objc var transceiver2: Transceiver!

    @objc var ident: String!
    @objc var transceivers: Int32 = 0
    @objc var lastPolledTransceiver: Int32 = 0

    @objc var modemTabItem: NSTabViewItem!
    @objc var controllingTabView: NSTabView!
    @objc var manager: ModemManager!

    //  Text views
    @objc var textColor: NSColor!
    @objc var backgroundColor: NSColor!
    @objc var sentTextColor: NSColor!
    @objc var plotColor: NSColor!
    var sentColor: Bool = false                 // non-@objc: collides with -setSentColor:
    //  TextAttribute is a C struct (TextAttribute.h) -- held by pointer (TextAttribute*), non-@objc
    var receiveTextAttribute: UnsafeMutablePointer<TextAttribute>?
    var transmitTextAttribute: UnsafeMutablePointer<TextAttribute>?

    //  modifier keys
    @objc var controlKeyState: Bool = false
    @objc var shiftKeyState: Bool = false
    @objc var optionKeyState: Bool = false

    //  modem's visible state
    var visibleState: Bool = false

    //  transmit
    @objc var transmitCountLock: NSLock!
    @objc var transmitCount: Int32 = 0
    @objc var transmitState: Bool = false
    @objc var ptt: PTT!

    //  receive
    @objc var slashZero: Bool = false

    //  call recognition / exchange recognition (C tables, 256 bytes each)
    let callChar: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        p.initialize(repeating: 0, count: 256); return p
    }()
    let exchChar: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        p.initialize(repeating: 0, count: 256); return p
    }()
    //  captured[33] returned as char* by -capturedString
    let captured: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: 33)
        p.initialize(repeating: 0, count: 33); return p
    }()
    @objc var enableClick: Bool = false
    @objc var getCallLock: NSLock!

    //  break-in
    @objc var breakinLeadin: Int32 = 0
    @objc var breakinRelease: Int32 = 0

    //  to avoid writing plist that has not been updated
    @objc var plistHasBeenUpdated: Bool = false

    @objc var waterfallLock: NSLock!
    @objc var waterfallProducer: Int32 = 0
    @objc var waterfallConsumer: Int32 = 0
    //  waterfallBuffer[16] of float[1024] -- flat store (ivar name collides with method)
    let waterfallBufferStore: UnsafeMutablePointer<Float> = {
        let n = Int(kWaterfallBufferMask + 1) * kWaterfallRowLength
        let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
        p.initialize(repeating: 0, count: n); return p
    }()
    @objc var waterfallDate: Date!
    @objc var waterfallTouched: Double = 0

    //  watchdog timer
    @objc var charactersSinceTimerStarted: Int32 = 0
    @objc var timeout: Timer!

    @objc var outputBoost: Float = 0

    deinit {
        callChar.deinitialize(count: 256); callChar.deallocate()
        exchChar.deinitialize(count: 256); exchChar.deallocate()
        captured.deinitialize(count: 33); captured.deallocate()
        let n = Int(kWaterfallBufferMask + 1) * kWaterfallRowLength
        waterfallBufferStore.deinitialize(count: n); waterfallBufferStore.deallocate()
    }

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    //  common to all subclasses (was -initWithManager:)
    private func commonInit(manager mgr: ModemManager!) {
        transceiver1 = Transceiver(modem: self, index: 0)
        transceiver2 = Transceiver(modem: self, index: 1)
        outputBoost = 1.0                       // v0.88
        receiveTextAttribute = nil
        transmitTextAttribute = nil
        manager = mgr
        transceivers = 1
        lastPolledTransceiver = 0
        transmitState = false
        slashZero = false
        transmitCount = 0
        controlKeyState = false
        shiftKeyState = false
        ident = nil
        ptt = nil
        captured[0] = 0
        enableClick = true
        plistHasBeenUpdated = false
        getCallLock = NSLock()
        waterfallDate = Date()                  // v0.82
    }

    @objc(initWithManager:)
    init(manager mgr: ModemManager!) {
        super.init()
        commonInit(manager: mgr)
    }

    //  override in instances of Modem to call -initIntoTabView:nib:manager:
    @objc(initIntoTabView:manager:)
    init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        super.init()
        ptt = nil
        commonInit(manager: mgr)
    }

    //  initialize and load the config view from the Nib into the tab view
    @objc(initIntoTabView:nib:manager:)
    init?(into tabview: NSTabView!, nib: String!, manager mgr: ModemManager!) {
        super.init()
        commonInit(manager: mgr)
        ptt = nil
        if Bundle.main.loadNibNamed(nib, owner: self, topLevelObjects: nil) {
            //  loadNib should have set up modem view
            if view != nil {
                modemTabItem = NSTabViewItem()
                modemTabItem.view = view as? NSView
                modemTabItem.label = ident ?? ""            // ident set from awakeFromNib
                controllingTabView = tabview
                controllingTabView.insertTabViewItem(modemTabItem, at: 0)
                NotificationCenter.default.addObserver(self, selector: #selector(keyModifierChanged(_:)),
                                                       name: NSNotification.Name("ModifierFlagsChanged"), object: nil)
                waterfallProducer = 0
                waterfallConsumer = 0
                return
            }
            print("cocoaModem: modem \(nib ?? "") not connected to any view")
        }
        return nil
    }

    //  =======================================================================

    @objc(setInterface:to:)
    func setInterface(_ object: NSControl!, to selector: Selector!) {
        object?.action = selector
        object?.target = self
    }

    @objc func capturedString() -> UnsafeMutablePointer<CChar>! {
        return captured
    }

    @objc func application() -> Application! {
        return manager?.appObject()
    }

    //  default mode to RTTY
    @objc func transmissionMode() -> Int32 {
        return RTTYMODE
    }

    @objc func initCallsign() {
        //  admissable callsign characters
        for i in 0..<256 { callChar[i] = 0 }
        for i in Int(UInt8(ascii: "A"))...Int(UInt8(ascii: "Z")) { callChar[i] = 1 }
        for i in Int(UInt8(ascii: "a"))...Int(UInt8(ascii: "z")) { callChar[i] = 1 }
        for i in Int(UInt8(ascii: "0"))...Int(UInt8(ascii: "9")) { callChar[i] = 1 }
        callChar[Int(UInt8(ascii: "/"))] = 1
        callChar[0xd8] = 1                       // slash-zero

        //  admissable exchange characters
        for i in 0..<256 { exchChar[i] = 0 }
        for i in Int(UInt8(ascii: "A"))...Int(UInt8(ascii: "Z")) { exchChar[i] = 1 }
        for i in Int(UInt8(ascii: "a"))...Int(UInt8(ascii: "z")) { exchChar[i] = 1 }
        for i in Int(UInt8(ascii: "0"))...Int(UInt8(ascii: "9")) { exchChar[i] = 1 }
        exchChar[0xd8] = 1                       // slash-zero
    }

    @objc(isCallChar:)
    func isCallChar(_ c: Int32) -> Bool {
        return callChar[Int(c) & 0xff] == 1
    }

    @objc func initColors() {
        sentTextColor = NSColor.black
        textColor = NSColor.black
        backgroundColor = NSColor.white
        plotColor = NSColor.green
    }

    @objc func updateColorsInViews() {
    }

    //  default modem, ignores receiver index
    @objc(setTextColor:sentColor:backgroundColor:plotColor:forReceiver:)
    func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!, forReceiver rx: Int32) {
        setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)
    }

    @objc(setTextColor:sentColor:backgroundColor:plotColor:)
    func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!) {
        textColor = inTextColor
        sentTextColor = sentTColor
        backgroundColor = bgColor
        plotColor = pColor
        receiveView?.backgroundColor = backgroundColor
        transmitView?.backgroundColor = backgroundColor
        if let attr = receiveTextAttribute {
            receiveView?.setTextColor(textColor, attribute: attr)
        }
        if let attr = transmitTextAttribute {
            transmitView?.setViewTextColor(textColor, attribute: attr)
        }
    }

    @objc(setTransmitTextColor:)
    func setTransmitTextColor(_ sentTColor: NSColor!) {
        sentTextColor = sentTColor
    }

    @objc(setSentColor:view:textAttribute:)
    func setSentColor(_ state: Bool, view eview: ExchangeView!, textAttribute attr: UnsafeMutablePointer<TextAttribute>?) {
        if let attr = attr {
            if state {
                if sentColor != true {
                    eview?.setTextColor(sentTextColor, attribute: attr)
                    sentColor = true
                }
            } else {
                eview?.setTextColor(textColor, attribute: attr)
                sentColor = false
            }
        }
    }

    //  change color of default receive view's text
    @objc(setSentColor:)
    func setSentColor(_ state: Bool) {
        setSentColor(state, view: receiveView as? ExchangeView, textAttribute: receiveTextAttribute)
    }

    @objc(directSetFrequency:)
    func directSetFrequency(_ freq: Float) {
        //  override by modems that can directly set frequency
        _ = application()?.speakAssist("This interface does not support direct frequency access.")
    }

    @objc func selectedFrequency() -> Float {
        //  override by modems that can directly set frequency
        return 0.0
    }

    //  default to the main config IBOutlet
    @objc(configObj:)
    func configObj(_ index: Int32) -> ModemConfig! {
        return config as? ModemConfig
    }

    @objc func txConfigObj() -> ModemConfig! {
        return txConfig as? ModemConfig
    }

    @objc func currentTransmitState() -> Bool {
        return transmitState
    }

    //  override by subclasses of Modem
    @objc(setIgnoreNewline:)
    func setIgnoreNewline(_ state: Bool) {
    }

    //  override by subclasses of Modem
    @objc(inputAttenuator:)
    func inputAttenuator(_ config: ModemConfig!) -> NSSlider! {
        return nil
    }

    //  override from subclasses that import directly into the mode
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
    }

    //  first recipient of the audio stream for this modem
    @objc(dataClient)
    func dataClient() -> CMTappedPipe! {
        print("\(ident ?? "") did not implement -dataClient")
        return nil
    }

    //  override by modem instances to turn modem on or off
    @objc(enableModem:)
    func enableModem(_ state: Bool) {
    }

    @objc(setVisibleState:)
    func setVisibleState(_ visible: Bool) {
        config?.updateVisibleState?(visible)
    }

    //  called from ModemConfig
    @objc(activeChanged:)
    func activeChanged(_ f: ModemConfig!) {
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences!) {
    }

    //  override by subclasses of Modem
    @objc func updateSourceFromConfigInfo() {
        print("\(ident ?? "") did not implement -updateSourceFromConfigInfo")
    }

    //  subclasses override this to keep (e.g. PSK) transmission alive
    @objc func shouldEndTransmission() -> Bool {
        return true
    }

    @objc func incrementTransmitCount() {
        transmitCountLock?.lock()
        transmitCount += 1
        transmitCountLock?.unlock()
    }

    @objc func decrementTransmitCount() {
        transmitCountLock?.lock()
        transmitCount -= 1
        transmitCountLock?.unlock()
    }

    @objc func clearTransmitCount() {
        transmitCountLock?.lock()
        transmitCount = 0
        transmitCountLock?.unlock()
    }

    //  v0.87 set microHAM keyerMode when a new modem interface is switched in
    @objc func switchModemIn() {
        print("Modem.m: switchModemIn (should override in subclass")
    }

    //  v00.89
    @objc func flushClickBuffer() {
    }

    //  ModemManager calls cleanup to all modems when app is terminating.
    @objc func applicationTerminating() {
        config?.applicationTerminating?()
    }

    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences!) -> Bool {
        plistHasBeenUpdated = true
        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences!) {
        //  default to no tooltips
        manager?.clearToolTips(inView: view as? NSView)
    }

    @objc func tabItem() -> NSTabViewItem! {
        return modemTabItem
    }

    @objc func isActiveTab() -> Bool {
        return manager?.activeTabView() === modemTabItem
    }

    //  -[Modem ptt:] -- exposed as executePTT(_:) (selector `ptt:` preserved)
    @objc(ptt:)
    func executePTT(_ state: Bool) {
        ptt?.executePTT(state)
    }

    @objc func checkIfCanTransmit() -> Bool {
        return true
    }

    //  override by subclasses of Modem
    @objc(changeTransmitStateTo:)
    func changeTransmitStateTo(_ state: Bool) {
    }

    //  override by ContestInterface
    @objc func transmissionEnded() {
    }

    @objc func removeToolTips() {
        manager?.clearToolTips(inView: view as? NSView)
    }

    @objc(useSlashedZero:)
    func useSlashedZero(_ state: Bool) {
        slashZero = state
    }

    //  override in modem implementations
    @objc(enterTransmitMode:)
    func enterTransmitMode(_ state: Bool) {
    }

    @objc func flushAndLeaveTransmit() {
    }

    @objc(transmittedCharacter:)
    func transmittedCharacter(_ ch: Int32) {
    }

    @objc func sendMessageImmediately() {
    }

    //  override in modem implementations that use waterfalls
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID index: Int32) {
    }

    @objc(turnOffReceiver:option:)
    func turnOffReceiver(_ ident: Int32, option: Bool) {
    }

    @objc(getCallsignString:from:)
    func getCallsignString(_ textView: NSTextView!, from selectedRange: NSRange) -> NSRange {
        var start = 0, end = 0, limit = 0, length = 0, ch = 0
        if getCallLock?.`try`() == true {
            let loc = selectedRange.location
            if loc > 0 {
                //  ExchangeView moves the cursor from the end -- ignore locations from a cleared buffer
                if let string = textView.textStorage?.string as NSString? {
                    length = string.length
                    if loc < length {
                        //  check if clicked character is a callsign character
                        if callChar[Int(string.character(at: loc)) & 0xff] == 0 {   // masked (was raw unichar)
                            getCallLock?.unlock()
                            return NSRange(location: 0, length: 0)
                        }
                        limit = loc - 13
                        if limit < 0 { limit = 0 }
                        start = loc
                        while start >= limit {
                            ch = Int(string.character(at: start)) & 0xff
                            if callChar[ch] == 0 { break }
                            start -= 1
                        }
                        start += 1
                        limit = start + 15
                        if limit > length { limit = length }
                        end = start
                        while end < limit {
                            ch = Int(string.character(at: end)) & 0xff
                            if callChar[ch] == 0 { break }
                            end += 1
                        }
                        end -= 1

                        length = end - start + 1
                        if length < 3 { start = 0; length = 0 }     // too short to be callsign
                        getCallLock?.unlock()
                        return NSRange(location: start, length: length)
                    }
                }
            }
        }
        return NSRange(location: 0, length: 0)
    }

    @objc func managerObject() -> ModemManager! {
        return manager
    }

    @objc(getExchangeString:from:)
    func getExchangeString(_ textView: NSTextView!, from selectedRange: NSRange) -> NSRange {
        var start = 0, end = 0, limit = 0, length = 0, ch = 0
        let loc = selectedRange.location
        if loc > 0 {
            if let string = textView.textStorage?.string as NSString? {
                length = string.length
                if loc < length {
                    //  check if clicked character is an exchange character
                    ch = Int(string.character(at: loc)) & 0xff        // masked (was raw unichar)
                    if exchChar[ch] == 0 { return NSRange(location: 0, length: 0) }
                    limit = loc - 13
                    if limit < 0 { limit = 0 }
                    start = loc
                    while start >= limit {
                        ch = Int(string.character(at: start)) & 0xff
                        if exchChar[ch] == 0 { break }
                        start -= 1
                    }
                    start += 1
                    limit = start + 15
                    if limit > length { limit = length }
                    end = start
                    while end < limit {
                        ch = Int(string.character(at: end)) & 0xff
                        if exchChar[ch] == 0 { break }
                        end += 1
                    }
                    end -= 1

                    length = end - start + 1
                    if length <= 0 { return NSRange(location: 0, length: 0) }   // too short
                    return NSRange(location: start, length: length)
                }
            }
        }
        return NSRange(location: 0, length: 0)
    }

    @objc(upperCase:into:)
    func upperCase(_ string: String!, into cstr: UnsafeMutablePointer<CChar>!) {
        let ns = (string ?? "") as NSString
        let n = ns.length
        guard let src = ns.cString(using: String.Encoding.isoLatin1.rawValue) else {
            cstr[30] = 0
            return
        }
        if n > 30 {
            //  too long to worry about
            _ = strncpy(cstr, src, 30)
        } else {
            _ = strcpy(cstr, src)
            for i in 0..<n {
                let v = Int(cstr[i]) & 0xff                              // v0.25
                if v == 216 || v == 175 {           // slashed zero
                    cstr[i] = CChar(UInt8(ascii: "0"))
                } else if v >= 0x61 && v <= 0x7a {  // 'a'..'z'
                    cstr[i] = CChar(v - 32)
                }
            }
        }
        cstr[30] = 0
    }

    @objc(keyModifierChanged:)
    func keyModifierChanged(_ notify: Notification!) {
        let flags = (notify.object as? Application)?.keyboardModifierFlags() ?? 0
        controlKeyState = (flags & UInt32(NSEvent.ModifierFlags.control.rawValue)) != 0
        shiftKeyState   = (flags & UInt32(NSEvent.ModifierFlags.shift.rawValue)) != 0
        optionKeyState  = (flags & UInt32(NSEvent.ModifierFlags.option.rawValue)) != 0
    }

    //  similar to the textView:willChangeSelectionFromCharacterRange: delegate
    @objc(captureCallsign:willChangeSelectionFromCharacterRange:toCharacterRange:)
    func captureCallsign(_ textView: NSTextView!, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange, toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        //  select callsign field if control-click or right click
        if (textView as? ExchangeView)?.getAndClearRightMouse() == true {
            //  only handle simple clicks without dragging
            if newSelectedCharRange.length > 0 { return oldSelectedCharRange }
            let range = getCallsignString(textView, from: newSelectedCharRange)
            if range.length <= 0 { return oldSelectedCharRange }

            if let storage = textView.textStorage {
                let string = storage.attributedSubstring(from: range).string
                if string.count < 32 {
                    upperCase(string, into: captured)
                    NotificationCenter.default.post(name: NSNotification.Name("CapturedCallsign"), object: self)
                }
            }
            return range
        }
        return newSelectedCharRange
    }

    //  capture the current text selection
    @objc(captureSelection:)
    func captureSelection(_ textView: NSTextView!) {
        let range = textView.selectedRange()
        if range.length > 0 {
            if let storage = textView.textStorage {
                let string = storage.attributedSubstring(from: range).string
                manager?.appObject()?.saveSelectedString(string, view: textView)
            }
        }
    }

    //  ---- AppleScript support ----

    @objc func spectrumPosition() -> NSAppleEventDescriptor! {
        let desc = NSAppleEventDescriptor.list()
        desc.insert(NSAppleEventDescriptor(int32: 0), at: 1)
        desc.insert(NSAppleEventDescriptor(int32: 0), at: 2)
        return desc
    }

    @objc(setSpectrumPosition:)
    func setSpectrumPosition(_ point: NSAppleEventDescriptor!) {
    }

    //  respond to a select <modem> command
    @objc(selectModem:)
    func selectModem(_ command: NSScriptCommand!) {
        _ = manager?.selectModem(self)
    }

    //  poll the transceivers (round robin)
    @objc(scriptStream) func scriptStream() -> String! {
        var g = ""
        if transceivers <= 0 { return g }
        lastPolledTransceiver = (lastPolledTransceiver &+ 1) % transceivers
        for i in 0..<transceivers {
            let index = (i &+ lastPolledTransceiver) % transceivers
            if index == 0 {
                if let received = transceiver1?.getStream(), received.count > 0 {
                    g = "[1]" + received
                    break
                }
            } else {
                if let received = transceiver2?.getStream(), received.count > 0 {
                    g = "[2]" + received
                    break
                }
            }
        }
        return g
    }

    @objc(setStream:)
    func setStream(_ text: String!) {
        guard let cptr = (text as NSString?)?.cString(using: String.Encoding.isoLatin1.rawValue) else { return }
        //  duplicate into a mutable buffer (original cast the const cString to char*)
        guard let s = strdup(cptr) else { return }
        defer { free(s) }
        var index: Int32 = 0
        var t = s
        if strlen(s) > 2 && s[0] == 0x5b /* [ */ && s[2] == 0x5d /* ] */ && (s[1] == 0x31 || s[1] == 0x32) {
            t = s + 3
            index = Int32(s[1] - 0x31)
        }
        if index >= transceivers { return }
        if index == 0 { transceiver1?.sendStream(t) } else { transceiver2?.sendStream(t) }
    }

    @objc(selectTransceiver:andChangeTransmitStateTo:)
    func selectTransceiver(_ transceiver: Transceiver!, andChangeTransmitStateTo transmit: Bool) {
        //  default to single transceiver case
        enterTransmitMode(transmit)
    }

    //  v0.56
    @objc func selectedTransceiver() -> Int32 {
        return 1
    }

    //  AppleScript support (callbacks from Modules)
    @objc(frequencyFor:)
    func frequencyFor(_ module: Module!) -> Float {
        return 0.0
    }

    @objc(setFrequency:module:)
    func setFrequency(_ freq: Float, module: Module!) {
    }

    @objc(setTimeOffset:index:)
    func setTimeOffset(_ offset: Float, index: Int32) {
    }

    @objc(markFor:)
    func markFor(_ module: Module!) -> Float {
        return frequencyFor(module)
    }

    @objc(setMark:module:)
    func setMark(_ freq: Float, module: Module!) {
        setFrequency(freq, module: module)
    }

    @objc(spaceFor:)
    func spaceFor(_ module: Module!) -> Float {
        return frequencyFor(module)
    }

    @objc(setSpace:module:)
    func setSpace(_ freq: Float, module: Module!) {
        setFrequency(freq, module: module)
    }

    @objc(baudFor:)
    func baudFor(_ module: Module!) -> Float {
        return 45.45
    }

    @objc(setBaud:module:)
    func setBaud(_ rate: Float, module: Module!) {
    }

    @objc(invertFor:)
    func invertFor(_ module: Module!) -> Bool {
        return false
    }

    @objc(setInvert:module:)
    func setInvert(_ state: Bool, module: Module!) {
    }

    @objc(breakinFor:)
    func breakinFor(_ module: Module!) -> Bool {
        return false
    }

    @objc(setBreakin:module:)
    func setBreakin(_ state: Bool, module: Module!) {
    }

    @objc(checkEnable:)
    func checkEnable(_ transceiver: Transceiver!) -> Bool {
        let configp = configObj((transceiver === transceiver2) ? 1 : 0)
        return configp?.soundInputActive() ?? false
    }

    @objc(setEnable:to:)
    func setEnable(_ transceiver: Transceiver!, to sense: Bool) {
        let configp = configObj((transceiver === transceiver2) ? 1 : 0)
        configp?.setSoundInputActive(sense)
    }

    //  override by non RTTY subclasses
    @objc(modulationCodeFor:)
    func modulationCode(for transceiver: Transceiver!) -> Int32 {
        //  default reply to 45 baud RTTY
        return Int32(ModulationRTTY45)
    }

    @objc(setModulationCodeFor:to:)
    func setModulationCode(for transceiver: Transceiver!, to code: Int32) {
    }

    //  override by subclasses to transmit a string
    @objc(transmitString:)
    func transmitString(_ s: UnsafePointer<CChar>!) {
    }

    @objc func showConfigPanel() {
        //  turn off transmit and open config panel
        if transmitState { changeTransmitStateTo(false) }
        config?.openPanel?()
    }

    //  v0.64c -- open config panel from AppleScript
    @objc func openConfigPanel() -> Bool {
        showConfigPanel()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @objc func closeConfigPanel() {
        config?.closePanel?()
    }

    @objc(waterfallBuffer:)
    func waterfallBuffer(_ index: Int32) -> UnsafeMutablePointer<Float>! {
        if waterfallConsumer == waterfallProducer { return nil }
        let row = Int(waterfallConsumer & kWaterfallBufferMask)
        let p = waterfallBufferStore + row * kWaterfallRowLength
        waterfallConsumer = (waterfallConsumer &+ 1) & kWaterfallBufferMask
        return p
    }

    //  waterfall.m calls back with a 1024 sample floating point buffer
    @objc(newFFTBuffer:)
    func newFFTBuffer(_ buffer: UnsafeMutablePointer<Float>) {
        let row = Int(waterfallProducer & kWaterfallBufferMask)
        let p = waterfallBufferStore + row * kWaterfallRowLength
        for i in 0..<kWaterfallRowLength {
            p[i] = buffer[i]
        }
        waterfallTouched = -(waterfallDate?.timeIntervalSinceNow ?? 0)       // v0.82
        waterfallProducer = (waterfallProducer &+ 1) & kWaterfallBufferMask
    }

    //  milliseconds to wait before the client polls for the next spectrum scanline
    @objc func nextWaterfallScanline() -> Int32 {
        if waterfallConsumer != waterfallProducer {
            NSLog("nextWaterfallScanline ***\n")
            return 0
        }
        let elapsed = -(waterfallDate?.timeIntervalSinceNow ?? 0) - waterfallTouched
        NSLog("nextWaterfallScanline %f\n", (0.374 - elapsed) * 1000)
        if elapsed > 0.374 { return 374 }
        return Int32((0.374 - elapsed) * 1000)
    }

    //  0.64c AppleScript to reset watchdog timer
    @objc func resetWatchdog() {
        charactersSinceTimerStarted += 1
    }

    //  v0.64c - show controls AppleScript
    @objc(setShowControls:)
    func setShowControls(_ state: Bool) {
    }

    @objc(setShowSpectrum:)
    func setShowSpectrum(_ state: Bool) {
    }

    @objc func controlsPosition() -> NSAppleEventDescriptor! {
        let desc = NSAppleEventDescriptor.list()
        desc.insert(NSAppleEventDescriptor(int32: 0), at: 1)
        desc.insert(NSAppleEventDescriptor(int32: 0), at: 2)
        return desc
    }

    @objc(setControlsPosition:)
    func setControlsPosition(_ point: NSAppleEventDescriptor!) {
    }

    //  v0.96c
    @objc(selectView:)
    func selectView(_ index: Int32) {
    }
}
