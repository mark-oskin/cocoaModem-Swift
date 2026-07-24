// Swift port of CMFIR.c
//
//  CMFIR.c / CMFIR.h
//  Filter (CoreModem)
//
//  Created by Kok Chen on 10/24/05
//  (ported from cocoaModem created on Mon May 24 2004)
//
//  Faithful reimplementation of the core FIR filter kernel.
//  Uses Accelerate's vDSP directly with the same arguments/strides/lengths as
//  the C.  Window functions (CMSinc, CMBlackmanWindow, ...) come from
//  CMDSPWindow (same module).  Numerics kept literal (kernel reversal
//  kernel[n-1-i], float vs double at every step, delay-line indexing).
//

import Foundation
import Accelerate

//  NOTE: filter sizes should be divisible by 4 to use Altivec!!!
//
//  NOTE:  don't use dotpr() in vDSP
//         It seems to sporadically returning NAN when run in development mode in xCode 1.5.
//         Instead, use vDSP_conv() with a result length of 1.

//  This file OWNS the CMFIR struct and CMFIRStyle enum.
enum CMFIRStyle: Int32 { case kCMInterpolate = 0, kCMFilter, kCMDecimate, kCMDelayLine }

struct CMFIR {
    var kernel: UnsafeMutablePointer<Float>!
    var delayLine: UnsafeMutablePointer<Float>!
    var activeTaps: Int32
    var stride: Int32
    var delaylineHead: Int32
    var style: CMFIRStyle
    var fsampling: Float        // sampling frequency
}

//  create a vDSP convolution structure for an FIR filter
//  Filter array kernel should have activeTaps entries
func CMFIRFilter(_ kernel: UnsafeMutablePointer<Float>!, _ activeTaps: Int32) -> UnsafeMutablePointer<CMFIR>! {
    let fir = UnsafeMutablePointer<CMFIR>.allocate(capacity: 1)
    fir.pointee.stride = 1
    fir.pointee.activeTaps = activeTaps
    fir.pointee.style = .kCMFilter
    fir.pointee.delaylineHead = 0

    //  delay line to provide FIR overlap
    fir.pointee.delayLine = UnsafeMutablePointer<Float>.allocate(capacity: Int(activeTaps * 2))
    fir.pointee.delayLine.initialize(repeating: 0, count: Int(activeTaps * 2))

    let n = activeTaps
    //  reverse kernel for convolution
    fir.pointee.kernel = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    var i: Int32 = 0
    while i < n { fir.pointee.kernel[Int(n - 1 - i)] = kernel[Int(i)]; i += 1 }
    return fir
}

// update a structure that already exists
func CMUpdateFIRFilter(_ fir: UnsafeMutablePointer<CMFIR>!, _ kernel: UnsafeMutablePointer<Float>!, _ activeTaps: Int32) {
    fir.pointee.stride = 1
    fir.pointee.activeTaps = activeTaps
    fir.pointee.style = .kCMFilter
    fir.pointee.delaylineHead = 0

    let n = activeTaps
    var i: Int32 = 0
    while i < n { fir.pointee.kernel[Int(n - 1 - i)] = kernel[Int(i)]; i += 1 }
}

//  create a vDSP convolution structure for interpolation
//  Filter array kernel should have activeTaps*factor entries
func CMFIRInterpolate(_ factor: Int32, _ kernel: UnsafeMutablePointer<Float>!, _ activeTaps: Int32) -> UnsafeMutablePointer<CMFIR>! {
    let fir = UnsafeMutablePointer<CMFIR>.allocate(capacity: 1)
    fir.pointee.stride = factor
    fir.pointee.activeTaps = activeTaps
    fir.pointee.style = .kCMInterpolate
    fir.pointee.delaylineHead = 0

    //  delay line to provide FIR overlap
    fir.pointee.delayLine = UnsafeMutablePointer<Float>.allocate(capacity: Int(activeTaps * 2))
    fir.pointee.delayLine.initialize(repeating: 0, count: Int(activeTaps * 2))

    let n = factor * activeTaps
    //  reverse kernel for convolution
    fir.pointee.kernel = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    var sum: Float = 0.0
    var i: Int32 = 0
    while i < n { sum += kernel[Int(i)]; i += 1 }
    let gain: Float = Float(factor) / sum

    i = 0
    while i < n { fir.pointee.kernel[Int(n - 1 - i)] = kernel[Int(i)] * gain; i += 1 }
    return fir
}

