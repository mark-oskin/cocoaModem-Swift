//
//  CWSpeedPipeline.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/27/06.
//  Swift port of CWSpeedPipeline.m.
//
//  Subclass of CWPipeline (also Swift).  Builds a histogram of keyed / unkeyed
//  interval lengths and estimates the code speed (MorseTiming) from it.  The
//  shared C types ElementType / MorseTiming live in CWPipelineTypes.h.
//

import Cocoa

//  C float -> int truncation toward zero, guarded (see cwFloatToInt32 in
//  CWPipeline.swift); returned as Int for buffer indexing.
@inline(__always)
private func cwTrunc(_ x: Float) -> Int {
    return Int(cwFloatToInt32(x))
}

@objc(CWSpeedPipeline)
class CWSpeedPipeline: CWPipeline {

    private var spectrum: UnsafeMutablePointer<CMFFT>!

    private var intervalHistory = [ElementType](repeating: ElementType(), count: 64)
    private var intervalHistoryIndex: Int32 = 0

    //  keyHistogram is handed out as a float* by -histogram, so both histograms
    //  live on the heap (a Swift Array's storage pointer would not be stable
    //  across calls, and they are also passed by pointer to addHistogramElement).
    private let keyHistogram = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    private let unkeyHistogram = UnsafeMutablePointer<Float>.allocate(capacity: 1024)

    private var speedEstimate = [Float](repeating: 0, count: 5)

    //  [matchedFilter] -> importArray -> stateChangedTo -> processElement.
    @objc(initFromClient:)
    override init(fromClient matchedFilter: CWMatchedFilter) {
        super.init(fromClient: matchedFilter)

        spectrum = FFTSpectrum(12, true)

        keyHistogram.initialize(repeating: 0, count: 1024)
        unkeyHistogram.initialize(repeating: 0, count: 1024)
        newClick()
    }

    deinit {
        //  MRC dealloc -> deinit; free the malloc'd C buffers (the CMFFT object
        //  is Objective-C / ARC and is released automatically).
        keyHistogram.deallocate()
        unkeyHistogram.deallocate()
    }

    @objc(newClick)
    override func newClick() {
        for i in 0..<64 { intervalHistory[i].valid = false }
        intervalHistoryIndex = 0
        for i in 0..<4 { speedEstimate[i] = 20.0 }
    }

    //  Save element into the interval history.
    //  The interval history is used whenever a speed estimate is needed
    @objc(processElement:)
    override func processElement(_ element: UnsafeMutablePointer<ElementType>?) {
        guard let element = element else { return }
        intervalHistory[Int(intervalHistoryIndex)] = element.pointee
        intervalHistoryIndex = (intervalHistoryIndex + 1) & 0x3f
    }

    private func addHistogramElement(_ e: ElementType, histogram: UnsafeMutablePointer<Float>) {
        if e.state == 0 {
            if e.min > 0.02 { return }
        } else {
            if e.max < 0.98 { return }
        }

        let n = Int(e.interval)
        for i in 0..<16 {
            let k = n - 16 + i
            if k > 0 && k < 1024 { histogram[k] += Float(i) }
        }
        var i = 16
        while i > 0 {
            let k = n + 16 - i
            if k > 0 && k < 1024 { histogram[k] += Float(i) }
            i -= 1
        }
    }

    //  create a histogram of intervalHistory
    private func makeHistograms() -> Int32 {
        //  the original used clearInt() on these float buffers -- zeroing the
        //  words is identical (0.0f is all-zero bits).
        keyHistogram.update(repeating: 0, count: 1024)
        unkeyHistogram.update(repeating: 0, count: 1024)
        var n: Int32 = 0
        for i in 0..<64 {
            let e = intervalHistory[i]
            if e.valid.boolValue {
                addHistogramElement(e, histogram: (e.state == 0) ? unkeyHistogram : keyHistogram)
                if e.state == 0 { n += 1 }
            }
        }
        return n
    }

