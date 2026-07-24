// Swift port of CMFFT.c
//
//  CMFFT.c / CMFFT.h
//  Filter (CoreModem)
//
//  Created by Kok Chen on 11/04/05
//  Ported from cocoaModem, file dated Thu May 27 2004.
//
//  Faithful reimplementation of the vDSP power-spectrum / forward FFT wrapper.
//  Uses Accelerate's vDSP directly with the same arguments/strides as the C.
//

import Foundation
import Accelerate

//  From CMFFT.h -- imported enum (Forward = 0, Inverse = 1, PowerSpectrum = 2).
enum CMFFTStyle: Int32 {
    case Forward = 0
    case Inverse
    case PowerSpectrum
}

//  typedef DSPSplitComplex FFTData ;
typealias FFTData = DSPSplitComplex

//  From CMFFT.h -- exact field names/types/order.
struct CMFFT {
    var log2n: Int32
    var size: Int32
    var window: UnsafeMutablePointer<Float>!
    var tempBuf: DSPSplitComplex
    var realBuf: UnsafeMutablePointer<Float>!
    var imagBuf: UnsafeMutablePointer<Float>!
    var style: CMFFTStyle
    var vfft: FFTSetup!
    var z: DSPSplitComplex?      //  allocated only on the PowerSpectrum path (nil for Forward)
}

//  create a vDSP power spectrum structure
func FFTSpectrum(_ log2n: Int32, _ useWindow: Bool) -> UnsafeMutablePointer<CMFFT>! {
    let fft = UnsafeMutablePointer<CMFFT>.allocate(capacity: 1)

    let size = Int32(1) << log2n
    //  z.realp / z.imagp : malloc( size*sizeof(float)/2 ) bytes == size/2 floats.
    //  tempBuf.realp / .imagp : malloc( sizeof(float)*16384 ) == 16384 floats.
    fft.initialize(to: CMFFT(
        log2n: log2n,
        size: size,
        window: useWindow ? CMMakeModifiedBlackmanWindow(size / 2) : nil,
        tempBuf: DSPSplitComplex(
            realp: UnsafeMutablePointer<Float>.allocate(capacity: 16384),
            imagp: UnsafeMutablePointer<Float>.allocate(capacity: 16384)),
        realBuf: nil,
        imagBuf: nil,
        style: .PowerSpectrum,
        vfft: vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)),
        z: DSPSplitComplex(
            realp: UnsafeMutablePointer<Float>.allocate(capacity: Int(size / 2)),
            imagp: UnsafeMutablePointer<Float>.allocate(capacity: Int(size / 2)))
    ))
    return fft
}

func FFTForward(_ log2n: Int32, _ useWindow: Bool) -> UnsafeMutablePointer<CMFFT>! {
    let fft = UnsafeMutablePointer<CMFFT>.allocate(capacity: 1)

    let size = Int32(1) << log2n
    //  tempBuf.realp / .imagp : malloc( sizeof(float)*16384 ) == 16384 floats.
    //  realBuf / imagBuf : allocated only when useWindow, size floats each.
    fft.initialize(to: CMFFT(
        log2n: log2n,
        size: size,
        window: useWindow ? CMMakeModifiedBlackmanWindow(size) : nil,
        tempBuf: DSPSplitComplex(
            realp: UnsafeMutablePointer<Float>.allocate(capacity: 16384),
            imagp: UnsafeMutablePointer<Float>.allocate(capacity: 16384)),
        realBuf: useWindow ? UnsafeMutablePointer<Float>.allocate(capacity: Int(size)) : nil,
        imagBuf: useWindow ? UnsafeMutablePointer<Float>.allocate(capacity: Int(size)) : nil,
        style: .Forward,
        vfft: vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)),
        z: nil
    ))
    return fft
}

func CMPerformFFT(_ fft: UnsafeMutablePointer<CMFFT>!, _ input: UnsafeMutablePointer<Float>!, _ output: UnsafeMutablePointer<Float>!) {
    let n = Int(fft.pointee.size)
    let nby2 = n / 2

    switch fft.pointee.style {
    case .PowerSpectrum:
        //  z holds the two split-complex buffer pointers; operate on a local
        //  copy (the pointed-to buffers are shared, so no write-back is needed).
        guard var z = fft.pointee.z else { break }
        let cinput = UnsafeRawPointer(input!).assumingMemoryBound(to: DSPComplex.self)
        vDSP_ctoz(cinput, 2, &z, 1, vDSP_Length(nby2))
        if fft.pointee.window != nil {
            for i in 0..<nby2 {
                z.realp[i] *= fft.pointee.window[i]
                z.imagp[i] *= fft.pointee.window[i]
            }
        }
        vDSP_fft_zript(fft.pointee.vfft, &z, 1, &fft.pointee.tempBuf, vDSP_Length(fft.pointee.log2n), FFTDirection(kFFTDirection_Forward))
        vDSP_vsq(z.realp, 1, z.realp, 1, vDSP_Length(nby2))
        vDSP_vsq(z.imagp, 1, z.imagp, 1, vDSP_Length(nby2))
        vDSP_vadd(z.realp, 1, z.imagp, 1, &output[0], 1, vDSP_Length(nby2))
    default:
        break
    }
}

func CMPerformComplexFFT(_ fft: UnsafeMutablePointer<CMFFT>!, _ input: UnsafeMutablePointer<DSPSplitComplex>!, _ output: UnsafeMutablePointer<DSPSplitComplex>!) {
    let n = Int(fft.pointee.size)

    switch fft.pointee.style {
    case .Forward:
        if fft.pointee.window != nil {
            for i in 0..<n {
                let w = fft.pointee.window[i]
                fft.pointee.realBuf[i] = input.pointee.realp[i] * w
                fft.pointee.imagBuf[i] = input.pointee.imagp[i] * w
            }
            var c = DSPSplitComplex(realp: fft.pointee.realBuf, imagp: fft.pointee.imagBuf)
            vDSP_fft_zopt(fft.pointee.vfft, &c, 1, output, 1, &fft.pointee.tempBuf, vDSP_Length(fft.pointee.log2n), FFTDirection(kFFTDirection_Forward))
        } else {
            vDSP_fft_zopt(fft.pointee.vfft, input, 1, output, 1, &fft.pointee.tempBuf, vDSP_Length(fft.pointee.log2n), FFTDirection(kFFTDirection_Forward))
        }
    default:
        break
    }
}

func CMDeleteFFT(_ fft: UnsafeMutablePointer<CMFFT>!) {
    switch fft.pointee.style {
    case .PowerSpectrum:
        vDSP_destroy_fftsetup(fft.pointee.vfft)
        if fft.pointee.window != nil { fft.pointee.window.deallocate() }
        fft.pointee.z?.realp.deallocate()
        fft.pointee.z?.imagp.deallocate()
    default:
        break
    }
    fft.deallocate()
}
