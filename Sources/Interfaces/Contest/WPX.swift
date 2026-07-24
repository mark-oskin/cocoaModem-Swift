//
//  WPX.swift
//  cocoaModem
//
//  Created by Kok Chen on 1/2/05.
//
//  Swift port of WPX.m.  CQ WPX RTTY contest.  Subclass of RST_Number.
//

import Cocoa

@objc(WPX)
class WPX: RST_Number {

    override func setupFields() {
        super.setupFields()
        if master != nil { master?.setCabrilloContestName("CQ-WPX-RTTY") }
    }

    override func writeCabrilloQSOs() {
        var myCall = ""
        if let used = usedCallString { myCall = cTrunc(used, 13) }

        var count: Int32 = 0
        for i in 0..<Int(MAXQ) {
            // WPX
            // QSO: 28000 RY 2002-02-10 2126 LU/N5KO       599 0001   KA4RRU        599 0530
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
            line += String(format: "599 %04d   ", Int(q.pointee.qsoNumber))
            line += ljust(callsign, 14)

            var rst = Int(q.pointee.rst)
            if rst > 599 { rst = 599 } else if rst < 111 { rst = 111 }

            let num = scanLeadingInt(latin1String(q.pointee.exchange), 1)
            line += String(format: "%3d %04d", rst, Int(num))
            line += "\n"
            cmFPuts(line, cabrilloFile)

            count += 1
            if count >= numberOfQSO { break }
        }
    }
}