    //  estimate code speed from the intervalHistory
    @objc(estimateMorseTiming)
    func estimateMorseTiming() -> MorseTiming {
        var result = MorseTiming()
        var minV: Float, maxV: Float, sum: Float, v: Float, m: Float, d: Float
        var initial: Float, lower: Float, higher: Float
        var estimate: Float, lowEstimate: Float, highEstimate: Float
        var interelementEstimate: Float, keyValue: Float
        var sorted = [Float](repeating: 0, count: 4)
        var n: Int, nmin: Int, nmax: Int, lowerLimit: Int, upperLimit: Int

        result.speed = 0
        if makeHistograms() < 8 { return result }   //  not enough data since beginning

        //  check keyed data if it is very noisy at the low end (very rapid changes)
        m = 0.0; d = 0.0
        for i in 0..<16 { m += keyHistogram[i] }
        for i in 16..<250 { d += keyHistogram[i] }
        if m > d { return result }

        //  check unkeyed data if it is very noisy at the low end (very rapid changes)
        m = 0.0; d = 0.0
        for i in 0..<16 { m += unkeyHistogram[i] }
        for i in 16..<250 { d += unkeyHistogram[i] }
        if m > d { return result }

        //  first estimate dit rate
        m = 0.0
        n = 0
        for i in 16..<1024 {
            v = keyHistogram[i]
            if v > m {
                m = v
                n = i
            }
        }
        if n > 340 { n /= 3 }

        //  find mean around the guess
        lowerLimit = n - 16
        upperLimit = n + 16
        m = 0.0
        d = 0.00001
        for i in lowerLimit..<upperLimit {
            v = keyHistogram[i]
            m += v * Float(i)
            d += v
        }
        estimate = m / d
        let initialEstimate = estimate
        n = cwTrunc(initialEstimate + 0.5)
        if n < 10 { return result }

        initial = keyHistogram[n] + 0.00001

        //  look for peak around n/3
        lowerLimit = n / 3 - 8
        upperLimit = n / 3 + 8
        if lowerLimit < 0 { lowerLimit = 0 }
        m = 0.0
        d = 0.00001
        for i in lowerLimit..<upperLimit {
            v = keyHistogram[i]
            m += v * Float(i)
            d += v
        }
        lowEstimate = m / d
        if lowEstimate < Float(lowerLimit) || lowEstimate > Float(upperLimit) { lowEstimate = Float(n / 3) }
        lower = keyHistogram[cwTrunc(lowEstimate + 0.5)] / initial

        //  now look for peak at between 2.5 and 3.8 x of n
        lowerLimit = cwTrunc(Float(n) * 2.5)
        upperLimit = cwTrunc(Float(n) * 3.5)
        if upperLimit > 1024 { upperLimit = 1024 }
        m = 0.0
        d = 0.00001
        for i in lowerLimit..<upperLimit {
            v = keyHistogram[i]
            m += v * Float(i)
            d += v
        }
        highEstimate = m / d + 0.5
        if highEstimate < Float(lowerLimit) || highEstimate > Float(upperLimit) { highEstimate = Float(n * 3) }

        higher = keyHistogram[cwTrunc(highEstimate + 0.5)] / initial

        if (lower + higher) > 0.1 {

            if higher < 0.1 && lower > higher * 2 && n > 45 { estimate = lowEstimate }
            //  check if energy is in the high frequencies (small interval numbers), if so, reject as noise
            if estimate < 8 { return result }

            n = cwTrunc(estimate + 0.5)
            keyValue = keyHistogram[n]

            if keyValue < 0.01 { return result }

            //  now check the interelement (unkeyed) spacings
            lowerLimit = n - 16
            upperLimit = n + 16
            m = 0.0
            d = 0.00001
            for i in lowerLimit..<upperLimit {
                v = unkeyHistogram[i]
                m += v * Float(i)
                d += v
            }
            interelementEstimate = m / d
            n = cwTrunc(interelementEstimate)
            v = unkeyHistogram[n] / keyValue
            if v < 0.18 { return result }

            v = 18.0 * 92.0 * 2.0 / (estimate + interelementEstimate)
            if v > 100 { return result }

            //  look for three speed estimates that are close to one another
            for i in 0..<4 { speedEstimate[i] = speedEstimate[i + 1] }
            speedEstimate[4] = v
            //  remove the smallest and largest
            minV = speedEstimate[0]
            maxV = speedEstimate[0]
            nmin = 0
            nmax = 0
            for i in 1..<5 {
                if speedEstimate[i] > maxV {
                    maxV = speedEstimate[i]
                    nmax = i
                } else if speedEstimate[i] < minV {
                    minV = speedEstimate[i]
                    nmin = i
                }
            }
            n = 0
            for i in 0..<5 {
                if i != nmax && i != nmin {
                    sorted[n] = speedEstimate[i]
                    n += 1
                }
            }

            sum = 0.0
            for i in 0..<3 { sum += sorted[i] }
            sum = sum * 0.333
            for i in 0..<3 {
                if abs(sorted[i] - sum) > 1.0 {
                    return result
                }
            }
            result.speed = sum
            result.dit = estimate
            result.interElement = interelementEstimate
            result.interSymbol = 3 * result.interElement
            result.dash = 3 * result.dit

            return result
        }
        return result
    }

    @objc(histogram)
    func histogram() -> UnsafeMutablePointer<Float>? {
        return keyHistogram
    }

    @objc(updateFilter:)
    override func updateFilter(_ elementLength: Int32) {
        //  adjust matched filter
        //  max matched filter is for approx 12 wpm
        //  matched filter at 11025, while element is defined at 11025/8 sampling rate
        var filterLength = elementLength &* 8
        if filterLength > 1010 { filterLength = 1010 }
        else if filterLength < 200 { filterLength = 200 }

        adjustWaveshapedBoxcarFilter(iDecimateFilter, filterLength)
        adjustWaveshapedBoxcarFilter(qDecimateFilter, filterLength)
    }
}
