//
//  ContestBar.swift
//  cocoaModem
//
//  Created by Kok Chen on 12/4/04.
//
//  Swift port of ContestBar.m.  The "Contest" tab that drives repeating
//  macros.  Subclass of StripPhi (now Swift).
//

import Cocoa

@objc(ContestBar)
class ContestBar: StripPhi {

    //  outlets connected by ContestBar.nib -- names must match nib keys exactly
    @objc var view: NSView!
    @objc var pauseTime: NSTextField!
    @objc var repeatingIndicator: NSTextField!
    @objc var macroMenu: NSPopUpButton!

    private var controllingTabView: NSTabView!
    private var application: Application!

    //  repeating macros
    private var manager: ContestManagerRef?
    private var modem: ContestInterface?
    private var index: Int32 = -1
    private var sheet: Int32 = -1
    private var delayTimer: Timer?
    private var offColor: NSColor = .black
    private var onColor: NSColor = .black
    private var waitColor: NSColor = .black
    private var repeatActive: Bool = false

    @objc(initIntoTabView:app:)
    init?(intoTabView tabview: NSTabView, app: Application) {
        super.init()

        application = app
        manager = nil
        modem = nil
        index = -1
        sheet = -1
        repeatActive = false
        delayTimer = nil
        offColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
        waitColor = .orange
        onColor = waitColor

        if Bundle.main.loadNibNamed("ContestBar", owner: self, topLevelObjects: nil), view != nil {
            //  create a new TabViewItem for the Contest bar
            let tabItem = NSTabViewItem()
            tabItem.label = "Contest"
            tabItem.view = view
            //  and insert as tabView item
            controllingTabView = tabview
            controllingTabView.insertTabViewItem(tabItem, at: 2)
            return
        }
        return nil
    }

    @objc func cancel() {
        if repeatActive, let modem = modem, modem.currentTransmitState() {
            //  is transmitting
            modem.flushAndLeaveTransmit()
        }
        if let timer = delayTimer {
            //  cancel any pending pause
            timer.invalidate()
            delayTimer = nil
        }
        //  cancel future requests for repeating macros from the ContestInterface (see nextMacro: below)
        repeatingIndicator?.backgroundColor = offColor
        repeatActive = false
    }

    @objc func cancelIfRepeatingIsActive() {
        if delayTimer != nil || repeatActive { cancel() }
    }

    //  this is where the delay timer fires (see nextMacro: below)
    @objc(repeating:)
    func repeating(_ timer: Timer) {
        delayTimer = nil
        repeatingIndicator?.backgroundColor = onColor
        _ = manager?.executeContestMacro(index, sheet: sheet, modem: modem)
    }

    //  called from ContestInterface:transmissionEnded to fire the timer for the
    //  next repeating macro.  It is the pause between macros that matters.
    @objc(nextMacro:)
    func nextMacro(_ arg: Any?) {
        if repeatActive && delayTimer == nil {
            var pause = pauseTime?.floatValue ?? 0
            //  pause limits of 0.5 min to 10 seconds max
            if pause < 0.5 { pause = 0.5 } else if pause > 10.0 { pause = 10.0 }
            repeatingIndicator?.backgroundColor = waitColor
            delayTimer = Timer.scheduledTimer(timeInterval: TimeInterval(pause), target: self, selector: #selector(repeating(_:)), userInfo: nil, repeats: false)
        } else {
            delayTimer?.invalidate()        // v0.33
        }
    }

    @objc(setManager:)
    func setManager(_ inManager: Any?) {
        manager = inManager as? ContestManagerRef
        repeatActive = false
    }

    @objc(setModem:)
    func setModem(_ inModem: ContestInterface?) {
        modem = inModem
        repeatActive = false
    }

    @objc(newMacroCalled:sheet:manager:modem:)
    func newMacroCalled(_ inIndex: Int32, sheet inSheet: Int32, manager inManager: Any?, modem inModem: ContestInterface?) {
        if delayTimer != nil { cancel() }

        index = inIndex
        sheet = inSheet
        manager = inManager as? ContestManagerRef
        modem = inModem
        repeatActive = false
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setFloat(2.7, forKey: kContestRepeat)
        pref.setInt(0, forKey: kContestRepeatMenu)
    }

    @objc(updateFromPlist:)
    @discardableResult
    func updateFromPlist(_ pref: Preferences) -> Bool {
        let pause = pref.floatValue(forKey: kContestRepeat)
        pauseTime?.stringValue = String(format: "%.1f", pause)
        let n = pref.intValue(forKey: kContestRepeatMenu)
        macroMenu?.selectItem(at: Int(n))
        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        let pause = pauseTime?.floatValue ?? 0
        pref.setFloat(pause, forKey: kContestRepeat)
        pref.setInt(Int32(macroMenu?.indexOfSelectedItem ?? 0), forKey: kContestRepeatMenu)
    }

    @objc func textInsertedFromRepeat() -> Bool {
        return repeatActive
    }

    @objc(repeatMacro:)
    func repeatMacro(_ sender: Any?) {
        guard repeatActive == false, let manager = manager, let modem = modem else { return }

        if !modem.checkIfCanTransmit() { return }

        //  find which macro to send
        var tag = Int32(macroMenu?.selectedItem?.tag ?? 0)
        if tag == 1111 {
            //  "last macro"
            if index < 0 || sheet < 0 {
                Messages.alert(withMessageText: NSLocalizedString("No prior macro sent", comment: ""), informativeText: NSLocalizedString("Select a macro", comment: ""))
                return
            }
        } else {
            let sh = tag / 100
            tag = tag % 100
            if sh < 0 || sh > 2 || tag < 0 || tag > 7 { /* internal error */ return }
            sheet = sh + kContestModeCQ
            index = tag
        }
        //  This switches on the macro repeats.  We call the ContestManager to
        //  execute the macro the first time here; afterward the ContestManager
        //  calls nextMacro: which re-fires as long as repeatActive is set.

        repeatActive = true
        repeatingIndicator?.backgroundColor = onColor

        if modem.currentTransmitState() { /* already transmitting */ return }
        // start a macro otherwise
        if !manager.executeContestMacro(index, sheet: sheet, modem: modem) {
            cancel()
            Messages.alert(withMessageText: NSLocalizedString("Macro is empty", comment: ""), informativeText: NSLocalizedString("selected macro is empty", comment: ""))
        }
    }

    @objc(stopRepeat:)
    func stopRepeat(_ sender: Any?) {
        cancel()
    }
}
