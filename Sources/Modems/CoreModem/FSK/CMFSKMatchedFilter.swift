//
//  CMFSKMatchedFilter.swift
//  CoreModem
//
//  Created by Kok Chen on 10/25/05
//	(ported from cocoaModem, original file dated Sun Jun 13 2004)
//  Swift port of CMFSKMatchedFilter.m.
//
//  RTTY Matched filter takes in I and Q split complex channels of data (4
//  separate streams of 512 samples each); output is decimated by 8 to Fs/8.
//
//  Port notes:
//   * The C object embedded its sample buffers as fixed C arrays (freed with the
//     object).  Here they are heap UnsafeMutablePointers freed in deinit -- the
//     exact Swift equivalent of that inline object storage.  The CMFIR filters
//     and the kernel are, as in the original (which had NO -dealloc), only freed
//     where the original freed them (setupFilter: / setDataRate:), not in deinit.
//   * `mfStream` is a heap CMDataStream so the base `data` pointer can alias it
//     exactly as the C did (data = &mfStream ; mfStream.array = &demodulated[0]).
//   * Buffer sizes, tap counts and the decimate-by-8 setup are preserved exactly.
//

import Foundation
import Accelerate

private let CMFs: Double = 11025.0

@inline(__always)
private func mfAllocFloat(_ n: Int) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
    p.initialize(repeating: 0, count: n)
    return p
}

//  find next larger integer that matches criteria for vDSP dot products
func dotPrKernelSize(_ n0: Int32) -> Int32 {
    var n = n0
    if n < 32 { n = 32 }
    return ((n + 1) / 2) * 2
}

//  n = bit width, m = result matched filter width (including LPF)
func createExtendedMatchedFilterKernel(_ n: Int32, _ m: Int32, _ cutoff: Float, _ extn: Int32) -> UnsafeMutablePointer<Float> {
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

//  n = bit width, m = result matched filter width (including LPF)
func createMatchedFilterKernel(_ n: Int32, _ m: Int32) -> UnsafeMutablePointer<Float> {
    return createExtendedMatchedFilterKernel(n, m, 110.0, 512)
}

private let EXTN: Int32 = 256

@objc(CMFSKMatchedFilter)
class CMFSKMatchedFilter: CMTappedPipe {

    internal var baud: Float = 0
    //  "split complex" demodulated amplitudes for Mark and Space channels (512)
    internal let demodulated: UnsafeMutablePointer<Float> = mfAllocFloat(512)
    internal var markIFilter: UnsafeMutablePointer<CMFIR>?
    internal var markQFilter: UnsafeMutablePointer<CMFIR>?
    internal var spaceIFilter: UnsafeMutablePointer<CMFIR>?
    internal var spaceQFilter: UnsafeMutablePointer<CMFIR>?
    internal let markIOutput: UnsafeMutablePointer<Float> = mfAllocFloat(256)
    internal let markQOutput: UnsafeMutablePointer<Float> = mfAllocFloat(256)
    internal let spaceIOutput: UnsafeMutablePointer<Float> = mfAllocFloat(256)
    internal let spaceQOutput: UnsafeMutablePointer<Float> = mfAllocFloat(256)
    internal let markIBuffer: UnsafeMutablePointer<Float> = mfAllocFloat(2048)
    internal let markQBuffer: UnsafeMutablePointer<Float> = mfAllocFloat(2048)
    internal let spaceIBuffer: UnsafeMutablePointer<Float> = mfAllocFloat(2048)
    internal let spaceQBuffer: UnsafeMutablePointer<Float> = mfAllocFloat(2048)
    internal let mfStream: UnsafeMutablePointer<CMDataStream> = {
        let p = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        p.initialize(to: CMDataStream())
        return p
    }()
    internal var enabled: Bool = false
    internal var kernel: UnsafeMutablePointer<Float>?
    internal var width: Float = 1.0     // width of impulse
    internal var mux: Int32 = 0

    override init() {
        super.init()
        //  set up CMDataStream
        data = mfStream
        mfStream.pointee.array = demodulated
        mfStream.pointee.samplingRate = Float(CMFs / 8)
        mfStream.pointee.samples = 256
        mfStream.pointee.components = 1
        mfStream.pointee.channels = 2
        kernel = nil
        enabled = false
        mux = 0
        markIFilter = nil; markQFilter = nil; spaceIFilter = nil; spaceQFilter = nil
        width = 1.0
    }

    @objc(initDefaultFilterWithBaudRate:)
    convenience init(defaultFilterWithBaudRate baudrate: Float) {
        self.init()
        baud = baudrate
        setDataRate(baud)
    }

    deinit {
        //  free the inline-storage-equivalent buffers (the C freed these with the
        //  object).  The FIRs and kernel are not freed here -- the original had no
        //  -dealloc.
        demodulated.deallocate()
        markIOutput.deallocate(); markQOutput.deallocate()
        spaceIOutput.deallocate(); spaceQOutput.deallocate()
        markIBuffer.deallocate(); markQBuffer.deallocate()
        spaceIBuffer.deallocate(); spaceQBuffer.deallocate()
        mfStream.deallocate()
    }

    func setupFilter(_ filter: UnsafeMutablePointer<CMFIR>?, length m: Int32) -> UnsafeMutablePointer<CMFIR>? {
        if let f = filter { CMDeleteFIR(f) }
        return CMFIRDecimate(8, kernel, m)
    }

    //  n = bit width, m = result matched filter width (including LPF)
    @objc(setDataRate:lowpass:)
    func setDataRate(_ rate: Float, lowpass cutoff: Float) {
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

    @objc(setDataRate:)
    func setDataRate(_ rate: Float) {
        setDataRate(rate, lowpass: 110.0)
    }

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
