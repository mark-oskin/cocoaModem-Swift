//
//  RST_Number.swift  (from "RST Number.m")
//  cocoaModem
//
//  Created by Kok Chen on 1/2/05.
//
//  Swift port of "RST Number.m".  RST + QSO number.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

@objc(RST_Number)
class RST_Number: RSTExchange {

    //  check number here
    override func validateExchange(_ exchange: String) -> Bool {
        guard let s = (exchange as NSString).cString(using: kLatin1) else { return false }
        var t = s
        var c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1

        if isNumeric[c] {
            while c > 0 {
                if !isNumeric[c] {
                    dxExchange.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "Exchange is a QSO number.")
                    dxExchange.markAsSelected(false)
                    return false
                }
                c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1
            }
            return true
        }
        dxExchange.markAsSelected(true)
        Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "Exchange is a QSO number.")
        dxExchange.markAsSelected(false)
        return false
    }

    override func setupFields() {
        super.setupFields()
        if master != nil { master?.setCabrilloContestName("RST-NUMBER") }
    }

    override func writeCabrilloQSOs() {
        var myCall = ""
        if let used = usedCallString { myCall = cTrunc(used, 13) }

        var count: Int32 = 0
        for i in 0..<Int(MAXQ) {
            //  QSO: 21080 RY 2004-01-03 1800 W7AY         599     OR AK0A         599     KS
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
            line += ljust(myCall, 13)
            line += String(format: "599%7d ", Int(q.pointee.qsoNumber))
            line += ljust(callsign, 13)

            var rst = Int(q.pointee.rst)
            if rst > 599 { rst = 599 } else if rst < 111 { rst = 111 }

            let exchange = cTrunc(latin1String(q.pointee.exchange), 7)
            line += String(format: "%3d", rst) + rjust(exchange, 7)
            line += "\n"
            cmFPuts(line, cabrilloFile)

            count += 1
            if count >= numberOfQSO { break }
        }
    }
}
