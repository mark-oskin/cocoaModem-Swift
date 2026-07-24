//
//  CMATCBuffer.swift
//  CoreModem
//
//  Created by Kok Chen on 10/25/05
//	(ported from cocoaModem, original file dated Sat Aug 07 2004)
//  Swift port of CMATCBuffer.{h,m}.  Accumulates two 256-sample ATC halves into
//  a 512-sample scope buffer and exports it to the tap.
//

import Foundation

@objc(CMATCBuffer)
class CMATCBuffer: CMTappedPipe {

    internal let buf: UnsafeMutablePointer<Float>   // was float[512]
    internal var mux: Int32

    override init() {
        buf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        buf.initialize(repeating: 0, count: 512)
        mux = 0
        super.init()
        outputClient = nil
        data.pointee.array = buf
        data.pointee.samples = 512
        data.pointee.components = 1
        data.pointee.channels = 1
        mux = 0
    }

    deinit {
        buf.deallocate()
    }

    //  export data to scope if the tap is active; each call has 256 samples
    @objc(atcData:)
    func atcData(_ atc: UnsafeMutablePointer<CMATCStream>!) {
        if tapClient != nil {
            //  `data` is the first field of CMATCStream (offset 0)
            let dataBase = UnsafeMutableRawPointer(atc).assumingMemoryBound(to: CMATCPair.self)
            var pair = dataBase.advanced(by: 128)
            if mux == 0 {
                for i in 0..<256 {
                    buf[i] = Float(Double(pair.pointee.mark - pair.pointee.space) * 0.6)
                    pair = pair.advanced(by: 1)
                }
                mux += 1
            } else {
                mux = 0
                for i in 256..<512 {
                    buf[i] = Float(Double(pair.pointee.mark - pair.pointee.space) * 0.6)
                    pair = pair.advanced(by: 1)
                }
                exportData()
            }
        }
    }
}
