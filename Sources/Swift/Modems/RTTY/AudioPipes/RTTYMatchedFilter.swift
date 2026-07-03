//
//  RTTYMatchedFilter.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/8/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of RTTYMatchedFilter.m.
//
//	Extend CMFSKMatchedFilter (importData is identical to the base; the class
//	exists as the RTTY-specific matched-filter type in the pipeline).
//

import Cocoa

@objc(RTTYMatchedFilter)
class RTTYMatchedFilter: CMFSKMatchedFilter {

    override init() {
        super.init()
    }

    //  Data comes here from the mixer as an array with four 512 float subarrays: Mark I, Mark Q, space I and Space Q, sampled at 11025 s/s.
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if !enabled { return }

        //  accumulate data streams into buffers of 2048 samples
        guard let stream = pipe.stream() else { return }
        mfStream.pointee.sourceID = stream.pointee.sourceID
        guard let array = stream.pointee.array else { return }

        let n = MemoryLayout<Float>.size * 512
        memcpy(markIBuffer + Int(mux), array, n)
        memcpy(markQBuffer + Int(mux), array + 512, n)
        memcpy(spaceIBuffer + Int(mux), array + 1024, n)
        memcpy(spaceQBuffer + Int(mux), array + 1536, n)

        mux += 512
        if mux < 2048 { return }

        //  reach here every 2048 samples at 11025 s/s (= 186ms)
        //  match filter and decimate 2048 samples by factor of 8 to 256 output samples
        mux = 0
        //  note that markIFilter, markQFilter, etc are decimation ploters
        CMPerformFIR(markIFilter, markIBuffer, 2048, markIOutput)
        CMPerformFIR(markQFilter, markQBuffer, 2048, markQOutput)
        CMPerformFIR(spaceIFilter, spaceIBuffer, 2048, spaceIOutput)
        CMPerformFIR(spaceQFilter, spaceQBuffer, 2048, spaceQOutput)

        //  form split complex terms for mark and space signals
        //  256 samples every 186ms
        for i in 0..<256 {
            var re = markIOutput[i]
            var im = markQOutput[i]
            demodulated[i] = (re * re + im * im).squareRoot() * 2.5        //  v0.76 added factor of 2.5 for RTTYMonitor
            re = spaceIOutput[i]
            im = spaceQOutput[i]
            demodulated[i + 256] = (re * re + im * im).squareRoot() * 2.5
        }
        exportData()  // exports in 256 sample buffers
    }
}
