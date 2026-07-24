//
//  RTTYInterface.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/17/05.
//  Swift port of RTTYInterface.m / RTTYInterface.h.
//
//  Base RTTY modem.  The single (RTTY) and dual (DualRTTY) implementations, as
//  well as WFRTTY -> ASCII / LiteRTTY / SITOR / WBCW, are sub-classed from this.
//  The RTTYInterface owns two RTTYTransceivers; for single RTTY only the `a`
//  transceiver is marked isAlive.
//
//	(RTTYInterface : ContestInterface : MacroInterface : Modem)
//
//  Port notes:
//   * Every original ivar is an `internal` stored property with its EXACT original
//     name.  The two RTTYTransceivers (`a`, `b`) are Swift reference-type instances
//     (RTTYTransceiver is defined in Modem.swift); `&a`/`&b` become `a`/`b`, and
//     `client->control` becomes `client.control`.
//   * `isASCIIModem`, `bitsPerCharacter` and `microKeyerSetupField` each unify an
//     ivar with a same-named accessor into one @objc property.
//   * Still-Objective-C collaborators reached via informal @objc protocols (the
//     RTTYRxControl frequency/invert/baud accessors and the transmit-light view's
//     setBackgroundColor:) so the exact selectors dispatch regardless of any Clang
//     name-mangling.  config / txConfig are cast to their (bridged) concrete types
//     RTTYConfig / RTTYTxConfig.
//

import Cocoa

//  Phi (slashed-zero glyph) was #define Phi 0xd8 in cocoaModemParams.h.
private let Phi: Int32 = 0xd8

//  Informal access to the still-Objective-C RTTYRxControl accessors (explicit
//  selectors so dispatch is exact).
@objc private protocol RTTYRxControlOps {
    @objc(setTuningIndicatorState:) func setTuningIndicatorState(_ active: Bool)
    @objc(markFrequencyForMask:) func markFrequency(forMask mask: Int32) -> Float
    @objc(spaceFrequencyForMask:) func spaceFrequency(forMask mask: Int32) -> Float
    @objc(setMarkFrequency:mask:) func setMarkFrequency(_ f: Float, mask: Int32)
    @objc(setSpaceFrequency:mask:) func setSpaceFrequency(_ f: Float, mask: Int32)
    @objc(invertStateForReceiver) func invertStateForReceiver() -> Bool
    @objc(invertStateForTransmitter) func invertStateForTransmitter() -> Bool
    @objc(setInvertStateForReceiver:) func setInvertStateForReceiver(_ state: Bool)
    @objc(setInvertStateForTransmitter:) func setInvertStateForTransmitter(_ state: Bool)
    @objc(baudRate) func baudRate() -> Float
    @objc(setBaudRate:) func setBaudRate(_ rate: Float)
}

//  The transmit-light indicator is an `id` outlet; only -setBackgroundColor: is used.
@objc private protocol RTTYLightInformal {
    @objc func setBackgroundColor(_ color: NSColor?)
}

@objc(RTTYInterface)
class RTTYInterface: ContestInterface {

    //  --- IBOutlets (id) ---
    @objc var transmitButton: AnyObject!
    @objc var transmitLight: AnyObject!
    @objc var breakinButton: AnyObject!

    @objc var isBreakin: Bool = false
    @objc var breakinTimer: Timer!
    @objc var breakinTimeout: Int32 = 0         //  passes in the timer where there was no character

    @objc var currentRxView: ExchangeView!
    //  RTTY Prefs
    @objc var usos: Bool = false
    @objc var bell: Bool = false
    @objc var robust: Bool = false
    let a = RTTYTransceiver()
    let b = RTTYTransceiver()

    @objc var thread: Thread!
    @objc var microKeyerSetupField: NSTextField!    //  unifies ivar + -microKeyerSetupField

    //  transmit
    @objc var transmitChannel: Int32 = 0
    @objc var transmitViewLock: NSLock!
    @objc var transmitBufferCheck: Timer!
    @objc var indexOfUntransmittedText: Int32 = 0
    //  macros
    @objc var alwaysAllowMacro: Int32 = 0

