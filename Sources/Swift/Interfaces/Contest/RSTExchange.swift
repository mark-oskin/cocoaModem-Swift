//
//  RSTExchange.swift
//  cocoaModem
//
//  Created by Kok Chen on Sat Nov 27 2004.
//
//  Swift port of RSTExchange.m.  Contest interface with a callsign, RST and
//  exchange field.  Base for most RTTY contests.  Subclass of Contest.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

//  notification names (formerly the CallNotify / ExchangeNotify / ExtraFieldNotify macros)
private let kCallNotify = "SelectCallField"
private let kExchangeNotify = "SelectExchField"
private let kExtraFieldNotify = "SelectExtraField"

//  XML QSO phases (from RSTExchange.h)
private let kQSOCall: Int32 = 1
private let kQSODate: Int32 = 2
private let kQSOTime: Int32 = 3
private let kQSOExch: Int32 = 4
private let kQSOFreq: Int32 = 5
private let kQSOMode: Int32 = 6
private let kQSONumber: Int32 = 7
private let kQSORST: Int32 = 8

//  scan a leading signed integer, matching sscanf( ..., "%d", ... )
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

//  RST written into the internal XML (clamped 100...599)
func saveRSTToXML(_ file: UnsafeMutablePointer<FILE>?, _ q: UnsafeMutablePointer<ContestQSO>) {
    var rst = Int(q.pointee.rst)
    if rst > 599 { rst = 599 } else if rst < 100 { rst = 100 }
    cmFPuts(String(format: "\t\t\t<rst>%d</rst>\n", rst), file)
}

@objc(RSTExchange)
class RSTExchange: Contest, NSTextFieldDelegate {

    //  outlets connected by the prototype nib -- names must match nib keys exactly
    @objc var dxCall: TransparentTextField!
    @objc var dxExchange: TransparentTextField!
    @objc var dxRST: TransparentTextField!
    @objc var dxExtra: TransparentTextField!

    var upperFormatter: UpperFormatter!
    var qsoStrings = [String?](repeating: nil, count: 9)
    //  xml parser
    private var parseQSOPhase: Int32 = 0
    //  for checking if field already cleared
    private var callFieldEmpty = false
    //  deferred field selection
    var selectedFieldType: Int32 = 0