//  create a vDSP convolution structure for decimation
//  Filter array kernel should have activeTaps entries
func CMFIRDecimate(_ factor: Int32, _ kernel: UnsafeMutablePointer<Float>!, _ activeTaps: Int32) -> UnsafeMutablePointer<CMFIR>! {
    let fir = UnsafeMutablePointer<CMFIR>.allocate(capacity: 1)
    fir.pointee.stride = factor
    fir.pointee.activeTaps = activeTaps
    fir.pointee.style = .kCMDecimate
    fir.pointee.delaylineHead = 0

    //  delay line to provide FIR overlap
    fir.pointee.delayLine = UnsafeMutablePointer<Float>.allocate(capacity: Int(activeTaps * 3))
    fir.pointee.delayLine.initialize(repeating: 0, count: Int(activeTaps * 3))

    let n = activeTaps
    //  reverse kernel for convolution
    fir.pointee.kernel = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    var i: Int32 = 0
    while i < n { fir.pointee.kernel[Int(n - 1 - i)] = kernel[Int(i)]; i += 1 }
    return fir
}

//  create a vDSP convolution structure for simple low pass filtering
//  Filter array kernel should have activeTaps entries
func CMFIRLowpassFilter(_ cutoff: Float, _ fsampling: Float, _ activeTaps: Int32) -> UnsafeMutablePointer<CMFIR>! {
    let fir = UnsafeMutablePointer<CMFIR>.allocate(capacity: 1)
    fir.pointee.stride = 1
    fir.pointee.activeTaps = activeTaps
    fir.pointee.style = .kCMFilter
    fir.pointee.delaylineHead = 0
    fir.pointee.fsampling = fsampling

    //  delay line to provide FIR overlap
    fir.pointee.delayLine = UnsafeMutablePointer<Float>.allocate(capacity: Int(activeTaps * 2))
    fir.pointee.delayLine.initialize(repeating: 0, count: Int(activeTaps * 2))

    fir.pointee.kernel = lowpassKernel(cutoff, fsampling, activeTaps, 1.0)
    return fir
}

func CMUpdateFIRLowpassFilter(_ fir: UnsafeMutablePointer<CMFIR>!, _ cutoff: Float) {
    updateLowpassKernel(fir.pointee.kernel, cutoff, fir.pointee.fsampling, fir.pointee.activeTaps, 1.0)
}

//  create a vDSP convolution structure for simple band pass filtering
//  Filter array kernel should have activeTaps entries
func CMFIRBandpassFilter(_ low: Float, _ high: Float, _ fsampling: Float, _ activeTaps: Int32) -> UnsafeMutablePointer<CMFIR>! {
    let fir = UnsafeMutablePointer<CMFIR>.allocate(capacity: 1)
    fir.pointee.stride = 1
    fir.pointee.activeTaps = activeTaps
    fir.pointee.style = .kCMFilter
    fir.pointee.delaylineHead = 0
    fir.pointee.fsampling = fsampling

    //  delay line to provide FIR overlap
    fir.pointee.delayLine = UnsafeMutablePointer<Float>.allocate(capacity: Int(activeTaps * 2))
    fir.pointee.delayLine.initialize(repeating: 0, count: Int(activeTaps * 2))

    fir.pointee.kernel = bandpassKernel(low, high, fsampling, activeTaps)
    return fir
}

func CMUpdateFIRBandpassFilter(_ fir: UnsafeMutablePointer<CMFIR>!, _ low: Float, _ high: Float) {
    updateBandpassKernel(fir.pointee.kernel, low, high, fir.pointee.fsampling, fir.pointee.activeTaps)
}

