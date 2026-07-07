//
//  ASCIIMatchedFilter.swift
//  CoreDSP
//
//  Integrate-and-dump matched filter for the mark/space baseband channels,
//  decimating 11025 Hz I/Q data down to Fs/8 (~1378 s/s) amplitude samples for
//  the bit synchronizer (ASCIIATC).  Faithful transplant of
//  CMFSKMatchedFilter's algorithm
//  (Sources/Swift/Modems/CoreModem/FSK/CMFSKMatchedFilter.swift) -- RTTY's own
//  RTTYMatchedFilter subclass duplicated -importData verbatim with no changes,
//  so this single class covers both.
//

import Foundation
import Accelerate

private let asciiMatchedFilterExtension: Int32 = 256

@inline(__always)
private func asciiAllocFloat(_ n: Int) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
    p.initialize(repeating: 0, count: n)
    return p
}

//  n = bit width (samples), m = result matched-filter width (including LPF
//  extension).  Builds an integrate-and-dump kernel convolved with a windowed
//  lowpass, normalized to unit DC gain.
private func asciiMatchedFilterKernel(_ n: Int32, _ m: Int32, _ cutoff: Float, _ extn: Int32) -> UnsafeMutablePointer<Float> {
    let mInt = Int(m)
    let extn2 = Int(extn) * 2

    let matched = UnsafeMutablePointer<Float>.allocate(capacity: mInt + extn2)
    matched.initialize(repeating: 0, count: mInt + extn2)
    var i = 0
    while i < extn2 { matched[i] = 0.0; i += 1 }
    while i < Int(n) + extn2 { matched[i] = 1.0; i += 1 }
    while i < mInt + extn2 { matched[i] = 0.0; i += 1 }

    let lowpass = CMFIRLowpassFilter(cutoff, Float(kCMFs), extn * 2)

    let kernel = UnsafeMutablePointer<Float>.allocate(capacity: mInt)
    kernel.initialize(repeating: 0, count: mInt)
    vDSP_conv(matched, 1, lowpass!.pointee.kernel!, 1, kernel, 1, vDSP_Length(m), vDSP_Length(extn * 2))
    var sum: Float = 0.0
    for k in 0..<mInt { sum += kernel[k] }
    sum *= 0.25
    for k in 0..<mInt { kernel[k] /= sum }

    CMDeleteFIR(lowpass)
    matched.deallocate()
    return kernel
}

final class ASCIIMatchedFilter: CMTappedPipe {

    private var baud: Float = 0
    //  demodulated mark/space amplitudes (256 mark, 256 space), decimated to Fs/8
    private let demodulated = asciiAllocFloat(512)
    private var markIFilter: UnsafeMutablePointer<CMFIR>?
    private var markQFilter: UnsafeMutablePointer<CMFIR>?
    private var spaceIFilter: UnsafeMutablePointer<CMFIR>?
    private var spaceQFilter: UnsafeMutablePointer<CMFIR>?
    private let markIOutput = asciiAllocFloat(256)
    private let markQOutput = asciiAllocFloat(256)
    private let spaceIOutput = asciiAllocFloat(256)
    private let spaceQOutput = asciiAllocFloat(256)
    private let markIBuffer = asciiAllocFloat(2048)
    private let markQBuffer = asciiAllocFloat(2048)
    private let spaceIBuffer = asciiAllocFloat(2048)
    private let spaceQBuffer = asciiAllocFloat(2048)
    private let mfStream: UnsafeMutablePointer<CMDataStream> = {
        let p = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        p.initialize(to: CMDataStream())
        return p
    }()
    private var enabled = false
    private var kernel: UnsafeMutablePointer<Float>?
    private var mux: Int32 = 0

    override init() {
        super.init()
        data = mfStream
        mfStream.pointee.array = demodulated
        mfStream.pointee.samplingRate = Float(kCMFs / 8)
        mfStream.pointee.samples = 256
        mfStream.pointee.components = 1
        mfStream.pointee.channels = 2
    }

    convenience init(baudRate: Float) {
        self.init()
        setDataRate(baudRate)
    }

    deinit {
        demodulated.deallocate()
        markIOutput.deallocate(); markQOutput.deallocate()
        spaceIOutput.deallocate(); spaceQOutput.deallocate()
        markIBuffer.deallocate(); markQBuffer.deallocate()
        spaceIBuffer.deallocate(); spaceQBuffer.deallocate()
        mfStream.deallocate()
    }

    private func setupFilter(_ filter: UnsafeMutablePointer<CMFIR>?, length m: Int32) -> UnsafeMutablePointer<CMFIR>? {
        if let f = filter { CMDeleteFIR(f) }
        return CMFIRDecimate(8, kernel, m)
    }

    func setDataRate(_ rate: Float, lowpass cutoff: Float = 110.0) {
        enabled = false
        baud = rate
        let n = Int32(kCMFs / Double(rate))
        var m = n + 2 * asciiMatchedFilterExtension
        m = ((m + 15) / 16) * 16     //  make m divisible by 16

        let oldkernel = kernel
        kernel = asciiMatchedFilterKernel(n, m, cutoff, asciiMatchedFilterExtension)
        if let ok = oldkernel { ok.deallocate() }

        markIFilter = setupFilter(markIFilter, length: m)
        markQFilter = setupFilter(markQFilter, length: m)
        spaceIFilter = setupFilter(spaceIFilter, length: m)
        spaceQFilter = setupFilter(spaceQFilter, length: m)
        enabled = true
        mux = 0
    }

    //  data comes here from the mixer as four 512-sample subarrays: Mark I,
    //  Mark Q, Space I, Space Q, sampled at 11025 s/s.
    override func importData(_ pipe: CMPipe!) {
        if !enabled { return }
        guard let stream = pipe.stream(), let array = stream.pointee.array else { return }
        mfStream.pointee.sourceID = stream.pointee.sourceID

        let n = MemoryLayout<Float>.size * 512
        memcpy(markIBuffer + Int(mux), array, n)
        memcpy(markQBuffer + Int(mux), array + 512, n)
        memcpy(spaceIBuffer + Int(mux), array + 1024, n)
        memcpy(spaceQBuffer + Int(mux), array + 1536, n)
        mux += 512
        if mux < 2048 { return }

        //  reach here every 2048 samples at 11025 s/s (~186 ms)
        mux = 0
        CMPerformFIR(markIFilter, markIBuffer, 2048, markIOutput)
        CMPerformFIR(markQFilter, markQBuffer, 2048, markQOutput)
        CMPerformFIR(spaceIFilter, spaceIBuffer, 2048, spaceIOutput)
        CMPerformFIR(spaceQFilter, spaceQBuffer, 2048, spaceQOutput)

        for i in 0..<256 {
            var re = markIOutput[i]; var im = markQOutput[i]
            demodulated[i] = (re * re + im * im).squareRoot() * 2.5
            re = spaceIOutput[i]; im = spaceQOutput[i]
            demodulated[i + 256] = (re * re + im * im).squareRoot() * 2.5
        }
        exportData()   // exports in 256-sample buffers, at Fs/8
    }
}
