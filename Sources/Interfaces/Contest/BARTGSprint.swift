//
//  BARTGSprint.swift
//  cocoaModem
//
//  Created by Kok Chen on 1/2/05.
//
//  Swift port of BARTGSprint.m.  BARTG Sprint (number-only exchange).
//  Subclass of NumberOnly.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

@objc(BARTGSprint)
class BARTGSprint: NumberOnly {

    override func setupFields() {
        super.setupFields()
        if master != nil {
            master?.setCabrilloContestName("BARTG-SPRINT")
            master?.setCabrilloCategorySuffix("RTTY")
        }
    }

    override func writeCabrilloFields() {
        super.writeCabrilloFields()

        let section = userInfo?.section() ?? ""
        if section.isEmpty {
            Messages.alert(withMessageText: "No ARRL Section in User Info panel.", informativeText: "Assume BARTG entry is from outside USA/Canada.\n\nOtherwise, please enter ARRL Section info in the User Info panel and save to Cabrillo again.")
        }

        //  check if we are DX
        var isDX = false
        let qth = userInfo?.qth() ?? ""
        if qth.isEmpty {
            isDX = true
            Messages.alert(withMessageText: "State/Province/DX field in User Info panel is empty.", informativeText: "Assume BARTG entry is from outside USA/Canada.\n\nOtherwise, please enter ARRL Section info in the User Info panel and save to Cabrillo again.")
        } else {
            let qths = Array(qth.utf8)
            isDX = (qths.count > 1) && (qths[0] == UInt8(ascii: "d") || qths[0] == UInt8(ascii: "D")) && (qths[1] == UInt8(ascii: "x") || qths[1] == UInt8(ascii: "X"))
        }
        if isDX {
            cmFPuts("ARRL-SECTION: DX\n", cabrilloFile)
        } else {
            cmFPuts("ARRL-SECTION: \(section)\n", cabrilloFile)
        }
    }

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
