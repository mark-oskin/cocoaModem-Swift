//
//  XERTTY.swift  (from "XE RTTY.m")
//  cocoaModem
//
//  Created by Kok Chen on 1/16/05.
//
//  Swift port of "XE RTTY.m".  XE (Mexico) RTTY contest.  Subclass of RSTExchange.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

//  (XEStateList in the original) -- Mexican state abbreviations
private let xeRawStateList: [(abbrev: String, area: Int8)] = [
    ("AGS", 1),
    ("BC", 1),  ("BCS", 1),
    ("CAM", 1), ("CHH", 1), ("CHS", 1), ("COA", 1), ("COL", 1),
    ("DF", 1),
    ("DGO", 1),
    ("EMX", 1),
    ("GRO", 1), ("GTO", 1),
    ("HGO", 1),
    ("JAL", 1),
    ("MIC", 1), ("MOR", 1),
    ("NAY", 1), ("NL", 1),
    ("OAX", 1),
    ("PUE", 1),
    ("QRO", 1), ("QTR", 1),
    ("SIN", 1), ("SLP", 1), ("SON", 1),
    ("TAB", 1), ("TLX", 1), ("TMS", 1),
    ("VER", 1),
    ("YUC", 1),
    ("ZAC", 1),
    ("**", 40)
]

@objc(XERTTY)
class XERTTY: RSTExchange {

    //  check state/number here
    override func validateExchange(_ exchange: String) -> Bool {
        guard let s = (exchange as NSString).cString(using: kLatin1) else { return false }
        var t = s
        let c0 = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1

        if isAlpha[c0] {
            var idx = 0
            while true {
                if xeRawStateList[idx].abbrev == exchange { return true }
                idx += 1
                if Int(xeRawStateList[idx].area) > 39 {
                    dxExchange.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad state abbreviation.", informativeText: "State should be one of AGS BC, BCS, CAM, CHH, CHS, COA, COL, DF, DGO, EMX, GRO, GTO, HGO, JAL, MIC, MOR, NAY, NL, OAX, PUE, QRO, QTR, SIN, SLP, SON, TAB, TLX, TMS, VER, YUC, ZAC.")
                    dxExchange.markAsSelected(false)
                    return false
                }
            }
        }
        var c = c0
        if isNumeric[c] {
            while c > 0 {
                if !isNumeric[c] {
                    dxExchange.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "XE RTTY exchange needs to be a Mexican State (2 or 3 letter abbreviation) or a QSO number (everyone else).")
                    dxExchange.markAsSelected(false)
                    return false
                }
                c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1
            }
            return true
        }
        dxExchange.markAsSelected(true)
        Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "XE RTTY exchange needs to be a Mexican State (2 or 3 letter abbreviation) or a QSO number (everyone else).")
        dxExchange.markAsSelected(false)
        return false
    }

    override func setupFields() {
        super.setupFields()
        if master != nil { master?.setCabrilloContestName("XE-RTTY") }
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
