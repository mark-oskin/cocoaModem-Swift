//
//  ContestInterface.swift
//  cocoaModem
//
//  Created by Kok Chen on 10/15/04.
//  Swift port of ContestInterface.m (originally titled ContestConfig.m) and
//  ContestInterface.h.
//
//  ContestInterface : MacroInterface.  Adds the contest QSO entry panel, the
//  callsign/exchange/extra field capture, the CQ / S&P mode toggle and the
//  repeating-macro ContestBar.  Base of RTTYInterface (and thus every RTTY-family
//  mode) as well as PSK, MFSK and Hellschreiber.
//
//  Port notes:
//   * Every original ivar is an `internal` stored property with its EXACT original
//     name so descendants resolve them across the module.
//   * `contestModeIndex` unifies the ivar and the same-named `-contestModeIndex`
//     accessor into one @objc property (the getter IS the method).
//   * Field-selector notification names CallNotify / ExchangeNotify /
//     ExtraFieldNotify are C string macros (@"SelectCallField" / @"SelectExchField"
//     / @"SelectExtraField" in cocoaModemParams.h); their literal values are used
//     directly here.  kCallsignTextField/kExchangeTextField/kExtraTextField and
//     kContestModeCQ are C int constants referenced directly.
//   * -initContest:master:manager: originally re-initialised a bare-alloc'd Contest
//     in place via -initIntoBox:...; Swift cannot re-run an initializer on an
//     existing instance, so a freshly initialised Contest is created here instead.
//     See report CONFLICT note (ContestManager still owns the alloc + addSubordinate).
//

import Cocoa

//  CQ/SP contest-mode constants (were #defines in the now-Swift Modem.h)
let kContestModeCQ: Int32 = 0
let kContestModeSP: Int32 = 3

@objc(ContestInterface)
class ContestInterface: MacroInterface {

    //  --- IBOutlets (id) ---
    @objc var contestTab: AnyObject!
    @objc var contestMode: AnyObject!           //  (CQ, S&P)
    @objc var contestView: AnyObject!
    @objc var contestMessageMatrix: AnyObject!
    @objc var contestDate: AnyObject!
    @objc var contestTime: AnyObject!

    @objc var mainRunLoop: RunLoop!

    @objc var modemClient: Modem!
    @objc var contest: Contest!
    @objc var master: Contest!
    @objc var contestManager: ContestManager!
    var contestBar: ContestBar!
    @objc var contestModeIndex: Int32 = 0       //  unifies ivar + -contestModeIndex
    @objc var inContestMode: Bool = false

    @objc var savedString: String!

    @objc var selectedField: Int32 = 0
    @objc var currentField: NSTextField!        //  the most recent field set from contest panel

    //  =======================================================================

    @objc(initIntoTabView:nib:manager:)
    override init?(into tabview: NSTabView!, nib: String!, manager mgr: ModemManager!) {
        super.init(into: tabview, nib: nib, manager: mgr)
        contestBar = nil
        savedString = ""
    }

    @objc(setClock:)
    func setClock(_ utcp: UTC!) {
        if contestDate != nil && contestTime != nil {
            let gmt = utcp.utc()
            (contestDate as? NSTextField)?.stringValue = String(format: "%02d-%02d-%02d", gmt.pointee.tm_mday, gmt.pointee.tm_mon + 1, (gmt.pointee.tm_year + 1900) % 100)
            (contestTime as? NSTextField)?.stringValue = String(format: "%02d:%02d", gmt.pointee.tm_hour, gmt.pointee.tm_min)
        }
    }

    @objc(timeTick:)
    func timeTick(_ notify: Notification!) {
        setClock(notify.object as? UTC)
    }

    @objc(callFieldSelected:)
    func callFieldSelected(_ notify: Notification!) {
        contestBar?.cancel()
        if self !== contestManager?.selectedContestInterface() { return }
        currentField = notify.object as? NSTextField
        selectedField = Int32(kCallsignTextField)
    }

    @objc(exchFieldSelected:)
    func exchFieldSelected(_ notify: Notification!) {
        contestBar?.cancel()
        if self !== contestManager?.selectedContestInterface() { return }
        currentField = notify.object as? NSTextField
        selectedField = Int32(kExchangeTextField)
    }

    @objc(extraFieldSelected:)
    func extraFieldSelected(_ notify: Notification!) {
        contestBar?.cancel()
        if self !== contestManager?.selectedContestInterface() { return }
        currentField = notify.object as? NSTextField
        selectedField = Int32(kExtraTextField)
    }

    @objc(initContest:master:manager:)
    func initContest(_ newContest: Contest!, master inMaster: Contest!, manager inManager: ContestManager!) {
        //  (oldContest release dropped under ARC)
        master = inMaster
        contestManager = inManager
        selectedField = 0
        //  Port: the original re-inited the passed-in Contest in place.  Swift creates
        //  a freshly initialised Contest instead (see file header / report).
        contest = Contest(intoBox: contestView as? NSBox, contestName: master?.contestName ?? "", prototype: master?.prototypeName ?? "", modem: self, master: inMaster, manager: contestManager)
        setClock(manager?.appObject()?.clock())
        if contestBar != nil { contestBar.setManager(contestManager) }
    }

