//
//  CMFilter.swift
//  Filter (CoreModem)
//
//  Created by Kok Chen on 10/28/05.
//  Swift port of CMFilter.{h,m}.  A CMTappedPipe that runs an FIR (CMFIR) over
//  the incoming 512-sample block.
//
//  Coordination notes (subclasses CMBandpassFilter / CMLowpassFilter depend on
//  these EXACT names): n, fir, filter.  The `userParam` ivar collides with the
//  -userParam accessor selector, so the stored property is `userParamStore`
//  (only CMFilter itself touches it).
//
//  Name collision: the original ivar `CMDataStream stream` collides with the
//  inherited -stream accessor.  The stored property is renamed `streamStore`
//  (heap allocated so `data` keeps a stable address exactly as `data = &stream`
//  did in C); the -stream selector stays on CMPipe.  outbuf is likewise a heap
//  buffer so the exported stream's array pointer stays valid.
//

import Foundation

@objc(CMFilter)
class CMFilter: CMTappedPipe {

    internal var n: Int32
    internal var fir: UnsafeMutablePointer<Float>?
    internal var filter: UnsafeMutablePointer<CMFIR>?
    internal var userParamStore: Float
    //  was `float outbuf[512]`
    internal let outbuf: UnsafeMutablePointer<Float>
    //  was `CMDataStream stream` (renamed to avoid the -stream selector collision)
    internal let streamStore: UnsafeMutablePointer<CMDataStream>

    override init() {
        n = 0
        fir = nil
        filter = nil
        userParamStore = 0.0
        outbuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        outbuf.initialize(repeating: 0, count: 512)
        streamStore = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        streamStore.initialize(to: CMDataStream())
        super.init()
        userParamStore = 0.0
        n = 0
        fir = nil
        filter = nil
    }

    deinit {
        //  `fir` is malloc'd (float*) -- free it (ARC does not).
        if let fir = fir { free(fir) }
        //  `filter` (CMFIR*) is intentionally NOT deleted: the original -dealloc
        //  did not exist, so the CMFIR object was never freed.
        outbuf.deallocate()
        streamStore.deallocate()
    }

    @objc func userParam() -> Float {
        return userParamStore
    }

    @objc(setUserParam:)
    func setUserParam(_ param: Float) {
        userParamStore = param
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        guard let filter = filter else { return }

        let input = pipe.stream()!            // use client's stream structure
        CMPerformFIR(filter, input.pointee.array, 512, outbuf)

        streamStore.pointee = input.pointee
        streamStore.pointee.array = outbuf
        data = streamStore
        exportData()
    }
}
