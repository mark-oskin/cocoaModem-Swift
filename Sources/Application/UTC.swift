//
//  UTC.swift
//  cocoaModem 2.0
//
//  Swift port of UTC.m (Kok Chen, 11/28/04).
//

import Foundation

@objc(UTC)
class UTC: NSObject {
    private let gmttime = UnsafeMutablePointer<tm>.allocate(capacity: 1)
    private var t: time_t = 0

    deinit {
        gmttime.deallocate()
    }

    //  set structure to GMT time, also return tm pointer
    @objc @discardableResult
    func setTime() -> UnsafeMutablePointer<tm> {
        t = time(nil)
        gmttime.pointee = gmtime(&t).pointee
        return gmttime
    }

    //  tm pointer
    @objc
    func utc() -> UnsafeMutablePointer<tm> {
        return gmttime
    }
}
