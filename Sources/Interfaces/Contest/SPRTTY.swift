//
//  SPRTTY.swift  (from "SP RTTY.m")
//  cocoaModem
//
//  Created by Kok Chen on 3/31/06.
//
//  Swift port of "SP RTTY.m".  SP DX RTTY contest.  Subclass of RSTExchange.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

//  (SPStateList in the original) -- Polish Wojewodztwo abbreviations
private let spRawStateList: [(abbrev: String, area: Int8)] = [
    ("B", 1), ("C", 1), ("D", 1), ("F", 1), ("G", 1), ("J", 1),
    ("K", 1), ("L", 1), ("M", 1), ("O", 1), ("P", 1), ("R", 1),
    ("S", 1), ("U", 1), ("W", 1), ("Z", 1),
    ("**", 40)
]

@objc(SPRTTY)
class SPRTTY: RSTExchange {

    //  check state/number here
    override func validateExchange(_ exchange: String) -> Bool {
        guard let s = (exchange as NSString).cString(using: kLatin1) else { return false }
        var t = s
        let c0 = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1

        //  province if first character is alpha
        if isAlpha[c0] {
            var idx = 0
            while true {
                if spRawStateList[idx].abbrev == exchange { return true }
                idx += 1
                if Int(spRawStateList[idx].area) > 39 {
                    dxExchange.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad Wojewodztwo (province) abbreviation.", informativeText: "Province should be one of B, C, D, F, G, J, K, L, M, O, P, R, S, U, W, Z.")
                    dxExchange.markAsSelected(false)
                    return false
                }
            }
        }
        //  number?
        var c = c0
        if isNumeric[c] {
            while c > 0 {
                if !isNumeric[c] {
                    dxExchange.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "SP RTTY exchange needs to be a Polish Wojewodztwo (1 letter abbreviation) or a QSO number (everyone else).")
                    dxExchange.markAsSelected(false)
                    return false
                }
                c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1
            }
            return true
        }
        dxExchange.markAsSelected(true)
        Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "SP RTTY exchange needs to be a Polish Wojewodztwo (1 letter abbreviation) or a QSO number (everyone else).")
        dxExchange.markAsSelected(false)
        return false
    }

    override func setupFields() {
        super.setupFields()
        if master != nil { master?.setCabrilloContestName("SP-DX-RTTY-C") }
    }

    override func writeCabrilloQSOs() {
        var myCall = ""
        if let used = usedCallString { myCall = cTrunc(used, 13) }

        var count: Int32 = 0
        for i in 0..<Int(MAXQ) {
            //  QSO: 14089 RY 2002-04-06 1629 4Z5LA         599    080 SP6ZLC        599      D
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
            line += ljust(myCall, 14)
            line += String(format: "599  %5d ", Int(q.pointee.qsoNumber))
            line += ljust(callsign, 14)

            var rst = Int(q.pointee.rst)
            if rst > 599 { rst = 599 } else if rst < 111 { rst = 111 }

            let exchange = cTrunc(latin1String(q.pointee.exchange), 7)
            line += String(format: "%3d   ", rst) + rjust(exchange, 4)
            line += "\n"
            cmFPuts(line, cabrilloFile)

            count += 1
            if count >= numberOfQSO { break }
        }
    }
}
