//
//  QSO.swift
//  cocoaModem
//
//  Created by Kok Chen on Thu Jul 08 2004.
//
//  Swift port of QSO.m.  QSO remains a subclass of the Objective-C class
//  StripPhi (StripPhi stays Objective-C; its header is in the bridging header).
//

import Cocoa

//  Informal access to -[Modem capturedString] (returns char*) without pulling
//  the heavy Modem.h into the bridging header.  Resolved dynamically through
//  AnyObject message dispatch.
@objc private protocol QSOCapturedStringSource {
    @objc func capturedString() -> UnsafeMutablePointer<CChar>?
}

@objc(QSO)
class QSO: StripPhi {

    //  outlets connected by QSO.nib -- names must match nib keys exactly
    @objc var view: NSView!
    @objc var callsignField: NSTextField!
    @objc var nameField: NSTextField!
    @objc var utcDateField: NSTextField!
    @objc var utcTimeField: NSTextField!

    @objc var callButton: NSButton!
    @objc var nameButton: NSButton!
    @objc var clearButton: NSButton!
    @objc var logButton: NSButton!

    private var controllingTabView: NSTabView!
    private var application: Application!

    private var day: Int32 = 0
    private var myExchange: String = ""
    private var dxExchange: String = ""
    private var qsoNumber: String = "001"
    private var previousNumber: String = "001"
    private var appleScript: NSAppleScript?

    private var gmt = tm()
    private var registeredTime = tm()
    private var previousTime = tm()

