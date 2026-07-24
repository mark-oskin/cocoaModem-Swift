//
//  Generic.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon Oct 11 2004.
//
//  Swift port of Generic.m.  A generic contest interface with just a callsign
//  and a free-form exchange field.  Subclass of Contest.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

private let kCallNotify = "SelectCallField"
private let kExchangeNotify = "SelectExchField"

//  XML QSO phases (from Generic.h)
private let kQSOCall: Int32 = 1
private let kQSODate: Int32 = 2
private let kQSOTime: Int32 = 3
private let kQSOExch: Int32 = 4
private let kQSOFreq: Int32 = 5
private let kQSOMode: Int32 = 6
private let kQSONumber: Int32 = 7

private func leadingInt(_ s: String?) -> Int32 {
    guard let s = s else { return 0 }
    let sc = Scanner(string: s)
    var v = 0
    return sc.scanInt(&v) ? Int32(truncatingIfNeeded: v) : 0
}

private func leadingFloat(_ s: String?) -> Float {
    guard let s = s else { return 0 }
    let sc = Scanner(string: s)
    var v = 0.0
    return sc.scanDouble(&v) ? Float(v) : 0
}

@objc(Generic)
class Generic: Contest, NSTextFieldDelegate {

    //  outlets connected by Generic.nib -- names must match nib keys exactly
    @objc var dxCall: TransparentTextField!
    @objc var dxExchange: TransparentTextField!

    var upperFormatter: UpperFormatter!
    var qsoStrings = [String?](repeating: nil, count: 8)
    private var parseQSOPhase: Int32 = 0

