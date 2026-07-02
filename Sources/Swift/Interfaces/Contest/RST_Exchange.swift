//
//  RST_Exchange.swift  (from "RST Exchange.m")
//  cocoaModem
//
//  Created by Kok Chen on 1/2/05.
//
//  Swift port of "RST Exchange.m".  RST + free exchange.
//

import Cocoa

@objc(RST_Exchange)
class RST_Exchange: RSTExchange {

    override func setupFields() {
        super.setupFields()
        if master != nil { master?.setCabrilloContestName("RST-EXCHANGE") }
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
            //  @@@ this should be from the Cabrillo info exchange field
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