    //  called from Application (delegate of NSApplication)
    @objc(application:delegateHandlesKey:)
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        return true
    }

    /* local */
    private func convertToUpper(_ string: UnsafeMutablePointer<CChar>) {
        var p = string
        while p.pointee != 0 {
            var v = Int(UInt8(bitPattern: p.pointee))
            if v == 216 || v == 175 { /* slashed zero */ v = Int(UInt8(ascii: "0")) }
            if v >= Int(UInt8(ascii: "a")) && v <= Int(UInt8(ascii: "z")) {
                v += Int(UInt8(ascii: "A")) - Int(UInt8(ascii: "a"))
            }
            p.pointee = CChar(bitPattern: UInt8(truncatingIfNeeded: v))
            p = p.advanced(by: 1)
        }
    }

    @objc(newCallsign:)
    func newCallsign(_ notify: Notification) {
        guard let src = notify.object as AnyObject?,
              let cptr = src.capturedString?() else { return }
        let capturedString = asciiCString(cptr) as NSString
        var length = capturedString.length
        if length > 15 { length = 15 }
        let str = capturedString.substring(with: NSRange(location: 0, length: length))
        if callsignField != nil { callsignField.stringValue = str }
    }

    @objc(newName:)
    func newName(_ notify: Notification) {
        guard let src = notify.object as AnyObject?,
              let cptr = src.capturedString?() else { return }
        let capturedString = asciiCString(cptr) as NSString
        var length = capturedString.length
        if length > 20 { length = 20 }
        let str = capturedString.substring(with: NSRange(location: 0, length: length))
        if nameField != nil { nameField.stringValue = str }
    }

    private func setUTC() {
        var t = time(nil)
        gmt = gmtime(&t).pointee

        if day != gmt.tm_mday {
            day = gmt.tm_mday
            let str = String(format: "%02d/%02d/%02d", day, gmt.tm_mon + 1, (gmt.tm_year + 1900) % 100)
            utcDateField.stringValue = str
        }
        utcTimeField.stringValue = String(format: "%02d:%02d", gmt.tm_hour, gmt.tm_min)
    }

    @objc func callsign() -> String {
        guard let string = callsignField?.stringValue else { return "" }
        return asciiString(string)
    }

    @objc(setCallsign:)
    func setCallsign(_ str: String) {
        if callsignField != nil {
            callsignField.stringValue = str
        }
    }

    @objc func opName() -> String {
        guard let string = nameField?.stringValue else { return "" }
        return asciiString(string)
    }

    @objc(setOpName:)
    func setOpName(_ str: String) {
        if nameField != nil {
            nameField.stringValue = str
        }
    }

    @objc(setNumber:)
    func setNumber(_ str: String) {
        previousNumber = qsoNumber
        qsoNumber = str
    }

    //  this field is used by the contest manager and used by macro sheets
    @objc(setExchangeString:)
    func setExchangeString(_ str: String) {
        myExchange = str
    }

    //  this field is used by the contest manager and used by macro sheets
    @objc(setDXExchange:)
    func setDXExchange(_ str: String) {
        dxExchange = str
    }

    @objc(tick:)
    func tick(_ timer: Timer) {
        setUTC()
    }

    @objc(initIntoTabView:app:)
    init?(intoTabView tabview: NSTabView, app: Application) {
        super.init()

        application = app
        qsoNumber = "001"
        previousNumber = "001"
        day = -1
        myExchange = ""
        dxExchange = ""
        appleScript = nil

        if Bundle.main.loadNibNamed("QSO", owner: self, topLevelObjects: nil), view != nil {
            //  create a new TabViewItem for QSO
            let tabItem = NSTabViewItem()
            tabItem.label = NSLocalizedString("QSO", comment: "")
            tabItem.view = view
            //  and insert as tabView item
            controllingTabView = tabview
            controllingTabView.insertTabViewItem(tabItem, at: 0)
            //  disable log script button first
            logButton.isEnabled = false

            //  create notification client for ExchangeView
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(newCallsign(_:)), name: NSNotification.Name("CapturedCallsign"), object: nil)
            nc.addObserver(self, selector: #selector(newName(_:)), name: NSNotification.Name("CapturedName"), object: nil)
            nc.addObserver(self, selector: #selector(registerTime), name: NSNotification.Name("RegisterTime"), object: nil)
            nc.addObserver(self, selector: #selector(registerAndUpdateTime), name: NSNotification.Name("RegisterAndUpdateTime"), object: nil)
            setUTC()
            registerAndUpdateTime()
            Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(tick(_:)), userInfo: self, repeats: true)

            callButton.target = self
            callButton.action = #selector(transferCall)
            nameButton.target = self
            nameButton.action = #selector(transferName)
            clearButton.target = self
            clearButton.action = #selector(clearFields)
            logButton.target = self
            logButton.action = #selector(logQSO)

            return
        }
        return nil
    }

    @objc(showOnlyDateAndTime:)
    func showOnlyDateAndTime(_ state: DarwinBoolean) {
        let hidden = state.boolValue
        callsignField.isHidden = hidden
        callButton.isHidden = hidden
        nameField.isHidden = hidden
        nameButton.isHidden = hidden
        clearButton.isHidden = hidden
        logButton.isHidden = hidden
    }

    @objc func registerTime() {
        registeredTime = gmt
    }

    @objc func registerAndUpdateTime() {
        registerTime()
        previousTime = registeredTime
    }

    @objc func getRegisteredTime() -> String {
        return String(format: "%02d%02d", registeredTime.tm_hour, registeredTime.tm_min)
    }

    private func cutFor(_ original: String) -> String {
        var chars = Array(original)
        for i in 0..<min(5, chars.count) {
            switch chars[i] {
            case "1": chars[i] = "A"
            case "9": chars[i] = "N"
            case "0": chars[i] = "T"
            default: break
            }
        }
        return String(chars)
    }

    private func zeroCutFor(_ original: String) -> String {
        var chars = Array(original)
        for i in 0..<min(5, chars.count) {
            if chars[i] == "0" { chars[i] = "T" }
        }
        return String(chars)
    }

    //  scan a leading signed integer, matching sscanf( ..., "%d", ... )
    private func leadingInt(_ s: String) -> Int32 {
        let scanner = Scanner(string: s)
        var value = 0
        _ = scanner.scanInt(&value)
        return Int32(truncatingIfNeeded: value)
    }

    private func numberFormat(_ n: Int32, _ p: Int32) -> String {
        switch n {
        case 0:
            return "%d"
        case 3:
            return (p < 1000) ? "%03d" : "%d"
        case 4:
            return (p < 1000) ? "%04d" : "%d"
        default:
            return "%d"
        }
    }

    //  fetch macro
    @objc(macroFor:)
    func macroFor(_ c: Int32) -> String {
        let str: String

        switch UnicodeScalar(UInt8(truncatingIfNeeded: c)) {
        case "C":
            str = callsignField.stringValue
        case "H":
            //  name
            str = nameField.stringValue
        case "n", "N", "o":
            //  n: number, N: cut (A=1,N=9,T=0) number, o: zero cut (T=0) number
            str = macroFor(c, count: 0)
        case "p":
            //  previous number
            str = (!callsignField.stringValue.isEmpty) ? qsoNumber : previousNumber
        case "t":
            str = String(format: "%02d%02d", gmt.tm_hour, gmt.tm_min)
        case "T":
            str = String(format: "%02d%02d", registeredTime.tm_hour, registeredTime.tm_min)
        case "P":
            str = String(format: "%02d%02d", previousTime.tm_hour, previousTime.tm_min)
        case "x":
            //  contest exchange
            str = myExchange
        case "X":
            //  dx exchange
            str = dxExchange
        default:
            str = "----"
        }
        return str
    }

    @objc(macroFor:count:)
    func macroFor(_ c: Int32, count n: Int32) -> String {
        let str: String

        switch UnicodeScalar(UInt8(truncatingIfNeeded: c)) {
        case "n":
            //  number
            let p = leadingInt(qsoNumber)
            str = String(format: numberFormat(n, p), p)
        case "N":
            //  cut number
            let p = leadingInt(qsoNumber)
            str = cutFor(String(format: numberFormat(n, p), p))
        case "o":
            //  zero cut number
            let p = leadingInt(qsoNumber)
            str = zeroCutFor(String(format: numberFormat(n, p), p))
        case "p":
            //  previous number
            let p = leadingInt(previousNumber)
            var nn = n
            if nn > 1 && !callsignField.stringValue.isEmpty { nn -= 1 }
            str = String(format: numberFormat(nn, p), p)
        default:
            str = "----"
        }
        return str
    }

    //  copy string into text field
    @objc(copyString:into:)
    func copyString(_ selectedString: UnsafeMutablePointer<CChar>!, into field: Int32) {
        var f: NSTextField? = nil
        switch UnicodeScalar(UInt8(truncatingIfNeeded: field)) {
        case "C":
            f = callsignField
            convertToUpper(selectedString)
        case "N":
            f = nameField
        default:
            break
        }
        if let f = f {
            f.stringValue = NSString(cString: selectedString, encoding: String.Encoding.isoLatin1.rawValue) as String? ?? ""
        }
    }

    @objc(logScriptChanged:)
    func logScriptChanged(_ fileName: String) {
        var errorDict: NSDictionary?
        appleScript = nil
        logButton?.isEnabled = false
        if !fileName.isEmpty {
            let url = URL(fileURLWithPath: (fileName as NSString).expandingTildeInPath)
            appleScript = NSAppleScript(contentsOf: url, error: &errorDict)
            if let script = appleScript {
                if script.compileAndReturnError(&errorDict) {
                    logButton?.isEnabled = true
                    return
                }
            }
            Messages.appleScriptError(errorDict as? [AnyHashable: Any], script: "Log button")
        }
    }

    @objc func logQSO() {
        if let script = appleScript {
            var errorDict: NSDictionary? = NSDictionary()
            if script.executeAndReturnError(&errorDict) == nil {
                Messages.appleScriptError(errorDict as? [AnyHashable: Any], script: "Log")
                logButton?.isEnabled = false
                appleScript = nil
            }
        }
    }

    @objc func transferCall() {
        application.transfer(toQSOField: Int32(UInt8(ascii: "C")))
    }

    @objc func transferName() {
        application.transfer(toQSOField: Int32(UInt8(ascii: "N")))
    }

    @objc func clearFields() {
        callsignField.stringValue = ""
        nameField.stringValue = ""
    }

    //  v1.01a
    @objc func selectCall() {
        callsignField.becomeFirstResponder()
        callsignField.stringValue = ""
    }

    //  v1.01a
    @objc func selectName() {
        nameField.becomeFirstResponder()
        nameField.stringValue = ""
    }
}
