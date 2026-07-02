//
//  RTTYRoundup.swift
//  cocoaModem
//
//  Created by Kok Chen on 11/27/04.
//
//  Swift port of RTTYRoundup.m.  ARRL RTTY Roundup, with a state/province
//  multiplier table.  Subclass of RSTExchange.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

//  shared raw state list (was a file-static StateList[64]).  The abbrev strings
//  are strdup'd once and live for the lifetime of the process.
private let rttyRawStateList: UnsafeMutablePointer<StateList> = {
    let entries: [(String, Int8)] = [
        ("AL", 4),  ("AR", 5),  ("AZ", 7),  ("CA", 6),
        ("CO", 0),  ("CT", 1),  ("DC", 3),  ("DE", 3),
        ("FL", 4),  ("GA", 4),  ("IA", 0),  ("ID", 7),
        ("IL", 9),  ("IN", 9),  ("KS", 0),  ("KY", 4),
        ("LA", 5),  ("MA", 1),  ("MD", 3),  ("ME", 1),
        ("MI", 8),  ("MN", 0),  ("MO", 0),  ("MS", 5),
        ("MT", 7),  ("NC", 4),  ("ND", 0),  ("NE", 0),
        ("NH", 1),  ("NJ", 2),  ("NM", 5),  ("NV", 7),
        ("NY", 2),  ("OH", 8),  ("OK", 5),  ("OR", 7),
        ("PA", 3),  ("RI", 1),  ("SC", 4),  ("SD", 0),
        ("TN", 4),  ("TX", 5),  ("UT", 7),  ("VA", 4),
        ("VT", 1),  ("WA", 7),  ("WI", 9),  ("WV", 8),
        ("WY", 7),
        ("AB", 26), ("BC", 27), ("LB", 21), ("MB", 24),
        ("NB", 21), ("NF", 21), ("NS", 21), ("NWT", 29),
        ("VY0", 30), ("ON", 23), ("PEI", 21), ("QC", 22),
        ("SK", 25), ("YT", 28),
        ("**", 40)
    ]
    let p = UnsafeMutablePointer<StateList>.allocate(capacity: 64)
    memset(p, 0, 64 * MemoryLayout<StateList>.stride)
    for (i, e) in entries.enumerated() {
        p[i].abbrev = strdup(e.0)
        p[i].area = e.1
    }
    return p
}()

@objc(RTTYRoundup)
class RTTYRoundup: RSTExchange {

    var exchSent: String = ""
    var isDX = false
    private var mult: RTTYRoundupMults?

    //  master-only set-up before the XML parse (replaces the pre-super work in
    //  the original -initContestName override)
    override func prepareForParsing() {
        mult = RTTYRoundupMults()
        Bundle.main.loadNibNamed("RTTYRoundupMults", owner: mult, topLevelObjects: nil)

        //  initialize the mult info (column layout + reset worked counts)
        var columns = [Int](repeating: 0, count: 11)
        var i = 0
        while i < 64 {
            if rttyRawStateList[i].abbrev!.pointee == Int8(UInt8(ascii: "*")) { break }
            rttyRawStateList[i].worked = 0
            var area = Int(rttyRawStateList[i].area)
            if area < 10 {
                area -= 1
                if area < 0 { area = 9 }
                rttyRawStateList[i].y = Int16(area)
                rttyRawStateList[i].x = Int16(columns[area]); columns[area] += 1
            } else {
                area = 10    // Canada
                var n = columns[area]; columns[area] += 1
                if n > 7 { n -= 8; area = 11 }
                rttyRawStateList[i].y = Int16(area)
                rttyRawStateList[i].x = Int16(n)
            }
            i += 1
        }
    }

    override func createMult(_ p: UnsafeMutablePointer<ContestQSO>) {
        if master != nil {
            (master as? RTTYRoundup)?.createMult(p)
            return
        }
        mult?.updateMult(p, statelist: rttyRawStateList)
    }

    //  check state/number here
    override func validateExchange(_ exchange: String) -> Bool {
        guard let s = (exchange as NSString).cString(using: kLatin1) else { return false }
        var t = s
        let c0 = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1

        //  state/province if first character is alpha
        if isAlpha[c0] {
            var idx = 0
            while true {
                if strcmp(rttyRawStateList[idx].abbrev, s) == 0 { return true }
                idx += 1
                if Int(rttyRawStateList[idx].area) > 39 {
                    dxExchange.markAsSelected(true)
                    Messages.alert(withMessageText: "Error -- bad state/province abbreviation.", informativeText: "State should be one of AL, AR, AZ, CA, CO, CT, DC, DE, FL, GA, IA, ID, IL, IN, KS, KY, LA, MA, MD, ME, MI, MN, MO, MS, MT, NC, ND, NE, NH, NJ, NM, NV, NY, OH, OK, OR, PA, RI, SC, SD, TN, TX, UT, VA, VT, WA, WI, WV, WY.\n\nProvince should be one of AB, BC, LB, MB, NB, NF, NS, NWT, ON, PEI, QC, SK, VY0, YT.\n\nNote that AK and HI are not counted as states in the RTTY Roundup.")
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
                    Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "RTTY Roundup exchange needs to be a State/Province (2 letter abbreviation) or a QSO number (for DX)")
                    dxExchange.markAsSelected(false)
                    return false
                }
                c = Int(UInt8(bitPattern: t.pointee)) & 0xff; t += 1
            }
            return true
        }
        dxExchange.markAsSelected(true)
        Messages.alert(withMessageText: "Error -- bad exchange.", informativeText: "RTTY Roundup exchange needs to be a State/Province (2 letter abbreviation) or a QSO number (for DX)")
        dxExchange.markAsSelected(false)
        return false
    }

    override func setupFields() {
        super.setupFields()
        if master != nil { master?.setCabrilloContestName("ARRL-RTTY") }
    }

    override func writeCabrilloFields() {
        super.writeCabrilloFields()

        let section = userInfo?.section() ?? ""
        if section.isEmpty {
            Messages.alert(withMessageText: "No ARRL Section in User Info panel.", informativeText: "Assume RTTY Roundup entry is from outside USA/Canada.\n\nOtherwise, please enter ARRL Section info in the User Info panel and save to Cabrillo again.")
        }

        //  check if we are DX
        isDX = false
        let qth = userInfo?.qth() ?? ""
        if qth.isEmpty {
            isDX = true
            Messages.alert(withMessageText: "State/Province/DX field in User Info panel is empty.", informativeText: "Assume RTTY Roundup entry is from outside USA/Canada.\n\nOtherwise, please enter ARRL Section info in the User Info panel and save to Cabrillo again.")
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
            if !isDX {
                line += "599" + rjust(exchSent, 7) + " "
            } else {
                line += String(format: "599%7d ", Int(q.pointee.qsoNumber))
            }
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

    override func showMultsWindow() {
        if master == nil, let mult = mult { mult.showWindow(rttyRawStateList) }
    }
}
