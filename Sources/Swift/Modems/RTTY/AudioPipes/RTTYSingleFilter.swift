//
//  RTTYSingleFilter.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon Jun 21 2004.
//  Swift port of RTTYSingleFilter.m.
//
//  mark-only and space-only matched filters.
//

import Cocoa

@objc(RTTYSingleFilter)
class RTTYSingleFilter: RTTYMatchedFilter {

    internal var tone: Int32 = 0

    @objc(initTone:baud:)
    convenience init(tone channel: Int32, baud baudrate: Float) {
        self.init()
        tone = channel
        baud = baudrate
        setDataRate(baud)
        for i in 0..<512 { demodulated[i] = 0.0 }
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if !enabled { return }

        //  accumulate data streams into buffers of 2048 samples
        guard let stream = pipe.stream() else { return }
        mfStream.pointee.sourceID = stream.pointee.sourceID
        guard let array = stream.pointee.array else { return }
        let n = MemoryLayout<Float>.size * 512
        if tone == 0 {
            memcpy(markIBuffer + Int(mux), array, n)
            memcpy(markQBuffer + Int(mux), array + 512, n)
        } else {
            memcpy(spaceIBuffer + Int(mux), array + 1024, n)
            memcpy(spaceQBuffer + Int(mux), array + 1536, n)
        }
        mux += 512
        if mux < 2048 { return }

        //  reach here every 2048 samples at 11025 s/s (= 186ms)
        //  match filter and decimate 2048 samples by factor of 8 to 256 output samples
        mux = 0
        if tone == 0 {
            CMPerformFIR(markIFilter, markIBuffer, 2048, markIOutput)
            CMPerformFIR(markQFilter, markQBuffer, 2048, markQOutput)
        } else {
            CMPerformFIR(spaceIFilter, spaceIBuffer, 2048, spaceIOutput)
            CMPerformFIR(spaceQFilter, spaceQBuffer, 2048, spaceQOutput)
        }

        //  form split complex terms for mark and space signals
        //  256 samples every 186ms
        if tone == 0 {
            for i in 0..<256 {
                let re = markIOutput[i]
                let im = markQOutput[i]
                demodulated[i] = (re * re + im * im).squareRoot()
            }
        } else {
            for i in 0..<256 {
                let re = spaceIOutput[i]
                let im = spaceQOutput[i]
                demodulated[i + 256] = (re * re + im * im).squareRoot()
            }
        }
        exportData()  // exports in 256 sample buffers
    }
}