func CMFIRCombFilter(_ freq: Float, _ fsampling: Float, _ activeTaps: Int32, _ phase: Float) -> UnsafeMutablePointer<CMFIR>! {
    let fir = UnsafeMutablePointer<CMFIR>.allocate(capacity: 1)
    fir.pointee.stride = 1
    fir.pointee.activeTaps = activeTaps
    fir.pointee.style = .kCMFilter
    fir.pointee.delaylineHead = 0
    fir.pointee.fsampling = fsampling

    //  delay line to provide FIR overlap
    fir.pointee.delayLine = UnsafeMutablePointer<Float>.allocate(capacity: Int(activeTaps * 2))
    fir.pointee.delayLine.initialize(repeating: 0, count: Int(activeTaps * 2))

    fir.pointee.kernel = combKernel(freq, fsampling, activeTaps, phase)
    return fir
}

func CMFIRDecimateWithCutoff(_ factor: Int32, _ cutoff: Float, _ fsampling: Float, _ activeTaps: Int32) -> UnsafeMutablePointer<CMFIR>! {
    let fir = UnsafeMutablePointer<CMFIR>.allocate(capacity: 1)
    fir.pointee.stride = factor
    fir.pointee.activeTaps = activeTaps
    fir.pointee.style = .kCMDecimate
    fir.pointee.delaylineHead = 0
    fir.pointee.fsampling = fsampling

    //  delay line to provide FIR overlap
    fir.pointee.delayLine = UnsafeMutablePointer<Float>.allocate(capacity: Int(activeTaps * 3))
    fir.pointee.delayLine.initialize(repeating: 0, count: Int(activeTaps * 3))

    fir.pointee.kernel = lowpassKernel(cutoff, fsampling, activeTaps, Float(factor))

    //  scale to unity gain
    let r: Float = 1.0 / Float(factor)
    var i: Int32 = 0
    while i < activeTaps { fir.pointee.kernel[Int(i)] *= r; i += 1 }

    return fir
}

//  create a vDSP convolution structure for an FIR filter
//  Filter array kernel should have activeTaps entries
func CMDelayLine(_ delayUnits: Int32) -> UnsafeMutablePointer<CMFIR>! {
    let fir = UnsafeMutablePointer<CMFIR>.allocate(capacity: 1)
    fir.pointee.stride = 1
    fir.pointee.activeTaps = delayUnits
    fir.pointee.style = .kCMDelayLine
    fir.pointee.delaylineHead = 0
    fir.pointee.fsampling = 0.0

    //  delay line to provide FIR overlap
    fir.pointee.delayLine = UnsafeMutablePointer<Float>.allocate(capacity: Int(fir.pointee.activeTaps * 2))
    fir.pointee.delayLine.initialize(repeating: 0, count: Int(fir.pointee.activeTaps * 2))

    fir.pointee.kernel = nil            // no kernel
    return fir
}

//  return a kernel for a lowpass filter
//  use unmodified Blackman window
private func lowpassKernel(_ cutoff: Float, _ fs: Float, _ activeTaps: Int32, _ decimationRatio: Float) -> UnsafeMutablePointer<Float> {
    let n = activeTaps
    var sum: Float = 0
    var w: Float = Float(activeTaps) * cutoff / fs        //  bandwidth of sinc

    let kernel = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    kernel.initialize(repeating: 0, count: Int(n))
    var i: Int32 = 0
    while i < n {
        let baseband: Double = CMBlackmanWindow(i, n) * CMSinc(i, n, Double(w))
        sum = Float(Double(sum) + baseband)
        kernel[Int(i)] = Float(baseband)
        i += 1
    }
    w = decimationRatio / sum
    i = 0
    while i < n { kernel[Int(i)] = kernel[Int(i)] * w; i += 1 }

    return kernel
}