    //  called from awakeFromNib of actual contests
    @objc func awakeFromContest() {
        currentSheet = 0
        contestModeIndex = Int32(kContestModeCQ)
        selectedField = 0
        inContestMode = false
        contest = nil
        master = nil
        contestManager = nil
        mainRunLoop = RunLoop.current
        if contestDate != nil && contestTime != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(timeTick(_:)), name: NSNotification.Name("MinuteTick"), object: nil)
        }
        //  CallNotify / ExchangeNotify / ExtraFieldNotify string macros
        NotificationCenter.default.addObserver(self, selector: #selector(callFieldSelected(_:)), name: NSNotification.Name("SelectCallField"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(exchFieldSelected(_:)), name: NSNotification.Name("SelectExchField"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(extraFieldSelected(_:)), name: NSNotification.Name("SelectExtraField"), object: nil)
    }

    @objc(keyModifierChanged:)
    override func keyModifierChanged(_ notify: Notification!) {
        contestBar?.cancel()
        super.keyModifierChanged(notify)
        //  option flag -- need to update macro button captions (same currentSheet as MacroInterface)
        updateContestMacroButtons()
    }

    @objc(selectContestMode:)
    func selectContestMode(_ state: Bool) {
        contestBar?.cancel()
        let whichView = (state == false) ? 0 : 1        //  normal = 0, contest = 1
        (contestTab as? NSTabView)?.selectTabViewItem(at: whichView)
        inContestMode = state
    }

    //  intercept call from Application to Modem
    //  usually occurs when the modem is switched by the tab in the interface window
    @objc(setVisibleState:)
    override func setVisibleState(_ visible: Bool) {
        contestBar?.cancel()
        super.setVisibleState(visible)
        if visible == true {
            if contestManager != nil {
                contestManager.setActiveContestInterface(self)
            }
            //  setup repeating macro bar
            if contestBar != nil { contestBar.setModem(self) }
            updateContestMacroButtons()
        }
    }

    @objc(setContestBar:)
    func setContestBar(_ bar: ContestBar!) {
        contestBar = bar
    }

    @objc override func transmissionEnded() {
        if contestBar != nil {
            //  need to perform as RunLoop performSelector... since transmissionEnded is
            //  called from an A/D converter thread
            if mainRunLoop != nil {
                mainRunLoop.perform(#selector(ContestBar.nextMacro(_:)), target: contestBar as Any, argument: self, order: 0, modes: [RunLoop.Mode.default])
            }
        }
    }

    @objc func updateContestMacroButtons() {
        contestBar?.cancel()
        if manager != nil {
            //  fetch matrix of current sheet's title
            let matrix = contestManager?.macroTitles(currentSheet + contestModeIndex)
            for i in 0..<8 {
                let field = matrix?.cell(atRow: i, column: 0)
                let string = field?.stringValue
                if contestMessageMatrix != nil {
                    if let button = (contestMessageMatrix as? NSMatrix)?.cell(atRow: 0, column: i) as? NSButtonCell {
                        if let s = string, !s.isEmpty {
                            button.title = s
                        } else {
                            button.title = "Mcr \(i + 1)"
                        }
                    }
                }
            }
        }
    }

    //  set up the contest bar for repeating the latest invoked macro
    @objc(newMacroForContestBar:sheet:)
    func newMacroForContestBar(_ index: Int32, sheet: Int32) {
        if contestBar != nil {
            contestBar.cancel()
            contestBar.newMacroCalled(index, sheet: sheet, manager: contestManager, modem: self)
        }
    }

    @objc(transmitContestMessage:)
    func transmitContestMessage(_ sender: Any!) {
        let index = Int32((sender as? NSMatrix)?.selectedColumn ?? 0)
        let sheet = currentSheet + contestModeIndex
        newMacroForContestBar(index, sheet: sheet)
        _ = contestManager?.executeContestMacro(index, sheet: sheet, modem: self)
    }

    @objc(showContestMacroSheet:)
    func showContestMacroSheet(_ sender: Any!) {
        if manager != nil {
            contestBar?.cancel()
            let sheet = currentSheet + contestModeIndex
            currentSheet = 0
            contestManager?.showContestMacroSheet(sheet)
        }
    }

    //  CQ/SP mode (kContestModeCQ=0, kContestModeSP=3)
    @objc(contestModeChanged:)
    func contestModeChanged(_ sender: Any!) {
        contestBar?.cancel()
        contestModeIndex = Int32((sender as? NSMatrix)?.selectedCell()?.tag ?? 0)
        let t = (contestModeIndex != 0) ? 0 : 1
        ((sender as? NSMatrix)?.cell(atRow: 0, column: t) as? NSButtonCell)?.state = .off
        ((sender as? NSMatrix)?.cell(atRow: 0, column: 1 - t) as? NSButtonCell)?.state = .on
        updateContestMacroButtons()
        contestManager?.contestSwitched(toCQ: contestModeIndex == Int32(kContestModeCQ))
    }

    //  overrides the captureCallsign in Modem.m
    @objc(captureCallsign:willChangeSelectionFromCharacterRange:toCharacterRange:)
    override func captureCallsign(_ textView: NSTextView!, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange, toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        var range = NSRange(location: 0, length: 0)

        contestBar?.cancel()

        (textView as? ExchangeView)?.setAppendLock(true)
        var locked = true

        let properClick = (textView as? ExchangeView)?.getAndClearMouseClick() ?? false
        let controlClick = (textView as? ExchangeView)?.getAndClearRightMouse() ?? false

        if !properClick || !controlClick || !inContestMode {
            range = super.captureCallsign(textView, willChangeSelectionFromCharacterRange: oldSelectedCharRange, toCharacterRange: newSelectedCharRange)
        } else {
            //  in contest mode, now check if callsign field or exchange field was selected
            switch selectedField {
            case Int32(kCallsignTextField):
                if controlKeyState && newSelectedCharRange.length > 0 {
                    range = oldSelectedCharRange
                } else {
                    range = getCallsignString(textView, from: newSelectedCharRange)
                    if range.length <= 0 {
                        (textView as? ExchangeView)?.setAppendLock(false)
                        locked = false
                        NotificationCenter.default.post(name: NSNotification.Name("ReselectField"), object: nil)
                        range = oldSelectedCharRange
                    } else {
                        if let storage = textView.textStorage {
                            let string = storage.attributedSubstring(from: range).string
                            if (string as NSString).length < 32 {
                                upperCase(string, into: captured)
                                (textView as? ExchangeView)?.setAppendLock(false)
                                locked = false
                                NotificationCenter.default.post(name: NSNotification.Name("CapturedContestCallsign"), object: self)
                                range.length = 0
                            }
                        }
                    }
                }
            case Int32(kExchangeTextField):
                if controlKeyState && newSelectedCharRange.length > 0 {
                    range = oldSelectedCharRange
                } else {
                    range = getExchangeString(textView, from: newSelectedCharRange)
                    if range.length <= 0 {
                        range = oldSelectedCharRange        //  0.45
                    } else {
                        if let storage = textView.textStorage {
                            let string = storage.attributedSubstring(from: range).string
                            if (string as NSString).length < 32 {
                                upperCase(string, into: captured)
                                (textView as? ExchangeView)?.setAppendLock(false)
                                locked = false
                                NotificationCenter.default.post(name: NSNotification.Name("CapturedContestExchange"), object: self)
                                range.length = 0
                            }
                        }
                    }
                }
            case Int32(kExtraTextField):
                if controlKeyState && newSelectedCharRange.length > 0 {
                    range = oldSelectedCharRange
                } else {
                    range = getExchangeString(textView, from: newSelectedCharRange)
                    if range.length <= 0 {
                        range = oldSelectedCharRange        //  0.45
                    } else {
                        if let storage = textView.textStorage {
                            let string = storage.attributedSubstring(from: range).string
                            if (string as NSString).length < 32 {
                                upperCase(string, into: captured)
                                (textView as? ExchangeView)?.setAppendLock(false)
                                locked = false
                                NotificationCenter.default.post(name: NSNotification.Name("CapturedSecondExchange"), object: self)
                                range.length = 0
                            }
                        }
                    }
                }
            default:
                //  should not get here
                selectedField = Int32(kCallsignTextField)
                range = newSelectedCharRange
            }
        }
        if locked { (textView as? ExchangeView)?.setAppendLock(false) }
        return range
    }

    @objc(delayedFinishClick:)
    func delayedFinishClick(_ timer: Timer!) {
        NotificationCenter.default.post(name: NSNotification.Name("FinishControlClick"), object: nil)
    }

    @objc(delayedSelectField:)
    func delayedSelectField(_ timer: Timer!) {
        NotificationCenter.default.post(name: NSNotification.Name("ReselectField"), object: nil)
    }

    @objc(callsignClickSuccessful:)
    func callsignClickSuccessful(_ success: Bool) {
        let selector: Selector = success ? #selector(delayedFinishClick(_:)) : #selector(delayedSelectField(_:))
        Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: selector, userInfo: self, repeats: false)
    }

    //  ----------- preferences -------------
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)
        if contestBar != nil { contestBar.setupDefaultPreferences(pref) }
    }

    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        var state = super.updateFromPlist(pref)
        if contestBar != nil { state = state && contestBar.updateFromPlist(pref) }
        return state
    }

    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        super.retrieveForPlist(pref)
        if contestBar != nil { contestBar.retrieveForPlist(pref) }
    }
}
