//
//  CMFSKMatchedFilter.swift
//  CoreDSP
//
//  RTTY matched filter: takes in the mixer's I/Q split-complex mark and space
//  baseband (4 separate streams of 512 samples each, accumulated into
//  2048-sample blocks) and decimates by 8 down to Fs/8, producing the mark and
//  space envelope ("demodulated") amplitudes that feed the ATC bit-sync/
//  threshold stage. Buffer sizes, tap counts, and the decimate-by-8 setup are
//  preserved exactly from the original.
//
//  Dropped relative to the original: the RTTYMPFilter (multipath) / RTTYSingle
//  Filter (mark-only or space-only) specializations and their supporting
//  createMatchedFilterKernel/dotPrKernelSize helpers -- test/diagnostic
//  variants of this filter not used by the normal RTTY receive chain.
//

import Foundation
import Accelerate

private let EXTN: Int32 = 256

//  n = bit width, m = result matched filter width (including LPF)
private func createExtendedMatchedFilterKernel(_ n: Int32, _ m: Int32, _ cutoff: Float, _ extn: Int32) -> UnsafeMutablePointer<Float> {
    let mInt = Int(m)
    let extn2 = Int(extn) * 2

    //  integrate and dump filter
    let matched = UnsafeMutablePointer<Float>.allocate(capacity: mInt + extn2)
    matched.initialize(repeating: 0, count: mInt + extn2)
    var i = 0
    while i < extn2 { matched[i] = 0.0; i += 1 }
    while i < Int(n) + extn2 { matched[i] = 1.0; i += 1 }
    while i < mInt + extn2 { matched[i] = 0.0; i += 1 }

    //  create a windowed lowpass filter of length EXTN
    let lowpass = CMFIRLowpassFilter(cutoff, Float(CMFs), extn * 2)

    //  convolve matched filter with the lowpass filter
    let kernel = UnsafeMutablePointer<Float>.allocate(capacity: mInt)
    kernel.initialize(repeating: 0, count: mInt)
    vDSP_conv(matched, 1, lowpass!.pointee.kernel!, 1 /*symmetrical lpf*/, kernel, 1, vDSP_Length(m), vDSP_Length(extn * 2))
    var sum: Float = 0.0
    for k in 0..<mInt { sum += kernel[k] }
    sum *= 0.25
    for k in 0..<mInt { kernel[k] /= sum }

    CMDeleteFIR(lowpass)
    matched.deallocate()
    return kernel
}

@inline(__always)
private func mfAllocFloat(_ n: Int) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
    p.initialize(repeating: 0, count: n)
    return p
}

final class CMFSKMatchedFilter: CMTappedPipe {

    var baud: Float = 0
    //  "split complex" demodulated amplitudes for Mark and Space channels (512)
    let demodulated: UnsafeMutablePointer<Float> = mfAllocFloat(512)
    var markIFilter: UnsafeMutablePointer<CMFIR>?
    var markQFilter: UnsafeMutablePointer<CMFIR>?
    var spaceIFilter: UnsafeMutablePointer<CMFIR>?
    var spaceQFilter: UnsafeMutablePointer<CMFIR>?
    let markIOutput: UnsafeMutablePointer<Float> = mfAllocFloat(256)
    let markQOutput: UnsafeMutablePointer<Float> = mfAllocFloat(256)
    let spaceIOutput: UnsafeMutablePointer<Float> = mfAllocFloat(256)
    let spaceQOutput: UnsafeMutablePointer<Float> = mfAllocFloat(256)
    let markIBuffer: UnsafeMutablePointer<Float> = mfAllocFloat(2048)
    let markQBuffer: UnsafeMutablePointer<Float> = mfAllocFloat(2048)
    let spaceIBuffer: UnsafeMutablePointer<Float> = mfAllocFloat(2048)
    let spaceQBuffer: UnsafeMutablePointer<Float> = mfAllocFloat(2048)
    var enabled: Bool = false
    var kernel: UnsafeMutablePointer<Float>?
    var width: Float = 1.0     // width of impulse
    var mux: Int32 = 0

    override init() {
        super.init()
        //  set up CMDataStream
        data.pointee.array = demodulated
        data.pointee.samplingRate = Float(CMFs / 8)
        data.pointee.samples = 256
        data.pointee.components = 1
        data.pointee.channels = 2
        kernel = nil
        enabled = false
        mux = 0
        markIFilter = nil; markQFilter = nil; spaceIFilter = nil; spaceQFilter = nil
        width = 1.0
    }

    convenience init(defaultFilterWithBaudRate baudrate: Float) {
        self.init()
        baud = baudrate
        setDataRate(baud)
    }

    deinit {
        demodulated.deallocate()
        markIOutput.deallocate(); markQOutput.deallocate()
        spaceIOutput.deallocate(); spaceQOutput.deallocate()
        markIBuffer.deallocate(); markQBuffer.deallocate()
        spaceIBuffer.deallocate(); spaceQBuffer.deallocate()
    }

    func setupFilter(_ filter: UnsafeMutablePointer<CMFIR>?, length m: Int32) -> UnsafeMutablePointer<CMFIR>? {
        if let f = filter { CMDeleteFIR(f) }
        return CMFIRDecimate(8, kernel, m)
    }

    //  n = bit width, m = result matched filter width (including LPF)
    func setDataRate(_ rate: Float, lowpass cutoff: Float = 110.0) {
        enabled = false
        baud = rate
        let n = Int32(CMFs / Double(rate) * Double(width))
        var m = n + 2 * EXTN            //  the EXTN takes care of the LPF extension to the matched filter
        //  make m divisible by 16
        m = ((m + 15) / 16) * 16

        let oldkernel = kernel
        kernel = createExtendedMatchedFilterKernel(n, m, cutoff, EXTN)
        if let ok = oldkernel { ok.deallocate() }

        markIFilter = setupFilter(markIFilter, length: m)
        markQFilter = setupFilter(markQFilter, length: m)
        spaceIFilter = setupFilter(spaceIFilter, length: m)
        spaceQFilter = setupFilter(spaceQFilter, length: m)
        enabled = true
        mux = 0
    }

    //  Data comes here from the mixer as an array with four 512 float subarrays:
    //  Mark I, Mark Q, Space I and Space Q, sampled at 11025 s/s.
    override func importData(_ pipe: CMPipe!) {
        if !enabled { return }

        //  accumulate data streams into buffers of 2048 samples
        guard let stream = pipe.stream() else { return }
        data.pointee.sourceID = stream.pointee.sourceID
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
        CMPerformFIR(markIFilter, markIBuffer, 2048, markIOutput)
        CMPerformFIR(markQFilter, markQBuffer, 2048, markQOutput)
        CMPerformFIR(spaceIFilter, spaceIBuffer, 2048, spaceIOutput)
        CMPerformFIR(spaceQFilter, spaceQBuffer, 2048, spaceQOutput)

        //  form split complex terms for mark and space signals
        //  256 samples every 186ms
        for i in 0..<256 {
            var re = markIOutput[i]
            var im = markQOutput[i]
            demodulated[i] = (re * re + im * im).squareRoot() * 2.5        //  factor of 2.5 matches original RTTYMonitor scaling
            re = spaceIOutput[i]
            im = spaceQOutput[i]
            demodulated[i + 256] = (re * re + im * im).squareRoot() * 2.5
        }
        exportData()  // exports in 256 sample buffers
    }
}