    //  v0.83
    @objc var isASCIIModem: Bool = false            //  unifies ivar + -isASCIIModem
    @objc var bitsPerCharacter: Int32 = 0           //  unifies ivar + -bitsPerCharacter

    //  =======================================================================

    //  Expose the base nib-loading designated initialiser to subclasses.  A
    //  class that adds its own designated init loses automatic inheritance of
    //  the superclass's other designated inits, so this forwarder is required
    //  for WFRTTY / RTTY / DualRTTY to pass their own nib name up the chain.
    override init?(into tabview: NSTabView!, nib: String!, manager mgr: ModemManager!) {
        super.init(into: tabview, nib: nib, manager: mgr)
    }

    @objc(initIntoTabView:manager:)
    init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        super.init(into: tabview, nib: "RTTY", manager: mgr)
        isASCIIModem = false
        bitsPerCharacter = 5
        transmitViewLock = NSLock()
    }

    //  NSMatrix of NSButtons from Preferences
    @objc(setRTTYPrefs:channel:)
    func setRTTYPrefs(_ rttyPrefs: NSMatrix!, channel: Int32) {
        let rx: RTTYReceiver! = (channel == 0) ? a.receiver : b.receiver
        let count = rttyPrefs.numberOfRows
        if count > 1 {
            for i in 0..<count {
                let button = rttyPrefs.cell(atRow: i, column: 0) as? NSButtonCell
                if button?.state == .on {
                    switch i {
                    case 0:
                        //  Unshift On Space
                        usos = true
                        if channel == 0 { (txConfig as? RTTYTxConfig)?.setUSOS(true) }   //  v0.84
                        rx?.setUSOS(usos)
                    case 1:
                        //  Disable Baudot BELL
                        bell = false
                        rx?.setBell(bell)
                    case 2:
                        robust = true
                        if channel == 0 { (txConfig as? RTTYTxConfig)?.afskObj()?.setRobustMode(robust) }
                    default:
                        break
                    }
                } else {
                    switch i {
                    case 0:
                        //  Unshift On Space
                        usos = false
                        if channel == 0 { (txConfig as? RTTYTxConfig)?.setUSOS(false) }
                        rx?.setUSOS(usos)
                    case 1:
                        //  Don't disable Baudot BELL
                        bell = true
                        rx?.setBell(bell)
                    case 2:
                        robust = false
                        if channel == 0 { (txConfig as? RTTYTxConfig)?.afskObj()?.setRobustMode(robust) }
                    default:
                        break
                    }
                }
            }
        } else {
            //  v0.83 -- ASCII RTTY
            usos = false
            let button = rttyPrefs.cell(atRow: 0, column: 0) as? NSButtonCell
            if button?.state == .on {
                //  Disable Baudot BELL
                bell = false
                rx?.setBell(bell)
            } else {
                //  Don't disable Baudot BELL
                bell = true
                rx?.setBell(bell)
            }
        }
    }

    @objc override func updateMacroButtons() {
        manager?.updateRTTYMacroButtons()       //  updates both RTTY and DualRTTY buttons
    }

    @objc(insertTransmittedCharacter:)
    func insertTransmittedCharacter(_ c: Int32) {
        var buffer = [CChar](repeating: 0, count: 2)
        buffer[0] = CChar(truncatingIfNeeded: c)
        buffer[1] = 0
        buffer.withUnsafeMutableBufferPointer { currentRxView?.append($0.baseAddress!) }
        manager?.appObject()?.addToVoice(c, channel: 0)     //  v0.96d voice synthesizer
        if transmitChannel == 0 { a.transmitModule?.insertBuffer(c) } else { b.transmitModule?.insertBuffer(c) }
    }

    //  callback from AFSK generator
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

    //  this gets periodically called when transmitting
    @objc(timedOut:)
    func timedOut(_ timer: Timer!) {
        if charactersSinceTimerStarted == 0 {
            //  timed out!
            Messages.logMessage("watchdog timer timed out ")    //  v0.65
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
        if let storage = transmitView?.textStorage {
            let total = Int32(storage.length)
            if total > 0 {
                if indexOfUntransmittedText < 0 {
                    indexOfUntransmittedText = total
                }
                if indexOfUntransmittedText < total {
                    let string = storage.string as NSString
                    while indexOfUntransmittedText < total {
                        let uch = string.character(at: Int(indexOfUntransmittedText))
                        indexOfUntransmittedText += 1
                        (txConfig as? RTTYTxConfig)?.transmitCharacter(Int32(uch))
                        charactersSinceTimerStarted += 1
                    }
                }
            }
        }
        clearTuningIndicators()
        transmitBufferCheck = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(checkTransmitBuffer(_:)), userInfo: self, repeats: true)   //  v0.65
    }

    //  v0.65 -- defer transmit cancel until the text view has finished
    @objc(delayTransmitCancel:)
    func delayTransmitCancel(_ timer: Timer!) {
        if transmitBufferCheck != nil { transmitBufferCheck.invalidate() }
        transmitBufferCheck = nil
        executePTT(false)
        transmitCountLock?.lock()
        transmitCount = 0
        transmitCountLock?.unlock()
        let indicatorColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
        setSentColor(false)
        transmitView?.select()
        a.receiver?.enableReceiver(true)
        if b.isAlive { b.receiver?.enableReceiver(true) }
        transmitLight?.setBackgroundColor?(indicatorColor)
    }

    @objc(checkTransmitBuffer:)
    func checkTransmitBuffer(_ timer: Timer!) {
        if let storage = transmitView?.textStorage {
            let total = Int32(storage.length)
            if total > 0 {
                if indexOfUntransmittedText < 0 { indexOfUntransmittedText = total }
                if indexOfUntransmittedText < total {
                    let string = storage.string as NSString
                    while indexOfUntransmittedText < total {
                        let uch = string.character(at: Int(indexOfUntransmittedText))
                        indexOfUntransmittedText += 1
                        (txConfig as? RTTYTxConfig)?.transmitCharacter(Int32(uch))
                        charactersSinceTimerStarted += 1
                    }
                }
            }
        }
    }

    //  select an input BPF
    @objc(selectBandwidth:)
    func selectBandwidth(_ index: Int32) {
        a.receiver?.selectBandwidth(index)
        if b.isAlive { b.receiver?.selectBandwidth(index) }
    }

    //  v0.87
    @objc override func switchModemIn() {
        (config as? RTTYConfig)?.setKeyerMode()
    }

    //  select a Demodulator
    @objc(selectDemodulator:)
    func selectDemodulator(_ index: Int32) {
        a.receiver?.selectDemodulator(index)
        if b.isAlive { b.receiver?.selectDemodulator(index) }
    }

    @objc func clearTuningIndicators() {
        (a.control as AnyObject?)?.setTuningIndicatorState?(false)
        if b.isAlive { (b.control as AnyObject?)?.setTuningIndicatorState?(false) }
    }

    @objc(demodulatorModeChanged:)
    func demodulatorModeChanged(_ sender: Any!) {
        selectDemodulator(Int32((sender as? NSMatrix)?.selectedColumn ?? 0))
    }

    @objc(enableModem:)
    override func enableModem(_ active: Bool) {
        a.receiver?.enableReceiver(active)
        if b.isAlive { b.receiver?.enableReceiver(active) }

        if active == true {
            if contestManager != nil {
                contestManager.setActiveContestInterface(self)
            }
            //  setup repeating macro bar
            if contestBar != nil {
                alwaysAllowMacro = 1                                             //  v0.33
                contestBar.setModem(manager?.currentModem() as? ContestInterface)   //  v0.33
                updateContestMacroButtons()
            }
        }
    }

    @objc(setVisibleState:)
    override func setVisibleState(_ visible: Bool) {
        (config as? RTTYConfig)?.updateVisibleState(visible)
        super.setVisibleState(visible)          //  v0.33 bug
    }

    //  overrides the one in modem.m so we can also inform the RTTYReceiver
    @objc(useSlashedZero:)
    override func useSlashedZero(_ state: Bool) {
        slashZero = state
        a.receiver?.setSlashZero(slashZero)
        if b.isAlive { b.receiver?.setSlashZero(slashZero) }
    }

    //  override by subclasses that need it
    @objc(tonePairChanged:)
    func tonePairChanged(_ control: RTTYRxControl!) {
    }

    //  v0.65 -- move this to the main thread so the cancel timer runs from the main run loop
    @objc func finishTransmitStateChange() {
        if transmitState == true {
            executePTT(true)
            let indicatorColor = NSColor.red
            transmitView?.window?.makeFirstResponder(transmitView)
            if timeout != nil { timeout.invalidate() }
            charactersSinceTimerStarted = 0
            if manager?.useWatchdog() == true {
                timeout = Timer.scheduledTimer(timeInterval: 150, target: self, selector: #selector(timedOut(_:)), userInfo: self, repeats: true)
            }
            transmitBufferCheck = nil
            a.receiver?.enableReceiver(false)
            if b.isAlive { b.receiver?.enableReceiver(false) }
            //  set text color in receive view and turn on transmit (v0.65 delay 0.3 sec)
            Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(delayTransmit(_:)), userInfo: self, repeats: false)
            transmitLight?.setBackgroundColor?(indicatorColor)

            flushClickBuffer()                  //  v0.89
        } else {
            if timeout != nil { timeout.invalidate() }
            timeout = nil
            //  v0.65 defer transmit cancel
            Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(delayTransmitCancel(_:)), userInfo: self, repeats: false)
        }
    }

    @objc(ook:)
    func ook(_ configr: RTTYConfig!) -> Int32 {
        return configr?.ook() ?? 0
    }

    //  v0.88b
    @objc(changeAuralTransmitStateTo:)
    func changeAuralTransmitStateTo(_ state: Bool) {
        let fsk = (config as? RTTYConfig)?.fsk
        let ookValue = ook(config as? RTTYConfig)

        //  transmitType = 0:AFSK, 1:FSK, 2:OOK
        var transmitType: Int32
        if ookValue != 0 {
            transmitType = 2
        } else {
            if fsk == nil { transmitType = 0 } else { transmitType = ((fsk?.useSelectedPort() ?? 0) <= 0) ? 0 : 1 }
        }
        a.receiver?.rttyAuralMonitor?.setTransmitState(state, transmitType: transmitType)     //  v0.88b
        transmitState = (txConfig as? RTTYTxConfig)?.turnOnTransmission(state, button: transmitButton as? NSButton, fsk: fsk, ook: ook(config as? RTTYConfig)) ?? false    //  v0.85

        //  v0.65 switch to main thread so the timers fire from the main run loop
        performSelector(onMainThread: #selector(finishTransmitStateChange), with: nil, waitUntilDone: true)
    }

    @objc(changeTransmitStateTo:)
    override func changeTransmitStateTo(_ state: Bool) {
        let fsk = (config as? RTTYConfig)?.fsk

        transmitState = (txConfig as? RTTYTxConfig)?.turnOnTransmission(state, button: transmitButton as? NSButton, fsk: fsk, ook: ook(config as? RTTYConfig)) ?? false    //  v0.85

        //  v0.65 switch to main thread so the timers fire from the main run loop
        performSelector(onMainThread: #selector(finishTransmitStateChange), with: nil, waitUntilDone: true)
    }

    //  this overrides the method in Modem.m that is called from the app
    @objc(enterTransmitMode:)
    override func enterTransmitMode(_ state: Bool) {
        if state != transmitState {
            if state == true {
                //  immediately change state to transmit
                changeTransmitStateTo(state)
            } else {
                transmitView?.insertInTextStorage("\u{05}")     //  ^E
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
        (txConfig as? RTTYTxConfig)?.flushTransmitBuffer()
    }

    //  this overrides the method in Modem.m that is called from the app
    @objc override func flushAndLeaveTransmit() {
        flushOutput()
        changeTransmitStateTo(false)
    }

    @objc override func sendMessageImmediately() {
        transmitCountLock?.lock()
        transmitCount += 1
        transmitCountLock?.unlock()
    }

    //  return the transceiver that is assigned as the active transmitter
    func transmittingTransceiver() -> RTTYTransceiver {
        return (transmitChannel == 0) ? a : b
    }

    @objc func transmitButtonChanged() {
        let state = ((transmitButton as? NSButton)?.state == .on)

        if state == false {
            //  enter a %[rx] character into the stream
            transmitView?.insertAtEnd("\u{05}")     //  ^E
            transmitLight?.setBackgroundColor?(NSColor.yellow)
        } else {
            changeTransmitStateTo(state)
        }
    }

    @objc(transmitString:)
    override func transmitString(_ s: UnsafePointer<CChar>!) {
        guard var p = s else { return }
        while p.pointee != 0 {
            let uch = unichar(truncatingIfNeeded: Int(p.pointee))
            (txConfig as? RTTYTxConfig)?.transmitCharacter(Int32(uch))
            p = p.advanced(by: 1)
        }
    }

    //  in contest interface
    @objc(flushContestBuffer:)
    func flushContestBuffer(_ sender: Any!) {
        flushAndLeaveTransmit()
        contestBar?.cancel()
    }

    @objc(flushTransmitStream:)
    func flushTransmitStream(_ sender: Any!) {
        flushOutput()
    }

    //  Delegate of receiveView and transmitView
    @objc(textView:shouldChangeTextInRange:replacementString:)
    func textView(_ textView: NSTextView, shouldChangeTextIn original: NSRange, replacementString replace: String?) -> Bool {
        let replaceLen = (replace as NSString?)?.length ?? 0

        if replaceLen == 0 && transmitState == true { return false }    //  v0.56 allow editing if not in transmit

        if textView === receiveView {
            if replaceLen != 0 {
                NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                Messages.alert(withMessageText: NSLocalizedString("text is write only", comment: ""), informativeText: NSLocalizedString("cannot insert text", comment: ""))
                return false
            }
            return true
        }
        if textView === transmitView {
            if slashZero {
                guard let sp = (replace as NSString?)?.cString(using: String.Encoding.isoLatin1.rawValue) else {
                    Messages.alertWithHiraganaError()
                    return false
                }
                var hasZero = false
                var i = 0
                while sp[i] != 0 { if sp[i] == 0x30 { hasZero = true }; i += 1 }
                if hasZero {
                    let length = Int(strlen(sp))
                    if length < 32 {
                        var replacement = [CChar](repeating: 0, count: length + 1)
                        for j in 0..<length {
                            replacement[j] = (sp[j] == 0x30) ? CChar(truncatingIfNeeded: Phi) : sp[j]
                        }
                        //  replace zeros with phi and try again
                        if let newStr = replacement.withUnsafeBufferPointer({ ptr -> String? in
                            NSString(bytes: ptr.baseAddress!, length: length, encoding: String.Encoding.isoLatin1.rawValue) as String?
                        }) {
                            transmitView?.replaceCharacters(in: original, with: newStr)
                        }
                        return false
                    }
                }
            }

            transmitViewLock?.lock()                //  removed in 0.64, added back in v0.65

            if let storage = transmitView?.textStorage {    //  sanity check v0.64c
                let total = Int32(storage.length)
                let start = Int32(original.location)
                let length = Int32(storage.attributedSubstring(from: original).length)   //  v0.65
                if length == total && replaceLen == 0 && transmitState == false {
                    transmitView?.clearAll()
                    indexOfUntransmittedText = 0
                    transmitViewLock?.unlock()
                    return false
                }
                if length > 0 {
                    if (start + length) == total {
                        if (total - length) < indexOfUntransmittedText {    //  deleting past the transmitted text v0.65
                            NSSound.beep()
                            transmitViewLock?.unlock()                      //  0.66
                            return false
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
                    if Int32(original.location) < indexOfUntransmittedText {
                        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                        Messages.alert(withMessageText: NSLocalizedString("text already sent", comment: ""), informativeText: NSLocalizedString("cannot insert after sending", comment: ""))
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
                        if Int32(original.location) < indexOfUntransmittedText {
                            //  attempt to insert into text that has already been transmitted
                            NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                            Messages.alert(withMessageText: NSLocalizedString("text already sent", comment: ""), informativeText: NSLocalizedString("cannot insert after sending", comment: ""))
                            transmitViewLock?.unlock()
                            return false
                        }
                        transmitViewLock?.unlock()
                        return true
                    }
                }
                //  inserting at the end of buffer (-checkTransmitBuffer will pick it up)
                if replaceLen != 0 {
                    transmitViewLock?.unlock()
                    return true
                }
            }
        }
        transmitViewLock?.unlock()
        return true
    }

    //  handle callsign clicks
    @objc(textView:willChangeSelectionFromCharacterRange:toCharacterRange:)
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange, toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        enableClick = false
        if textView === a.view || textView === b.view {

            //  cancel transmission if there is a repeating macro
            if contestBar != nil && alwaysAllowMacro <= 0 { contestBar.cancelIfRepeatingIsActive() }    //  v0.25, v0.33
            if alwaysAllowMacro > 0 { alwaysAllowMacro -= 1 }

            if textView.responds(to: #selector(ExchangeView.getRightMouse)) && (textView as? ExchangeView)?.getRightMouse() == true {    //  v0.32
                //  right clicked (contest QSO)
                if newSelectedCharRange.length == 0 {
                    if textView.lockFocusIfCanDraw() {
                        //  capture callsign can disable click so -textViewDidChangeSelection can ignore it
                        let range = captureCallsign(textView, willChangeSelectionFromCharacterRange: oldSelectedCharRange, toCharacterRange: newSelectedCharRange)
                        enableClick = (oldSelectedCharRange.location != range.location)
                        textView.unlockFocus()
                        return range
                    }
                    return newSelectedCharRange
                }
            }
        }
        return newSelectedCharRange
    }

    //  v0.32
    @objc(textViewDidChangeSelection:)
    func textViewDidChangeSelection(_ notify: Notification) {
        let obj = notify.object as AnyObject?
        if obj === a.view || obj === b.view {
            captureSelection(obj as? NSTextView)
        }
        if contestBar?.textInsertedFromRepeat() == true { return }   //  v0.33
        callsignClickSuccessful(enableClick)
    }

    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)
        // microKeyerSetupField = [ (Config*)pref microKeyerSetupField ] ; v0.89
    }

    // --- AppleScript support ---

    @objc(frequencyFor:)
    override func frequencyFor(_ module: Module!) -> Float {
        return markFor(module)
    }

    func transceiverForModule(_ module: Module!) -> RTTYTransceiver {
        var client = a
        if b.isAlive {
            let transceiver = module?.transceiver()
            if transceiver === transceiver2 { client = b }
        }
        return client
    }

    //  local
    @objc(setFrequency:module:)
    override func setFrequency(_ freq: Float, module: Module!) {
        setMark(freq, module: module)
    }

    @objc(markFor:)
    override func markFor(_ module: Module!) -> Float {
        let client = transceiverForModule(module)
        let control: AnyObject? = client.control
        if module?.isReceiver() == true {
            //  receiver tones
            return control?.markFrequency?(forMask: 1) ?? 0
        }
        //  transmitter mark tone (single RTTY)
        return control?.markFrequency?(forMask: 2) ?? 0
    }

    @objc(setMark:module:)
    override func setMark(_ freq: Float, module: Module!) {
        let client = transceiverForModule(module)
        let control: AnyObject? = client.control
        if module?.isReceiver() == true {
            let originalTransmitMark = control?.markFrequency?(forMask: 2) ?? 0
            let originalTransmitSpace = control?.spaceFrequency?(forMask: 2) ?? 0
            let originalReceiveSpace = control?.spaceFrequency?(forMask: 1) ?? 0

            //  receiver mark tone
            control?.setMarkFrequency?(freq, mask: 1)
            //  tones before change
            control?.setSpaceFrequency?(originalReceiveSpace, mask: 1)
            control?.setMarkFrequency?(originalTransmitMark, mask: 2)
            control?.setSpaceFrequency?(originalTransmitSpace, mask: 2)
        } else {
            //  transmitter mark tone
            control?.setMarkFrequency?(freq, mask: 2)
        }
    }

    @objc(spaceFor:)
    override func spaceFor(_ module: Module!) -> Float {
        let client = transceiverForModule(module)
        let control: AnyObject? = client.control
        if module?.isReceiver() == true {
            //  receiver tones
            return control?.spaceFrequency?(forMask: 1) ?? 0
        }
        //  transmitter space tone
        return control?.spaceFrequency?(forMask: 2) ?? 0
    }

    @objc(setSpace:module:)
    override func setSpace(_ freq: Float, module: Module!) {
        let client = transceiverForModule(module)
        let control: AnyObject? = client.control
        if module?.isReceiver() == true {
            let originalTransmitMark = control?.markFrequency?(forMask: 2) ?? 0
            let originalTransmitSpace = control?.spaceFrequency?(forMask: 2) ?? 0
            let originalReceiveMark = control?.markFrequency?(forMask: 1) ?? 0

            //  receiver space tone
            control?.setSpaceFrequency?(freq, mask: 1)
            //  tones before change
            control?.setMarkFrequency?(originalReceiveMark, mask: 1)
            control?.setMarkFrequency?(originalTransmitMark, mask: 2)
            control?.setSpaceFrequency?(originalTransmitSpace, mask: 2)
        } else {
            //  transmitter space tone
            control?.setSpaceFrequency?(freq, mask: 2)
        }
    }

    @objc(afskChanged:config:)
    func afskChanged(_ index: Int32, config cfg: RTTYConfig!) {
        //  override by wideband RTTY
    }

    @objc(baudFor:)
    override func baudFor(_ module: Module!) -> Float {
        if b.isAlive {
            let transceiver = module?.transceiver()
            if transceiver === transceiver2 { return (b.control as AnyObject?)?.baudRate?() ?? 0 }
        }
        return (a.control as AnyObject?)?.baudRate?() ?? 0
    }

    @objc(setBaud:module:)
    override func setBaud(_ rate: Float, module: Module!) {
        if b.isAlive {
            let transceiver = module?.transceiver()
            if transceiver === transceiver2 {
                (b.control as AnyObject?)?.setBaudRate?(rate)
                return
            }
        }
        (a.control as AnyObject?)?.setBaudRate?(rate)
    }

    @objc(invertFor:)
    override func invertFor(_ module: Module!) -> Bool {
        let client = transceiverForModule(module)
        let control: AnyObject? = client.control
        if module?.isReceiver() == true {
            //  receiver tones
            return control?.invertStateForReceiver?() ?? false
        }
        //  transmitter tone invert state
        return control?.invertStateForTransmitter?() ?? false
    }

    @objc(setInvert:module:)
    override func setInvert(_ state: Bool, module: Module!) {
        let client = transceiverForModule(module)
        let control: AnyObject? = client.control
        if module?.isReceiver() == true {
            control?.setInvertStateForReceiver?(state)
            return
        }
        //  transmitter tone invert state
        control?.setInvertStateForTransmitter?(state)
    }

    //  Application sends this through the ModemManager when quitting
    @objc override func applicationTerminating() {
        ptt?.applicationTerminating()       //  v0.89
    }

    //  applescript support

    //  v0.56
    @objc override func selectedTransceiver() -> Int32 {
        return transmitChannel + 1
    }
}
