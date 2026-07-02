//
//  NumberOnly.swift
//  cocoaModem
//
//  Created by Kok Chen on 1/2/05.
//
//  Swift port of NumberOnly.m.  Exchange is a plain QSO number.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

@objc(NumberOnly)
class NumberOnly: RSTExchange {

    //  check state/number here
    override func validateExchange(_ exchange: String) -> Bool {
        guard let s = (exchange as NSString).cString(using: kLatin1) else { return false }
        var t = s
        var c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1

        if isNumeric[c] {
            while c > 0 {
                if !isNumeric[c] {
                    dxExchange.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "The exchange needs to be a QSO number.")
                    dxExchange.markAsSelected(false)
                    return false
                }
                c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1
            }
            return true
        }
        dxExchange.markAsSelected(true)
        Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "The exchange needs to be a QSO number.")
        dxExchange.markAsSelected(false)
        return false
    }

    override func setupFields() {
        super.setupFields()
        if master != nil { master?.setCabrilloContestName("Numbers Exchange") }
    }

    // Use BARTG Sprint format for Cabrillo
    override func writeCabrilloQSOs() {
        var myCall = ""
        if let used = usedCallString { myCall = cTrunc(used, 13) }

        var count: Int32 = 0
        for i in 0..<Int(MAXQ) {
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

            //  QSO: 21000 RY 2002-01-26 1201 GW4BRS            0001   RW3LB             0001
            var line = "QSO: " + String(format: "%5d", frequency % 100000) + " " + rjust(mode, 2) + " "
            line += String(format: "%4d-%02d-%02d %04d ", year, month, day, utc)
            line += ljust(myCall, 18)
            line += String(format: "%04d   ", Int(q.pointee.qsoNumber))
            line += ljust(callsign, 18)

            let num = scanLeadingInt(latin1String(q.pointee.exchange), 1)
            line += String(format: "%04d", Int(num))
            line += "\n"
            cmFPuts(line, cabrilloFile)

            count += 1
            if count >= numberOfQSO { break }
        }
    }
}
