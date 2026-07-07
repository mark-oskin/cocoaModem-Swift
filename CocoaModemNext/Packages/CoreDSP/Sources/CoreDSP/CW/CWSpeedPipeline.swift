//
//  CWSpeedPipeline.swift
//  CoreDSP
//
//  Swift port of the old app's CWSpeedPipeline.swift: builds histograms of
//  keyed / unkeyed interval lengths (using the same AGC/decimate/element
//  front end as CWPipeline, which this subclasses) and estimates the code
//  speed from them.
//
//  Dropped: the `spectrum` CMFFT member from the original -- it was allocated
//  in -init (`FFTSpectrum(12, true)`) but never read anywhere else in the
//  original file (dead code), so it is not transplanted.
//

import Foundation

@inline(__always)
private func cwTrunc(_ x: Float) -> Int {
    return Int(cwFloatToInt32(x))
}

final class CWSpeedPipeline: CWPipeline {

    private var intervalHistory = [CWElementType](repeating: CWElementType(), count: 64)
    private var intervalHistoryIndex: Int32 = 0

    private let keyHistogram = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    private let unkeyHistogram = UnsafeMutablePointer<Float>.allocate(capacity: 1024)

    private var speedEstimate = [Float](repeating: 0, count: 5)

    override init(fromClient matchedFilter: CWMatchedFilter) {
        super.init(fromClient: matchedFilter)

        keyHistogram.initialize(repeating: 0, count: 1024)
        unkeyHistogram.initialize(repeating: 0, count: 1024)
        newClick()
    }

    deinit {
        keyHistogram.deallocate()
        unkeyHistogram.deallocate()
    }

    override func newClick() {
        for i in 0..<64 { intervalHistory[i].valid = false }
        intervalHistoryIndex = 0
        for i in 0..<4 { speedEstimate[i] = 20.0 }
    }

    //  Save element into the interval history; used whenever a speed estimate is needed.
    override func processElement(_ element: inout CWElementType) {
        intervalHistory[Int(intervalHistoryIndex)] = element
        intervalHistoryIndex = (intervalHistoryIndex + 1) & 0x3f
    }

    private func addHistogramElement(_ e: CWElementType, histogram: UnsafeMutablePointer<Float>) {
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
        keyHistogram.update(repeating: 0, count: 1024)
        unkeyHistogram.update(repeating: 0, count: 1024)
        var n: Int32 = 0
        for i in 0..<64 {
            let e = intervalHistory[i]
            if e.valid {
                addHistogramElement(e, histogram: (e.state == 0) ? unkeyHistogram : keyHistogram)
                if e.state == 0 { n += 1 }
            }
        }
        return n
    }

    //  estimate code speed from the intervalHistory
    func estimateMorseTiming() -> CWMorseTiming {
        var result = CWMorseTiming()
        var minV: Float, maxV: Float, sum: Float, v: Float, m: Float, d: Float
        var initial: Float, lower: Float, higher: Float
        var estimate: Float, lowEstimate: Float, highEstimate: Float
        var interelementEstimate: Float, keyValue: Float
        var sorted = [Float](repeating: 0, count: 4)
        var n: Int, lowerLimit: Int, upperLimit: Int

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
            var nmin = 0
            var nmax = 0
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

    override func updateFilter(_ elementLength: Int32) {
        var filterLength = elementLength &* 8
        if filterLength > 1010 { filterLength = 1010 }
        else if filterLength < 200 { filterLength = 200 }

        adjustWaveshapedBoxcarFilter(iDecimateFilter, filterLength)
        adjustWaveshapedBoxcarFilter(qDecimateFilter, filterLength)
    }
}