private func updateLowpassKernel(_ kernel: UnsafeMutablePointer<Float>!, _ cutoff: Float, _ fs: Float, _ activeTaps: Int32, _ decimationRatio: Float) {
    let n = activeTaps
    var sum: Float = 0
    var w: Float = Float(activeTaps) * cutoff / fs        //  bandwidth of sinc

    var i: Int32 = 0
    while i < n {
        let baseband: Double = CMBlackmanWindow(i, n) * CMSinc(i, n, Double(w))
        sum = Float(Double(sum) + baseband)
        kernel[Int(i)] = Float(baseband * 0.01)        //  attenuate to avoid loud transcients
        i += 1
    }
    w = decimationRatio / sum * 100
    i = 0
    while i < n { kernel[Int(i)] = kernel[Int(i)] * w; i += 1 }
}

//  return a kernel for a bandpass filter
//  use modified Blackman window to reduce DC offset
private func bandpassKernel(_ low: Float, _ high: Float, _ fs: Float, _ activeTaps: Int32) -> UnsafeMutablePointer<Float> {
    let n = activeTaps
    let center: Float = Float(Double(high + low) * 0.5)
    let f: Float = Float(0.5 * Double(center) * Double(n) / Double(fs))
    let w: Float = Float(0.5 * fabs(Double(high - low)) * Double(n) / Double(fs))        //  bandwidth of sinc

    let kernel = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    kernel.initialize(repeating: 0, count: Int(n))

    var sum: Double = 0
    let t: Float = Float(n / 2)
    var i: Int32 = 0
    while i < n {
        let x: Float
        if (n & 1) == 0 { x = Float((Double(i) + 0.5 - Double(t)) / Double(t)) } else { x = (Float(i) - t) / t }
        let baseband: Double = CMModifiedBlackmanWindow(i, n) * CMSinc(i, n, Double(w))
        let m: Double = sin(2.0 * 3.14159265358979 * Double(f) * Double(x))
        let kv = Float(baseband * m)
        kernel[Int(i)] = kv
        sum += Double(kv) * m
        i += 1
    }
    let w2: Float = Float(1 / sum)
    i = 0
    while i < n { kernel[Int(i)] *= w2; i += 1 }

    return kernel
}

private func updateBandpassKernel(_ kernel: UnsafeMutablePointer<Float>!, _ low: Float, _ high: Float, _ fs: Float, _ activeTaps: Int32) {
    let n = activeTaps
    let center: Float = Float(Double(high + low) * 0.5)
    let f: Float = Float(0.5 * Double(center) * Double(n) / Double(fs))
    let w: Float = Float(0.5 * fabs(Double(high - low)) * Double(n) / Double(fs))        //  bandwidth of sinc

    var sum: Double = 0
    let t: Float = Float(n / 2)
    var i: Int32 = 0
    while i < n {
        let x: Float
        if (n & 1) == 0 { x = Float((Double(i) + 0.5 - Double(t)) / Double(t)) } else { x = (Float(i) - t) / t }
        let baseband: Double = CMModifiedBlackmanWindow(i, n) * CMSinc(i, n, Double(w))
        let m: Double = sin(2.0 * 3.14159265358979 * Double(f) * Double(x))
        let kv = Float(baseband * m * 0.01)        //  attenuate by 100 to avoid loud transcients
        kernel[Int(i)] = kv
        sum += Double(kv) * m
        i += 1
    }
    let w2: Float = Float(1.0 / sum)
    i = 0
    while i < n { kernel[Int(i)] *= w2; i += 1 }
}

private var combCache = [Float](repeating: 0, count: 2048)
private var fCached: Float = 0.0
private var nCached: Int32 = 0