    override func awakeFromNib() {
        initializeActions()
        setInterface(dxCall, to: #selector(callFieldChanged))
        setInterface(dxExchange, to: #selector(exchangeFieldChanged))
    }

    func selectCallsignField() {
        NotificationCenter.default.post(name: NSNotification.Name(kCallNotify), object: dxCall)
        selectField(dxCall)
        dxCall.markAsSelected(true)
        dxExchange.markAsSelected(false)
    }

    func selectExchangeField() {
        NotificationCenter.default.post(name: NSNotification.Name(kExchangeNotify), object: dxExchange)
        selectField(dxExchange)
        dxCall.markAsSelected(false)
        dxExchange.markAsSelected(true)
    }

    @objc func newCallsign(_ notify: Notification) {
        //  check if we are the active interface
        if client !== manager?.selectedContestInterface() { return }

        let src = notify.object as? Modem
        let capturedString = asciiCString(src?.capturedString()) as NSString
        var length = capturedString.length
        if length > 15 { length = 15 }
        let str = capturedString.substring(with: NSRange(location: 0, length: length))

        if master != nil {
            let inBand = selectedBand()
            var duped = false
            activeCall = master!.receivedCallsign(str, band: inBand, isDupe: &duped)
            if activeCall != nil {
                selectExchangeField()
                dxCall.window?.selectKeyView(following: dxCall)
                dxCall.stringValue = str
                dxCall.display()
                dxExchange.selectText(self)
            } else {
                selectCallsignField()
            }
        }
    }

    //  called from a TransparentTextField notification
    @objc func newFieldSelected(_ notify: Notification) {
        if client !== manager?.selectedContestInterface() { return }

        guard let field = notify.object as? TransparentTextField else { return }
        switch field.fieldType {
        case kCallsignTextField:
            NotificationCenter.default.post(name: NSNotification.Name(kCallNotify), object: dxCall)
            dxCall.markAsSelected(true)
            dxExchange.markAsSelected(false)
        case kExchangeTextField:
            NotificationCenter.default.post(name: NSNotification.Name(kExchangeNotify), object: dxExchange)
            dxCall.markAsSelected(false)
            dxExchange.markAsSelected(true)
        default:
            break
        }
    }

    func validateExchange(_ exchange: String) -> Bool {
        return true
    }

    //  check state/number here
    @objc func newExchange(_ notify: Notification) {
        if client !== manager?.selectedContestInterface() { return }

        let src = notify.object as? Modem
        let capturedString = asciiCString(src?.capturedString()) as NSString
        var length = capturedString.length
        if length > 10 { length = 10 }
        let str = capturedString.substring(with: NSRange(location: 0, length: length))
        if dxExchange != nil {
            dxExchange.stringValue = str
            if !validateExchange(str) {
                dxExchange.window?.makeKeyAndOrderFront(self)
                dxExchange.stringValue = ""
                dxExchange.selectText(self)
            }
        }
    }

    //  initialize this contest here
    override func setupFields() {
        guard master != nil else { return }

        super.setupFields()

        contestName = "Generic"

        upperFormatter = UpperFormatter()
        dxCall.formatter = upperFormatter
        dxExchange.formatter = upperFormatter

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(newCallsign(_:)), name: NSNotification.Name("CapturedContestCallsign"), object: nil)
        nc.addObserver(self, selector: #selector(newExchange(_:)), name: NSNotification.Name("CapturedContestExchange"), object: nil)
        nc.addObserver(self, selector: #selector(newFieldSelected(_:)), name: NSNotification.Name("SelectNewField"), object: nil)

        dxCall.moveAbove()
        dxCall.fieldType = kCallsignTextField
        dxExchange.moveAbove()
        dxExchange.fieldType = kExchangeTextField
        qsoNumberField.moveAbove()

        dxCall.delegate = self
        dxCall.nextKeyView = dxExchange

        setWatermarkState(false)
    }

    override func fetchCallString() -> String {
        return dxCall.stringValue
    }

    //  band switched, check call (dupe) again
    override func bandSwitched(_ band: Int32) {
        activeBand = band
        let call = dxCall?.stringValue ?? ""
        if !call.isEmpty {
            var duped = false
            activeCall = (master != nil) ? master!.receivedCallsign(call, band: band, isDupe: &duped)
                                         : receivedCallsign(call, band: band, isDupe: &duped)
        }
    }

    @objc override func newQSO(_ n: Int32) {
        if master != nil {
            //  only with the active contest interface
            if client !== manager?.selectedContestInterface() { return }
            //  subordinate
            dxCall.stringValue = ""
            dxExchange.stringValue = ""
            activeQSONumber = n
            qsoNumberField.intValue = n
            selectCallsignField()
        } else {
            //  master
            for i in 0..<Int(subordinates) { subordinate[i]?.newQSO(activeQSONumber) }
        }
    }

    //  create a log entry from an XML QSO element
    func enterQSOFromXML() {
        if master != nil { return }

        var t = DateTime()
        let timeParts = (qsoStrings[Int(kQSOTime)] ?? "").split(separator: ":", omittingEmptySubsequences: false)
        t.hour = UInt8(truncatingIfNeeded: timeParts.count > 0 ? leadingInt(String(timeParts[0])) : 0)
        t.minute = UInt8(truncatingIfNeeded: timeParts.count > 1 ? leadingInt(String(timeParts[1])) : 0)
        t.second = UInt8(truncatingIfNeeded: timeParts.count > 2 ? leadingInt(String(timeParts[2])) : 0)

        let dateParts = (qsoStrings[Int(kQSODate)] ?? "").split(separator: "/", omittingEmptySubsequences: false)
        t.day = UInt8(truncatingIfNeeded: dateParts.count > 0 ? leadingInt(String(dateParts[0])) : 0)
        t.month = UInt8(truncatingIfNeeded: dateParts.count > 1 ? leadingInt(String(dateParts[1])) : 0)
        t.year = UInt8(truncatingIfNeeded: dateParts.count > 2 ? leadingInt(String(dateParts[2])) : 0)

        if let c = ((qsoStrings[Int(kQSOCall)] ?? "") as NSString).cString(using: kLatin1) {
            activeCall = hashCallsign(c)
        }
        let p = UnsafeMutablePointer<ContestQSO>.allocate(capacity: 1)
        p.pointee.frequency = leadingFloat(qsoStrings[Int(kQSOFreq)])
        p.pointee.qsoNumber = UInt16(truncatingIfNeeded: leadingInt(qsoStrings[Int(kQSONumber)]))
        if Int32(p.pointee.qsoNumber) >= activeQSONumber { activeQSONumber = Int32(p.pointee.qsoNumber) }
        p.pointee.time = t
        p.pointee.mode = Int16(truncatingIfNeeded: modeForString(qsoStrings[Int(kQSOMode)] ?? ""))

        if let str = qsoStrings[Int(kQSOExch)] {
            let ns = str as NSString
            let buf = malloc(ns.length + 1)!.assumingMemoryBound(to: CChar.self)
            if let c = ns.cString(using: kLatin1) { strcpy(buf, c) } else { buf[0] = 0 }
            p.pointee.exchange = buf
        } else {
            p.pointee.exchange = nil
        }

        createQSO(p, callsign: activeCall, mode: activeMode)

        for i in 1..<7 { qsoStrings[i] = nil }
    }

    /* local -- set master entry from dxCallSet.  true if successful, false if duped */
    func setDXCall(_ str: String, panel: Contest) -> Bool {
        if master != nil { return false }
        var duped = false
        activeBand = panel.selectedBand()
        activeCall = receivedCallsign(str, band: activeBand, isDupe: &duped)
        return activeCall != nil
    }

    @objc func callFieldChanged() {
        if (dxCall.clickedString() as NSString).length > 0 { return }
        let string = dxCall.stringValue

        if !string.isEmpty {
            let state = (master as? Generic)?.setDXCall(string, panel: self) ?? false
            if state { selectExchangeField() } else { setWatermarkState(true) }
        } else {
            if master?.isDuped() ?? false { setWatermarkState(false) }
        }
    }

    @objc func exchangeFieldChanged() {
        if master != nil {
            let str = dxExchange.stringValue
            if !str.isEmpty {
                if !validateExchange(str) {
                    dxExchange.stringValue = ""
                    dxExchange.selectText(self)
                }
            }
        }
    }

    //  local version of createQSOFromCurrentData
    override func createQSOFromCurrentData() -> UnsafeMutablePointer<ContestQSO> {
        let p = super.createQSOFromCurrentData()
        p.pointee.callsign = currentCallsign()
        let ns = dxExchange.stringValue as NSString
        let buf = malloc(ns.length + 1)!.assumingMemoryBound(to: CChar.self)
        if let c = ns.cString(using: kLatin1) { strcpy(buf, c) } else { buf[0] = 0 }
        p.pointee.exchange = buf
        return p
    }

    override func writeCabrilloQSOs() {
        var myCall = ""
        if let used = usedCallString { myCall = cTrunc(used, 13) }

        let expanded = manager?.expandMacroInUserAndQSOInfo(cabrillo.exchangeString()) ?? ""
        let exchSent = String(expanded.prefix(16))

        var count: Int32 = 0
        for i in 0..<Int(MAXQ) {
            //  QSO: 21080 RY 2004-01-03 1800 W7AY         599     OR AK0A         599     KS
            guard let q = sortedQSOList[i] else { continue }

            let frequency = Int(q.pointee.frequency * 1000.0 + 0.1)
            var mode = stringForMode(Int32(q.pointee.mode))
            if mode == "PK" { mode = "RY" }        //  report PSK as RY to Cabrillo
            let time = q.pointee.time
            var year = Int(time.year); if year < 2000 { year += 2000 }
            let month = Int(time.month)
            let day = Int(time.day)
            let utc = Int(time.hour) * 100 + Int(time.minute)

            var callsign = ""
            if let c = q.pointee.callsign { callsign = cTrunc(latin1String(callsignCName(c)), 13) }

            var line = "QSO: " + String(format: "%5d", frequency % 100000) + " " + rjust(mode, 2) + " "
            line += String(format: "%4d-%02d-%02d %04d ", year, month, day, utc)
            line += ljust(myCall, 13)
            line += rjust(exchSent, 10) + " "
            line += ljust(callsign, 13)

            let exchange = q.pointee.exchange != nil ? cTrunc(latin1String(q.pointee.exchange), 10) : ""
            line += rjust(exchange, 10)
            line += "\n"
            cmFPuts(line, cabrilloFile)

            count += 1
            if count >= numberOfQSO { break }
        }
    }

    @objc override func logButtonPushed() {
        if isEmpty(dxCall) || isEmpty(dxExchange) {
            Messages.alert(withMessageText: "Not all field are filled.", informativeText: "Call sign and exchange fields need to be non-empty.  Please fill them and click on Log again.")
            return
        }
        if master != nil {
            if (master as? Generic)?.validateExchange(dxExchange.stringValue) ?? false {
                let p = createQSOFromCurrentData()
                master!.createQSO(p, callsign: activeCall, mode: activeMode)
                master!.journalQSO(p)
                master!.newQSO(0)
                if master!.setDupeState(false) { setWatermarkState(false) }
                selectCallsignField()
            } else {
                dxExchange.stringValue = ""
                dxExchange.selectText(self)
            }
        }
    }

    // ------------------- XML parser (NSXMLParserDelegate) -------------------

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String]) {
        if parseContest {
            if parseContestLog {
                if parseQSO {
                    if elementName == "call" { parseQSOPhase = kQSOCall }
                    else if elementName == "date" { parseQSOPhase = kQSODate }
                    else if elementName == "time" { parseQSOPhase = kQSOTime }
                    else if elementName == "exch" { parseQSOPhase = kQSOExch }
                    else if elementName == "freq" { parseQSOPhase = kQSOFreq }
                    else if elementName == "mode" { parseQSOPhase = kQSOMode }
                    else if elementName == "qnum" { parseQSOPhase = kQSONumber }
                    return
                }
                if elementName == "QSO" {
                    parseQSO = true
                    parseQSOPhase = 0
                    return
                }
            } else if elementName == "contestLog" { parseContestLog = true }
            else if elementName == "contestName" { parseContestName = true }
            return
        }
        if elementName == "Contest" {
            parseContest = true
            parseQSOPhase = 0
            return
        }
        print("cocoaModem read xml discarding element name \(elementName)")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if parseContest {
            if parseContestLog {
                if parseQSO {
                    if parseQSOPhase != 0 {
                        qsoStrings[Int(parseQSOPhase)] = string
                    }
                }
            }
            if parseContestName {
                contestName = string
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "QSO" {
            parseQSO = false
            enterQSOFromXML()
            parseQSOPhase = 0
        } else if elementName == "call" { parseQSOPhase = 0 }
        else if elementName == "date" { parseQSOPhase = 0 }
        else if elementName == "time" { parseQSOPhase = 0 }
        else if elementName == "exch" { parseQSOPhase = 0 }
        else if elementName == "freq" { parseQSOPhase = 0 }
        else if elementName == "mode" { parseQSOPhase = 0 }
        else if elementName == "qnum" { parseQSOPhase = 0 }
        else if elementName == "contestName" { parseContestName = false }
        else if elementName == "contestLog" { parseContestLog = false }
        else if elementName == "Contest" { parseContest = false }
    }

    //  delegate for callsign text field
    func controlTextDidChange(_ obj: Notification) {
        master?.setDupeState(false)
        setWatermarkState(false)
    }
}