    override func awakeFromNib() {
        initializeActions()
        setInterface(dxCall, to: #selector(callFieldChanged))
        if dxExchange != nil { setInterface(dxExchange, to: #selector(exchangeFieldChanged)) }
        if dxRST != nil { setInterface(dxRST, to: #selector(rstFieldChanged)) }
        if dxExtra != nil { setInterface(dxExtra, to: #selector(extraFieldChanged)) }
    }

    func selectCallsignField() {
        selectedFieldType = kCallsignTextField
        NotificationCenter.default.post(name: NSNotification.Name(kCallNotify), object: dxCall)
        selectField(dxCall)
        dxCall.markAsSelected(true)
        dxExchange.markAsSelected(false)
        dxExtra?.markAsSelected(false)
    }

    func selectExchangeField() {
        selectedFieldType = kExchangeTextField
        NotificationCenter.default.post(name: NSNotification.Name(kExchangeNotify), object: dxExchange)
        selectField(dxExchange)
        dxCall.markAsSelected(false)
        dxExchange.markAsSelected(true)
        dxExtra?.markAsSelected(false)
    }

    func selectExtraField() {
        if let dxExtra = dxExtra {
            selectedFieldType = kExtraTextField
            NotificationCenter.default.post(name: NSNotification.Name(kExtraFieldNotify), object: dxExtra)
            selectField(dxExtra)
            dxCall.markAsSelected(false)
            dxExchange.markAsSelected(false)
            dxExtra.markAsSelected(true)
        }
    }

    override func selectFirstResponderInActivePanel() {
        selectCallsignField()
    }

    @objc func timedMakeFieldFirstResponder() {
        if master == nil {
            activeSubordinate?.selectActiveField()
            return
        }
        if self !== master?.activeSubordinate { return }

        if selectedFieldType == kExchangeTextField {
            dxExchange.becomeFirstResponder()
        } else if selectedFieldType == kCallsignTextField {
            dxCall.becomeFirstResponder()
        }
    }

    @objc func makeFieldFirstResponder() {
        Timer.scheduledTimer(timeInterval: 0.35, target: self, selector: #selector(timedMakeFieldFirstResponder), userInfo: self, repeats: false)
    }

    //  select the text field in the active subordinate
    @objc override func selectActiveField() {
        if master == nil {
            activeSubordinate?.selectActiveField()
            return
        }
        if self !== master?.activeSubordinate { return }

        if selectedFieldType == kExchangeTextField {
            selectExchangeField()
            dxExchange.selectText(self)
            dxExchange.becomeFirstResponder()
        } else if selectedFieldType == kCallsignTextField {
            selectCallsignField()
            dxCall.selectText(self)
            dxCall.becomeFirstResponder()
        }
    }

    //  new callsign entered
    @objc func newCallsign(_ notify: Notification) {
        guard let src = notify.object as? Modem else { return }

        //  check if we are the active interface
        let activeModem = manager?.selectedContestInterface()
        if client !== activeModem { return }

        if master != nil {
            let inBand = selectedBand()
            let capturedString = asciiCString(src.capturedString())     // strip phi
            var duped = false
            activeCall = master!.receivedCallsign(capturedString, band: inBand, isDupe: &duped)
            //  insert callsign into call field even if dupe, remembering activeCall==nil
            dxCall.stringValue = capturedString
            dxCall.display()

            if activeCall != nil {
                NotificationCenter.default.post(name: NSNotification.Name("RegisterAndUpdateTime"), object: nil)
                selectedFieldType = kExchangeTextField
                master!.setDupeState(false)
                if !duped { setWatermarkState(false) } else { setSmallWatermarkState(true) }
            } else {
                selectedFieldType = kCallsignTextField
                master!.setDupeState(true)
                setWatermarkState(true)
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
            dxExtra?.markAsSelected(false)
            selectedFieldType = kCallsignTextField
        case kExchangeTextField:
            NotificationCenter.default.post(name: NSNotification.Name(kExchangeNotify), object: dxExchange)
            dxCall.markAsSelected(false)
            dxExchange.markAsSelected(true)
            dxExtra?.markAsSelected(false)
            selectedFieldType = kExchangeTextField
        case kExtraTextField:
            if let dxExtra = dxExtra {
                NotificationCenter.default.post(name: NSNotification.Name(kExtraFieldNotify), object: dxExtra)
                dxCall.markAsSelected(false)
                dxExchange.markAsSelected(false)
                dxExtra.markAsSelected(true)
                selectedFieldType = kExtraTextField
            }
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

        if master != nil {
            let src = notify.object as? Modem
            let capturedString = asciiCString(src?.capturedString()) as NSString
            var length = capturedString.length
            if length > 10 { length = 10 }
            var str = capturedString.substring(with: NSRange(location: 0, length: length))

            if dxExchange != nil {
                str = asciiString(str)      // strip phi
                dxExchange.stringValue = str
                //  validate exchange and reselect the visible exchange field
                if !validateExchange(str) {
                    dxExchange.window?.makeKeyAndOrderFront(self)
                    dxExchange.stringValue = ""
                    dxExchange.selectText(self)
                }
                selectedFieldType = kExchangeTextField
            }
        }
    }

    //  initialize this contest here
    override func setupFields() {
        guard master != nil else { return }

        savedCallsign = ""; savedExchange = ""
        callFieldEmpty = true

        super.setupFields()

        upperFormatter = UpperFormatter()
        dxCall.formatter = upperFormatter
        dxRST.formatter = upperFormatter
        dxExchange.formatter = upperFormatter

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(newCallsign(_:)), name: NSNotification.Name("CapturedContestCallsign"), object: nil)
        nc.addObserver(self, selector: #selector(newExchange(_:)), name: NSNotification.Name("CapturedContestExchange"), object: nil)
        nc.addObserver(self, selector: #selector(selectActiveField), name: NSNotification.Name("FinishControlClick"), object: nil)
        nc.addObserver(self, selector: #selector(newFieldSelected(_:)), name: NSNotification.Name("SelectNewField"), object: nil)
        nc.addObserver(self, selector: #selector(makeFieldFirstResponder), name: NSNotification.Name("ReselectField"), object: nil)

        //  fields that overlap the watermark are transparent -- place above everything
        dxCall.moveAbove()
        dxCall.fieldType = kCallsignTextField
        dxRST.moveAbove()
        dxExchange.moveAbove()
        dxExchange.fieldType = kExchangeTextField
        qsoNumberField.moveAbove()
        if let dxExtra = dxExtra {
            dxExtra.moveAbove()
            dxExtra.fieldType = kExtraTextField
        }
        dxCall.delegate = self
        dxCall.nextKeyView = dxExchange
        dxExchange.nextKeyView = dxExchange     //  loop in dxExchange field
        selectedFieldType = kCallsignTextField

        setWatermarkState(false)
    }

    override func fetchCallString() -> String {
        return dxCall.stringValue
    }

    override func fetchSavedCallString() -> String {
        return savedCallsign
    }

    override func fetchReceivedExchange() -> String {
        return dxExchange.stringValue
    }

    override func fetchSavedReceivedExchange() -> String {
        return savedExchange
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

    //  override by subclass to set up default fields
    func clearFieldsToDefault() {
        dxCall?.stringValue = ""
        dxRST?.stringValue = "599"
        dxExchange?.stringValue = ""
        dxExtra?.stringValue = ""
    }

    @objc override func newQSO(_ n: Int32) {
        if master != nil {
            //  subordinate
            qsoNumberField.intValue = n
            clearFieldsToDefault()
            activeQSONumber = n
            return
        }
        //  master -- set up all subordinates then select first responder
        NotificationCenter.default.post(name: NSNotification.Name("RegisterTime"), object: nil)
        for i in 0..<Int(subordinates) { subordinate[i]?.newQSO(activeQSONumber) }
        selectFirstResponder()
    }

    @objc override func clearCurrentQSO() {
        if master != nil {
            //  subordinate
            clearFieldsToDefault()
            setWatermarkState(false)
            return
        }
        //  master
        NotificationCenter.default.post(name: NSNotification.Name("RegisterTime"), object: nil)
        setDupeState(false)
        for i in 0..<Int(subordinates) { subordinate[i]?.clearCurrentQSO() }
        selectFirstResponder()
    }

    //  create a log entry from an XML QSO element
    func enterQSOFromXML() {
        if master != nil { return }        //  must be a subordinate

        var t = DateTime()
        let timeParts = (qsoStrings[Int(kQSOTime)] ?? "").split(separator: ":", omittingEmptySubsequences: false)
        t.hour = UInt8(truncatingIfNeeded: timeParts.count > 0 ? leadingInt(String(timeParts[0])) : 0)
        t.minute = UInt8(truncatingIfNeeded: timeParts.count > 1 ? leadingInt(String(timeParts[1])) : 0)
        t.second = UInt8(truncatingIfNeeded: timeParts.count > 2 ? leadingInt(String(timeParts[2])) : 0)

        let dateParts = (qsoStrings[Int(kQSODate)] ?? "").split(separator: "/", omittingEmptySubsequences: false)
        t.day = UInt8(truncatingIfNeeded: dateParts.count > 0 ? leadingInt(String(dateParts[0])) : 1)
        t.month = UInt8(truncatingIfNeeded: dateParts.count > 1 ? leadingInt(String(dateParts[1])) : 1)
        t.year = UInt8(truncatingIfNeeded: dateParts.count > 2 ? leadingInt(String(dateParts[2])) : 5)

        if (qsoStrings[Int(kQSOCall)] ?? "").isEmpty {
            activeCall = hashCallsign("NIL")
        } else if let c = (qsoStrings[Int(kQSOCall)]! as NSString).cString(using: kLatin1) {
            activeCall = hashCallsign(c)
        }

        let p = UnsafeMutablePointer<ContestQSO>.allocate(capacity: 1)
        p.pointee.frequency = 14.080
        if let f = qsoStrings[Int(kQSOFreq)], !f.isEmpty { p.pointee.frequency = leadingFloat(f) }
        importedFrequency = p.pointee.frequency

        //  QSO number
        p.pointee.qsoNumber = 0
        if let num = qsoStrings[Int(kQSONumber)], !num.isEmpty {
            p.pointee.qsoNumber = UInt16(truncatingIfNeeded: leadingInt(num))
        }
        if Int32(p.pointee.qsoNumber) >= activeQSONumber { activeQSONumber = Int32(p.pointee.qsoNumber) }
        //  QSO time
        p.pointee.time = t
        //  QSO mode
        p.pointee.mode = Int16(truncatingIfNeeded: modeForString(qsoStrings[Int(kQSOMode)] ?? ""))
        //  RST
        var rst: Int32 = 599
        if let r = qsoStrings[Int(kQSORST)], !r.isEmpty { rst = leadingInt(r) }
        p.pointee.rst = Int16(truncatingIfNeeded: rst)

        //  exchange (kept even when empty so writeCabrilloQSOs strncpy has a valid ptr)
        if let str = qsoStrings[Int(kQSOExch)] {
            let ns = str as NSString
            let buf = malloc(ns.length + 1)!.assumingMemoryBound(to: CChar.self)
            if let c = ns.cString(using: kLatin1) { strcpy(buf, c) } else { buf[0] = 0 }
            p.pointee.exchange = buf
        } else {
            let buf = malloc(1)!.assumingMemoryBound(to: CChar.self)
            buf[0] = 0
            p.pointee.exchange = buf
        }

        createQSO(p, callsign: activeCall, mode: activeMode)

        for i in 1..<7 { qsoStrings[i] = nil }
    }

    /* local -- master only.  returns true if successful, false if duped */
    func setDXCall(_ str: String, panel: Contest, isDupe duped: inout Bool) -> Bool {
        if master != nil { return false }
        activeBand = panel.selectedBand()
        activeCall = receivedCallsign(str, band: activeBand, isDupe: &duped)
        return activeCall != nil
    }

    //  set master entry from dxRSTSet
    func setDXRST(_ string: String, panel: RSTExchange) {
        //  no need to do anything, the textField already has the string
    }

    @objc func callFieldChanged() {
        var string = dxCall.stringValue
        if string == previousCall { return }

        NotificationCenter.default.post(name: NSNotification.Name("RegisterTime"), object: nil)

        if !string.isEmpty {
            callFieldEmpty = false
            var realDupe = false
            let notDupe = (master as? RSTExchange)?.setDXCall(string, panel: self, isDupe: &realDupe) ?? false

            if notDupe {
                NotificationCenter.default.post(name: NSNotification.Name("RegisterAndUpdateTime"), object: nil)
                if realDupe { setSmallWatermarkState(true) }
                selectedFieldType = kExchangeTextField
                activeCall = master?.currentCallsign()
                dxExchange.setIgnoreFirstResponder(false)
                selectExchangeField()
            } else {
                selectedFieldType = kCallsignTextField
                activeCall = nil
                setWatermarkState(true)
                dxExchange.setIgnoreFirstResponder(true)
                string = ""
            }
        } else {
            //  always clear dupe if dxField is cleared
            if !callFieldEmpty { setWatermarkState(false) }
            callFieldEmpty = true
            dxExchange.setIgnoreFirstResponder(false)
        }
        previousCall = string
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

    //  override if class has a third field
    @objc func extraFieldChanged() {
    }

    @objc func rstFieldChanged() {
        if master != nil { setDXRST(dxRST.stringValue, panel: self) }
    }

    override func createQSOFromCurrentData() -> UnsafeMutablePointer<ContestQSO> {
        let p = super.createQSOFromCurrentData()
        p.pointee.callsign = currentCallsign()
        let ns = dxExchange.stringValue as NSString
        let buf = malloc(ns.length + 1)!.assumingMemoryBound(to: CChar.self)
        if let c = ns.cString(using: kLatin1) { strcpy(buf, c) } else { buf[0] = 0 }
        p.pointee.exchange = buf
        p.pointee.rst = Int16(truncatingIfNeeded: dxRST.intValue)
        return p
    }

    //  this is where we log a QSO using -createQSOFromCurrentData
    @objc override func logButtonPushed() {
        //  check DX fields
        if isEmpty(dxCall) || isEmpty(dxExchange) {
            Messages.alert(withMessageText: "Not all field are filled.", informativeText: "Call sign and exchange fields need to be non-empty.  Please fill them and click on Log again.")
            return
        }
        if master != nil {
            savedCallsign = dxCall.stringValue
            savedExchange = dxExchange.stringValue

            if (master as? RSTExchange)?.validateExchange(savedExchange) ?? false {
                //  get call from dxCall field; if it was a dupe, create one
                if activeCall == nil {
                    let c = dxCall.stringValue
                    activeCall = getCallsign((c as NSString).cString(using: kLatin1))
                }
                let p = createQSOFromCurrentData()
                master!.createQSO(p, callsign: activeCall, mode: activeMode)
                master!.journalQSO(p)
                master!.newQSO(0)
                selectCallsignField()
            } else {
                dxExchange.stringValue = ""
                dxExchange.selectText(self)
            }
            master!.setDupeState(false)
            setWatermarkState(false)

            master!.logMacro()
        } else {
            setDupeState(false)
        }
    }

    override func saveQSOToXML(_ file: UnsafeMutablePointer<FILE>?, qso q: UnsafeMutablePointer<ContestQSO>) {
        cmFPuts("\t\t<QSO>\n", file)
        saveQSONumberToXML(file, q)
        saveCallToXML(file, q)
        saveDateToXML(file, q)
        saveTimeToXML(file, q)
        saveModeToXML(file, q)
        saveRSTToXML(file, q)
        saveExchangeToXML(file, q)
        saveFrequencyToXML(file, q)
        cmFPuts("\t\t</QSO>\n", file)
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
                    else if elementName == "rst" { parseQSOPhase = kQSORST }
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
        else if elementName == "rst" { parseQSOPhase = 0 }
        else if elementName == "freq" { parseQSOPhase = 0 }
        else if elementName == "mode" { parseQSOPhase = 0 }
        else if elementName == "qnum" { parseQSOPhase = 0 }
        else if elementName == "contestName" { parseContestName = false }
        else if elementName == "contestLog" { parseContestLog = false }
        else if elementName == "Contest" { parseContest = false }
    }

    //  delegate for callsign text field
    func controlTextDidChange(_ obj: Notification) {
        //  clear dupe state and watermark
        master?.setDupeState(false)
        setWatermarkState(false)
    }
}