private func combKernel(_ center: Float, _ fs: Float, _ activeTaps: Int32, _ phase: Float) -> UnsafeMutablePointer<Float> {
    let n = activeTaps
    let f: Float = Float(0.5 * Double(center) * Double(n) / Double(fs))

    if n == nCached && f == fCached {
        //  simply return cached array
        let byteCount = MemoryLayout<Float>.size * Int(n)
        let kernel = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
        combCache.withUnsafeBytes { _ = memcpy(kernel, $0.baseAddress, byteCount) }
        return kernel
    }

    let kernel = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    kernel.initialize(repeating: 0, count: Int(n))
    var sum: Double = 0
    let t: Float = Float(n / 2)
    var i: Int32 = 0
    while i < n {
        let x: Float
        if (n & 1) == 0 { x = Float((Double(i) + 0.5 - Double(t)) / Double(t)) } else { x = (Float(i) - t) / t }
        let baseband: Double = pow(CMHanningWindow(i, n), 0.25)                        // 0.96c
        let m: Double = sin(2.0 * 3.14159265358979 * Double(f) * Double(x) + Double(phase))
        let kv = Float(baseband * m)
        kernel[Int(i)] = kv
        sum += Double(kv) * m
        i += 1
    }
    let mm: Double = 1 / sum
    i = 0
    while i < n { kernel[Int(i)] = Float(Double(kernel[Int(i)]) * mm); i += 1 }

    if n <= 2048 {
        combCache.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, kernel, MemoryLayout<Float>.size * Int(n)) }
        fCached = f
        nCached = n
    }

    return kernel
}

//  apply FIR filter for array and length of array
//  outArray size should be same size as inLength
private func performFilter(_ fir: UnsafeMutablePointer<CMFIR>!, _ inArray: UnsafeMutablePointer<Float>!, _ inLength: Int32, _ outArray: UnsafeMutablePointer<Float>!) {
    let n = fir.pointee.activeTaps

    if inLength > n {
        //  provide FIR overlap by copying an extra set of activeTaps into the delay line
        memcpy(fir.pointee.delayLine + Int(n), inArray, MemoryLayout<Float>.size * Int(n))
        //  filter the data in the delay line (length = taps)
        vDSP_conv(fir.pointee.delayLine, 1, fir.pointee.kernel, 1, outArray, 1, vDSP_Length(n), vDSP_Length(n))
        //  filter rest of the data
        vDSP_conv(inArray, 1, fir.pointee.kernel, 1, outArray + Int(n), 1, vDSP_Length(inLength - n), vDSP_Length(n))
        //  copy tail of data into the front of the delay line
        memcpy(fir.pointee.delayLine, inArray + Int(inLength - n), MemoryLayout<Float>.size * Int(n))
    } else {
        //  copy data into the delay line
        memcpy(fir.pointee.delayLine + Int(n), inArray, MemoryLayout<Float>.size * Int(inLength))
        //  filter the data in the delay line (length = taps)
        vDSP_conv(fir.pointee.delayLine, 1, fir.pointee.kernel, 1, outArray, 1, vDSP_Length(inLength), vDSP_Length(n))
        memcpy(fir.pointee.delayLine, fir.pointee.delayLine + Int(inLength), MemoryLayout<Float>.size * Int(n))
    }
}

//  apply FIR interpolation for array and length of array
//  FIR is an interpolating filter, outArray size should be inLength*activeTaps
private func performInterpolation(_ fir: UnsafeMutablePointer<CMFIR>!, _ inArray: UnsafeMutablePointer<Float>!, _ inLength: Int32, _ outArray: UnsafeMutablePointer<Float>!) {
    let stride = fir.pointee.stride
    let taps = fir.pointee.activeTaps
    let n = stride * taps

    //  provide FIR overlap by copying an extra set of activeTaps into the delay line
    memcpy(fir.pointee.delayLine + Int(taps), inArray, MemoryLayout<Float>.size * Int(taps))

    //  filter the data in the delay line (length = taps)
    var i: Int32 = 0
    while i < stride {
        vDSP_conv(fir.pointee.delayLine, 1, fir.pointee.kernel + Int(stride - i - 1), vDSP_Stride(stride), outArray + Int(i), vDSP_Stride(stride), vDSP_Length(taps), vDSP_Length(taps))
        i += 1
    }
    // continue filtering with new data (length = inlength-taps)
    let p = outArray + Int(n)
    i = 0
    while i < stride {
        vDSP_conv(inArray, 1, fir.pointee.kernel + Int(stride - i - 1), vDSP_Stride(stride), p + Int(i), vDSP_Stride(stride), vDSP_Length(inLength - taps), vDSP_Length(taps))
        i += 1
    }
    //  copy tail into the delay line
    memcpy(fir.pointee.delayLine, inArray + Int(inLength - taps), MemoryLayout<Float>.size * Int(taps))
}

