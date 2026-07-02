//
//  ContestQSOObj.swift
//  cocoaModem
//
//  Created by Kok Chen on 12/24/04.
//
//  Swift port of ContestQSOObj.m.  Encapsulates a ContestQSO (C struct)
//  into an Objective-C object so it can live in an NSMutableArray.
//

import Cocoa

//  file-private aliases resolve the C functions band()/rttyFrequency()
//  (declared in Contest.h) unambiguously, since the instance methods
//  band()/... would otherwise shadow them.
private let cBand: (Float) -> Int32 = band
private let cRttyFrequency: (Int32) -> Float = rttyFrequency

private let kLatin1 = String.Encoding.isoLatin1.rawValue

@objc(ContestQSOObj)
class ContestQSOObj: NSObject {

    //  the (non-owned) pointer into the contest's QSO table
    private var qso: UnsafeMutablePointer<ContestQSO>

    @objc(initWith:)
    init(with q: UnsafeMutablePointer<ContestQSO>) {
        qso = q
        super.init()
    }

    @objc func ptr() -> UnsafeMutablePointer<ContestQSO> {
        return qso
    }

    @objc func qsoNumber() -> Int32 {
        return Int32(qso.pointee.qsoNumber)
    }

    @objc func callsign() -> String {
        //  callsign[64] is the first member of struct _Callsign
        let cp = UnsafeRawPointer(qso.pointee.callsign!).assumingMemoryBound(to: CChar.self)
        return NSString(cString: cp, encoding: kLatin1) as String? ?? ""
    }

    //  return band (metres)
    @objc func band() -> Int32 {
        return cBand(qso.pointee.frequency)
    }

    @objc(setBand:)
    func setBand(_ value: Int32) {
        qso.pointee.frequency = cRttyFrequency(value)
    }

    @objc func time() -> UnsafeMutablePointer<DateTime> {
        return withUnsafeMutablePointer(to: &qso.pointee.time) { $0 }
    }

    @objc func rst() -> String {
        let val = Int(qso.pointee.rst)
        return (val == 0) ? "" : String(format: "%d", val)
    }

    @objc(setRST:)
    func setRST(_ rst: String) {
        var p: Int32 = 599
        let scanner = Scanner(string: rst)
        var v = 0
        if scanner.scanInt(&v) { p = Int32(truncatingIfNeeded: v) }
        qso.pointee.rst = Int16(truncatingIfNeeded: p)
    }

    @objc func exchange() -> String {
        guard let x = qso.pointee.exchange else { return "" }
        return NSString(cString: x, encoding: kLatin1) as String? ?? ""
    }

    @objc(setExchange:)
    func setExchange(_ exch: String) {
        //  matches the original: malloc( [exch length]+1 ) + strcpy, no free of old
        let ns = exch as NSString
        let len = ns.length
        let buf = malloc(len + 1)!.assumingMemoryBound(to: CChar.self)
        if let c = ns.cString(using: kLatin1) {
            strcpy(buf, c)
        } else {
            buf[0] = 0
        }
        qso.pointee.exchange = buf
    }

    //  return mode
    @objc func mode() -> String {
        switch Int32(qso.pointee.mode) {
        case RTTYMODE: return "RY"
        case CWMODE:   return "CW"
        case SSBMODE:  return "PH"
        case PSKMODE:  return "PK"
        default:       return "??"
        }
    }

    @objc(setQSOMode:)
    func setQSOMode(_ m: UnsafeMutablePointer<CChar>) {
        if strcmp(m, "RY") == 0 { qso.pointee.mode = Int16(RTTYMODE) }
        else if strcmp(m, "CW") == 0 { qso.pointee.mode = Int16(CWMODE) }
        else if strcmp(m, "PH") == 0 { qso.pointee.mode = Int16(SSBMODE) }
        else if strcmp(m, "PK") == 0 { qso.pointee.mode = Int16(PSKMODE) }
    }

    //  sort by callsign, arranging the same callsign by band
    @objc(sortByCallsign:)
    func sortByCallsign(_ other: ContestQSOObj) -> ComparisonResult {
        let order = (callsign() as NSString).compare(other.callsign())
        if order != .orderedSame { return order }

        //  same callsign, check band
        let band0 = band()
        let band1 = other.band()
        if band0 == band1 {
            //  same band, check QSO number
            return (Int32(qso.pointee.qsoNumber) < other.qsoNumber()) ? .orderedAscending : .orderedDescending
        }
        return (band0 < band1) ? .orderedAscending : .orderedDescending
    }

    //  reverse sort by callsign, arranging the same callsign by band
    @objc(reverseByCallsign:)
    func reverseByCallsign(_ other: ContestQSOObj) -> ComparisonResult {
        let order = (other.callsign() as NSString).compare(callsign())
        if order != .orderedSame { return order }

        let band0 = band()
        let band1 = other.band()
        if band0 == band1 {
            return (Int32(qso.pointee.qsoNumber) < other.qsoNumber()) ? .orderedAscending : .orderedDescending
        }
        return (band0 < band1) ? .orderedAscending : .orderedDescending
    }

    @objc(sortByNumber:)
    func sortByNumber(_ other: ContestQSOObj) -> ComparisonResult {
        return (Int32(qso.pointee.qsoNumber) < other.qsoNumber()) ? .orderedAscending : .orderedDescending
    }

    @objc(reverseByNumber:)
    func reverseByNumber(_ other: ContestQSOObj) -> ComparisonResult {
        return (Int32(qso.pointee.qsoNumber) > other.qsoNumber()) ? .orderedAscending : .orderedDescending
    }

    //  sort by band, in ascending QSO number
    @objc(sortByBand:)
    func sortByBand(_ other: ContestQSOObj) -> ComparisonResult {
        let diff = band() - other.band()
        if diff == 0 {
            return (Int32(qso.pointee.qsoNumber) < other.qsoNumber()) ? .orderedAscending : .orderedDescending
        }
        return (diff < 0) ? .orderedAscending : .orderedDescending
    }

    //  reverse sort by band, in ascending QSO number
    @objc(reverseByBand:)
    func reverseByBand(_ other: ContestQSOObj) -> ComparisonResult {
        let diff = band() - other.band()
        if diff == 0 {
            return (Int32(qso.pointee.qsoNumber) < other.qsoNumber()) ? .orderedAscending : .orderedDescending
        }
        return (diff > 0) ? .orderedAscending : .orderedDescending
    }
}
