//
//  MacroInterface.swift
//  cocoaModem
//
//  Created by Kok Chen on 11/20/04.
//  Swift port of MacroInterface.m / MacroInterface.h.
//
//  MacroInterface : Modem.  Shared base of every keyboard/macro-driven mode tab
//  (ContestInterface, and through it RTTYInterface, PSK, MFSK, Hellschreiber ...).
//  It owns the three RTTY macro sheets (normal / option / shift-option) and drives
//  the on-screen macro buttons.
//
//  Port notes:
//   * Every original ivar is an `internal` stored property with its EXACT original
//     name so the 14+ descendants resolve them across the module.  Most are @objc
//     for KVC / nib wiring.
//   * `macroSheet[3]` (a C array) becomes `[MacroSheet?]` of count 3; it coexists
//     with the same-named `macroSheet(_:)` accessor (property vs method).
//   * The copyright `validate:` filter and the CC/DC macros are replicated with
//     masked Int math.  (The #ifndef VALIDATE branch that calls -validate: is dead
//     code in the shipping build because VALIDATE is #defined, so -validate: is
//     ported for completeness but is never invoked, matching the original.)
//

import Cocoa

@objc(MacroInterface)
class MacroInterface: Modem {

    //  --- IBOutlet (id) ---
    @objc var messageMatrix: AnyObject!

    //  Macro sheets (normal, option and shift-option RTTY macros) -- was MacroSheet*[3]
    var macroSheet = [MacroSheet?](repeating: nil, count: 3)
    @objc var currentSheet: Int32 = 0
    @objc var check: Int32 = 0
    @objc var exclusionLicense: Bool = false
    @objc var exclusionCount: Int32 = 0

    //  =======================================================================

    @objc func initMacros() {
        check = 0
        exclusionLicense = false
        exclusionCount = 0
    }

    @objc(keyModifierChanged:)
    override func keyModifierChanged(_ notify: Notification!) {
        super.keyModifierChanged(notify)
        //  option flag
        //    0 - no option
        //    1 - option
        //    2 - option shift
        //  update macro button captions
        var optionFlag: Int32 = 0
        if optionKeyState {
            optionFlag = shiftKeyState ? 2 : 1
        }
        currentSheet = optionFlag
        updateMacroButtons()
    }

    //  CC( c ) = ( ( s[c] & 0x5f ) - 1 ) ; DC( c ) = ( ( s[c] & 0x7f ) - 2 )
    @objc(validate:)
    func validate(_ string: String!) -> Bool {
        let ns = (string ?? "") as NSString
        let length = ns.length
        guard let s = ns.cString(using: String.Encoding.isoLatin1.rawValue) else { return true }
        //  s in the original points at the C string + 1
        func byte(_ idx: Int) -> Int { return Int(s[idx]) & 0xff }
        var base = 1
        var i = 0
        while i < length - 4 {
            let cc0 = (byte(base + 0) & 0x5f) - 1
            let cc1 = (byte(base + 1) & 0x5f) - 1
            let dc2 = (byte(base + 2) & 0x7f) - 2
            let cc3 = (byte(base + 3) & 0x5f) - 1
            let cc4 = (byte(base + 4) & 0x5f) - 1
            if cc0 == 64 && dc2 == 51 && cc3 == 85 && cc4 == 84 && cc1 == 64 {
                check += 1
                if check > 20 { return false }
            }
            i += 1
            base += 1
        }
        return true
    }

    //  override this if needed
    @objc func updateMacroButtons() {
        updateModeMacroButtons()
    }

    @objc func updateModeMacroButtons() {
        //  fetch matrix of current sheet's title
        let matrix = macroSheet[Int(currentSheet)]?.titles()
        for i in 0..<12 {
            let field = matrix?.cell(atRow: i, column: 0)
            let string = field?.stringValue
            if messageMatrix != nil {
                if let button = (messageMatrix as? NSMatrix)?.cell(atRow: 0, column: i) as? NSButtonCell {
                    if let s = string, !s.isEmpty {
                        button.title = s
                    } else {
                        button.title = "Mcr \(i + 1)"
                    }
                }
            }
        }
    }

    //  execute string
    @objc(executeMacroString:)
    func executeMacroString(_ macro: String!) {
        if let macro = macro { transmitView?.insertAtEnd(macro) }

        if transmitCount > 0 {
            //  keep transmit on if needed
            if transmitState == false { changeTransmitStateTo(true) }
        }
    }

    //  execute a macro in a macroSheet
    @objc(executeMacro:macroSheet:fromContest:)
    func executeMacro(_ index: Int32, macroSheet sheet: MacroSheet!, fromContest: Bool) {
        let macro = sheet?.expandMacro(index, modem: self)

        //  (The #ifndef VALIDATE branch of the original is compiled out because
        //   VALIDATE is #defined; only the copyright filter below remains.)

        //  COPYRIGHT NOTICE:
        //  Do not change or remove the following filter from any cocoaModem build.
        if fromContest {
            let range = ((macro ?? "").uppercased() as NSString).range(of: "AA5VU")
            if exclusionLicense || range.location != NSNotFound {
                exclusionCount += 1
                if exclusionCount > 16 {
                    Messages.alert(withMessageText: "Contest macros disabled.", informativeText: "You are not licensed to use the contest interface in cocoaModem.")
                    exclusionLicense = true
                    return
                }
            }
        }
        //  end of copyright notice.

        executeMacroString(macro)
    }

    //  execute a macro in a (non-contest) macroSheet
    @objc(executeMacro:sheetNumber:)
    func executeMacro(_ index: Int32, sheetNumber n: Int32) {
        executeMacro(index, macroSheet: macroSheet[Int(n)], fromContest: false)
    }

    //  execute a macro in the current (non-contest) macroSheet
    @objc(executeMacroInSelectedSheet:)
    func executeMacroInSelectedSheet(_ index: Int32) {
        executeMacro(index, macroSheet: macroSheet[Int(currentSheet)], fromContest: false)
    }

    @objc(macroSheet:)
    func macroSheet(_ index: Int32) -> MacroSheet! {
        var index = index
        if index < 0 || index > 2 { index = 0 }
        return macroSheet[Int(index)]
    }

    @objc(setMacroSheet:index:)
    func setMacroSheet(_ sheet: MacroSheet!, index i: Int32) {
        macroSheet[Int(i)] = sheet
    }

    @objc(showMacroSheet:)
    func showMacroSheet(_ sender: Any!) {
        let sheet = currentSheet
        currentSheet = 0
        if let window = controllingTabView?.window {
            macroSheet[Int(sheet)]?.showMacroSheet(window, modem: self)
        }
    }

    @objc(transmitMessage:)
    func transmitMessage(_ sender: Any!) {
        let index = Int32((sender as? NSMatrix)?.selectedColumn ?? 0)
        let title = macroSheet[Int(currentSheet)]?.title(index)
        if title == nil || title!.isEmpty {
            NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
            return
        }
        executeMacroInSelectedSheet(index)
    }
}