//  apply FIR interpolation for array and length of array
//  FIR is a decimating filter, outArray size should be inLength/factor.
//  Decimating factor has to divide kernel length
private func performDecimation(_ fir: UnsafeMutablePointer<CMFIR>!, _ inArray: UnsafeMutablePointer<Float>!, _ inLength: Int32, _ outArray: UnsafeMutablePointer<Float>!) {
    let factor = fir.pointee.stride
    let taps = fir.pointee.activeTaps
    var out: UnsafeMutablePointer<Float> = outArray

    if inLength <= taps {
        //  provide FIR overlap by copying an extra set of activeTaps into the delay line
        memcpy(fir.pointee.delayLine + Int(taps), inArray, MemoryLayout<Float>.size * Int(inLength))
        var i: Int32 = 0
        while i < inLength {
            vDSP_conv(fir.pointee.delayLine + Int(i), 1, fir.pointee.kernel, 1, out, 1, 1, vDSP_Length(taps)); out += 1
            i += factor
        }
        //  copy tail into the delay line
        memcpy(fir.pointee.delayLine, fir.pointee.delayLine + Int(inLength), MemoryLayout<Float>.size * Int(taps))
        return
    }
    //  provide FIR overlap by copying an extra set of activeTaps into the delay line
    memcpy(fir.pointee.delayLine + Int(taps), inArray, MemoryLayout<Float>.size * Int(taps))
    var i: Int32 = 0
    while i < taps {
        vDSP_conv(fir.pointee.delayLine + Int(i), 1, fir.pointee.kernel, 1, out, 1, 1, vDSP_Length(taps)); out += 1
        i += factor
    }
    i = 0
    while i < inLength - taps {
        vDSP_conv(inArray + Int(i), 1, fir.pointee.kernel, 1, out, 1, 1, vDSP_Length(taps)); out += 1
        i += factor
    }
    //  copy tail into the delay line
    memcpy(fir.pointee.delayLine, inArray + Int(inLength - taps), MemoryLayout<Float>.size * Int(taps))
}

private func performDelay(_ fir: UnsafeMutablePointer<CMFIR>!, _ inArray: UnsafeMutablePointer<Float>!, _ inLength: Int32, _ outArray: UnsafeMutablePointer<Float>!) {
    let n = fir.pointee.activeTaps

    if inLength > n {
        //  move data in the delay line to output (length = taps)
        memcpy(outArray, fir.pointee.delayLine, MemoryLayout<Float>.size * Int(n))
        //  filter rest of the data
        memcpy(outArray + Int(n), inArray, MemoryLayout<Float>.size * Int(inLength - n))
        //  copy tail of data into the front of the delay line
        memcpy(fir.pointee.delayLine, inArray + Int(inLength - n), MemoryLayout<Float>.size * Int(n))
    } else {
        //  copy data into the delay line
        memcpy(fir.pointee.delayLine + Int(n), inArray, MemoryLayout<Float>.size * Int(inLength))
        //  move data in the delay line to output (length = taps)
        memcpy(outArray, fir.pointee.delayLine, MemoryLayout<Float>.size * Int(n))
        memcpy(fir.pointee.delayLine, fir.pointee.delayLine + Int(inLength), MemoryLayout<Float>.size * Int(n))
    }
}

//  filter one sample.
func CMSimpleFilter(_ fir: UnsafeMutablePointer<CMFIR>!, _ input: Float) -> Float {
    let taps = fir.pointee.activeTaps

    if fir.pointee.delaylineHead >= taps {
        memcpy(fir.pointee.delayLine, fir.pointee.delayLine + Int(fir.pointee.delaylineHead), MemoryLayout<Float>.size * Int(taps))
        fir.pointee.delaylineHead = 0
    }
    let delayLine = fir.pointee.delayLine + Int(fir.pointee.delaylineHead)
    //  provide FIR overlap by copying new data at the end the delay line
    delayLine[Int(taps)] = input
    var v: Float = 0
    vDSP_conv(delayLine, 1, fir.pointee.kernel, 1, &v, 1, 1, vDSP_Length(taps))
    fir.pointee.delaylineHead += 1
    return v
}

