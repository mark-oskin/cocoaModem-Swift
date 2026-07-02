//
//  BARTG.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/12/06.
//
//  Swift port of BARTG.m.  BARTG HF RTTY (QSO number + UTC time exchange).
//  Subclass of RSTExchange.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

@objc(BARTG)
class BARTG: RSTExchange {

    var exchSent: String = ""
    var isDX = false

    private func validateNumber(_ exchange: String) -> Bool {
        guard let s = (exchange as NSString).cString(using: kLatin1) else { return false }
        var t = s
        var c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1

        if isNumeric[c] {
            while c > 0 {
                if !isNumeric[c] {
                    dxExchange.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "BARTG HF exchange needs to be a QSO number and a UTC time")
                    dxExchange.markAsSelected(false)
                    return false
                }
                c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1
            }
            return true
        }
        dxExchange.markAsSelected(true)
        Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "BARTG HF exchange needs to be a QSO number and a UTC time")
        dxExchange.markAsSelected(false)
        return false
    }

    private func validateTime(_ exchange: String) -> Bool {
        guard let s = (exchange as NSString).cString(using: kLatin1) else { return false }
        var t = s
        var c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1

        if isNumeric[c] {
            while c > 0 {
                if !isNumeric[c] {
                    dxExtra.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad UTC time.", informativeText: "BARTG HF exchange needs to be a QSO number and a UTC time")
                    dxExtra.markAsSelected(false)
                    return false
                }
                c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1
            }
            let time = scanLeadingInt(exchange, 0)
            if (exchange as NSString).length != 4 || time < 0 || time > 2359 {
                dxExtra.markAsSelected(true)
                Messages.alert(withMessageText: "Error -- bad UTC format.", informativeText: "UTC time should be a 4 digit 24-hour UTC time")
                dxExtra.markAsSelected(false)
                return false
            }
            return true
        }
        dxExtra.markAsSelected(true)
        Messages.alert(withMessageText: "Error -- bad UTC time.", informativeText: "BARTG HF exchange needs to be a QSO number and a UTC time")
        dxExtra.markAsSelected(false)
        return false
    }

    @objc override func exchangeFieldChanged() {
        if master != nil {
            let string = dxExchange.stringValue
            if !string.isEmpty {
                if !validateNumber(string) {
                    dxExchange.stringValue = ""
                    dxExchange.selectText(self)
                } else {
                    selectedFieldType = kExtraTextField
                    dxExtra.setIgnoreFirstResponder(false)
                    selectExtraField()
                }
            } else {
                //  stay in QSO number field
                selectedFieldType = kExchangeTextField
                dxExtra.setIgnoreFirstResponder(true)
            }
        } else {
            dxExtra.setIgnoreFirstResponder(false)
        }
    }

    @objc override func extraFieldChanged() {
        if master != nil {
            let str = dxExtra.stringValue
            if !str.isEmpty {
                if !validateTime(str) {
                    dxExtra.stringValue = ""
                    dxExtra.selectText(self)
                }
            }
        }
    }

    //  set up the extra UTC field in the key view chain
    override func setupFields() {
        super.setupFields()
        //  extend key view chain to include UTC field
        dxExchange.nextKeyView = dxExtra
        dxExtra.nextKeyView = dxExtra       //  loop in dxExtra (UTC) field
        NotificationCenter.default.addObserver(self, selector: #selector(newSecondExchange(_:)), name: NSNotification.Name("CapturedSecondExchange"), object: nil)

        if master != nil { master?.setCabrilloContestName("BARTG-RTTY") }
    }

    //  check GMT here
    @objc func newSecondExchange(_ notify: Notification) {
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
                if !validateTime(str) {
                    dxExchange.window?.makeKeyAndOrderFront(self)
                    dxExchange.stringValue = ""
                    dxExchange.selectText(self)
                }
                selectedFieldType = kExtraTextField
            }
        }
    }

    //  merge the received QSO number and UTC into a single exchange field
    override func createQSOFromCurrentData() -> UnsafeMutablePointer<ContestQSO> {
        let p = super.createQSOFromCurrentData()
        p.pointee.callsign = currentCallsign()

        let str1 = dxExchange.stringValue
        let str2 = dxExtra.stringValue
        let combined = str1 + "-" + str2
        let ns = combined as NSString
        let buf = malloc(ns.length + 1)!.assumingMemoryBound(to: CChar.self)
        if let c = ns.cString(using: kLatin1) { strcpy(buf, c) } else { buf[0] = 0 }
        p.pointee.exchange = buf

        p.pointee.rst = Int16(truncatingIfNeeded: dxRST.intValue)
        return p
    }

    //  NOTE: QSO number and UTC received are saved as 123-0030 format internally
    override func writeCabrilloFields() {
        super.writeCabrilloFields()

        let section = userInfo?.section() ?? ""
        if section.isEmpty {
            Messages.alert(withMessageText: "No ARRL Section in User Info panel.", informativeText: "Assume BARTG entry is from outside USA/Canada.\n\nOtherwise, please enter ARRL Section info in the User Info panel and save to Cabrillo again.")
        }

        isDX = false
        let qth = userInfo?.qth() ?? ""
        if qth.isEmpty {
            isDX = true
            Messages.alert(withMessageText: "State/Province/DX field in User Info panel is empty.", informativeText: "Assume BARTG entry is from outside USA/Canada.\n\nOtherwise, please enter ARRL Section info in the User Info panel and save to Cabrillo again.")
        } else {
            let qths = Array(qth.utf8)
            isDX = (qths.count > 1) && (qths[0] == UInt8(ascii: "d") || qths[0] == UInt8(ascii: "D")) && (qths[1] == UInt8(ascii: "x") || qths[1] == UInt8(ascii: "X"))
            exchSent = ""
            if !isDX { exchSent = cTrunc(qth, 7) }
        }
        cmFPuts("ARRL-SECTION: \(section)\n", cabrilloFile)
    }

    override func writeCabrilloQSOs() {
        var myCall = ""
        if let used = usedCallString { myCall = cTrunc(used, 13) }

        var count: Int32 = 0
        for i in 0..<Int(MAXQ) {
            //                                             QSO  UTC              QSO  UTC
            //  QSO: 28000 RY 2002-03-17 0910 ZZ6ZZ      599 0001 0908 CT1AGF     599 0321 0909
            guard let q = sortedQSOList[i] else { continue }

            let callName = latin1String(callsignCName(q.pointee.callsign))
            if callName.isEmpty || callName == "NIL" { continue }

            let frequency = Int(q.pointee.frequency * 1000.0 + 0.1)
            var mode = stringForMode(Int32(q.pointee.mode))
            if mode == "PK" { mode = "RY" }
            let time = q.pointee.time
            var year = Int(time.year); if year < 2000 { year += 2000 }
            let month = Int(time.month)
            let day = Int(time.day)
            let utc = Int(time.hour) * 100 + Int(time.minute)

            let callsign = cTrunc(callName, 13)

            var line = "QSO: " + String(format: "%5d", frequency % 100000) + " " + rjust(mode, 2) + " "
            line += String(format: "%4d-%02d-%02d %04d ", year, month, day, utc)

            line += ljust(myCall, 11)
            line += String(format: "599 %04d %04d ", Int(q.pointee.qsoNumber), utc)

            line += ljust(callsign, 11)

            var rst = Int(q.pointee.rst)
            if rst > 599 { rst = 599 } else if rst < 111 { rst = 111 }

            //  sscanf( q->exchange, "%d-%d", &rxNumber, &rxUTC )
            let exch = latin1String(q.pointee.exchange)
            let parts = exch.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let rxNumber = parts.count > 0 ? scanLeadingInt(String(parts[0]), 0) : 0
            let rxUTC = parts.count > 1 ? scanLeadingInt(String(parts[1]), 0) : 0

            line += String(format: "%3d %04d %04d", rst, Int(rxNumber), Int(rxUTC))
            line += "\n"
            cmFPuts(line, cabrilloFile)

            count += 1
            if count >= numberOfQSO { break }
        }
    }
}