//  add one sample to delay line and return samply that came out.
func CMSimpleDelay(_ fir: UnsafeMutablePointer<CMFIR>!, _ input: Float) -> Float {
    let taps = fir.pointee.activeTaps

    let v = fir.pointee.delayLine[0]
    fir.pointee.delayLine[Int(taps)] = input
    memcpy(fir.pointee.delayLine, fir.pointee.delayLine + 1, MemoryLayout<Float>.size * Int(taps))
    return v
}

//  advance filter with new samples, but do not compute output.
func CMAdvanceFilter(_ fir: UnsafeMutablePointer<CMFIR>!, _ input: UnsafeMutablePointer<Float>!, _ n: Int32) {
    let taps = fir.pointee.activeTaps
    if (fir.pointee.delaylineHead + n) < taps {
        let j = fir.pointee.delaylineHead + taps
        var i: Int32 = 0
        while i < n { fir.pointee.delayLine[Int(i + j)] = input[Int(i)]; i += 1 }
        fir.pointee.delaylineHead += n
        return
    }
    var i: Int32 = 0
    while i < n {
        if fir.pointee.delaylineHead >= taps {
            memcpy(fir.pointee.delayLine, fir.pointee.delayLine + Int(fir.pointee.delaylineHead), MemoryLayout<Float>.size * Int(taps))
            fir.pointee.delaylineHead = 0
        }
        fir.pointee.delayLine[Int(fir.pointee.delaylineHead + taps)] = input[Int(i)]
        fir.pointee.delaylineHead += 1
        i += 1
    }
}

//  decimate for one sample.  Length of inArray must be decimation ratio
func CMDecimate(_ fir: UnsafeMutablePointer<CMFIR>!, _ inArray: UnsafeMutablePointer<Float>!) -> Float {
    let factor = fir.pointee.stride        //  factor is decimation ratio
    let taps = fir.pointee.activeTaps

    if fir.pointee.delaylineHead >= taps {
        memcpy(fir.pointee.delayLine, fir.pointee.delayLine + Int(fir.pointee.delaylineHead), MemoryLayout<Float>.size * Int(taps))
        fir.pointee.delaylineHead = 0
    }
    let delayLine = fir.pointee.delayLine + Int(fir.pointee.delaylineHead)
    //  provide FIR overlap by copying new data at the end the delay line
    memcpy(delayLine + Int(taps), inArray, MemoryLayout<Float>.size * Int(factor))
    var v: Float = 0.0
    vDSP_conv(delayLine, 1, fir.pointee.kernel, 1, &v, 1, 1, vDSP_Length(taps))

    fir.pointee.delaylineHead += factor
    return v
}

//  apply FIR filter for inArray and length of array
//  size of outArray depends of the style
func CMPerformFIR(_ fir: UnsafeMutablePointer<CMFIR>!, _ inArray: UnsafeMutablePointer<Float>!, _ inLength: Int32, _ outArray: UnsafeMutablePointer<Float>!) {
    switch fir.pointee.style {
    case .kCMFilter:
        performFilter(fir, inArray, inLength, outArray)
    case .kCMDelayLine:
        performDelay(fir, inArray, inLength, outArray)
    case .kCMInterpolate:
        performInterpolation(fir, inArray, inLength, outArray)
    case .kCMDecimate:
        performDecimation(fir, inArray, inLength, outArray)
    }
}

func CMDeleteFIR(_ fir: UnsafeMutablePointer<CMFIR>!) {
    guard let fir = fir else { return }

    fir.pointee.delayLine?.deallocate()
    fir.pointee.kernel?.deallocate()
    fir.deallocate()
}
