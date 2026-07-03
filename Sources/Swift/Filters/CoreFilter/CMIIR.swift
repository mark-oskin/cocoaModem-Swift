// Swift port of CMIIR.c
//
//  CMIIR.c
//  Filter (CoreModem)
//
//  Created by Kok Chen on
//	Ported from ModemFilter.c in cocoaModem, original file dated Thu Jun 03 2004.
//
//  These are routines used to generate the filter coefficients that are used in
//  cocoaModem.  IIR design adapted from applet by http://www.dsptutor.freeuk.com/
//
//  Faithful reimplementation: the pole/zero mathematics is kept in double
//  precision, complex arithmetic is done in scalar real/imaginary components and
//  the loop bounds / index arithmetic mirror the original C exactly.

import Foundation

//  #define CMFs 11025.0 / #define CMPi 3.141592653589793 (CoreFilterTypes.h),
//  #define samplingRate CMFs (CMIIR.c) — kept as file-scope constants.
private let CMPi: Double = 3.141592653589793
private let samplingRate: Double = 11025.0        // CMFs

//  Filter types.  Originally #define LP 0 / HP 1 / BP 2 in CMIIR.h — provided
//  here so existing Swift callers (e.g. CrossedEllipse) still resolve them.
let LP: Int32 = 0
let HP: Int32 = 1
let BP: Int32 = 2

//  typedef struct { ... } IIR  (CMIIR.h)
struct IIR {
    var filterType: Int32 = 0
    var order: Int32 = 0
    var fp1: Double = 0
    var fp2: Double = 0
    var fN: Double = 0
    var z = [Double](repeating: 0, count: 16)
    var pReal = [Double](repeating: 0, count: 16)
    var pImag = [Double](repeating: 0, count: 16)
    var pole: UnsafeMutablePointer<Double>! = nil
    var zero: UnsafeMutablePointer<Double>! = nil
}

private func filterGain(_ iir: inout IIR, _ freq: Float) -> Float {
    var theta: Double, s: Double, c: Double
    var sac: Double, sas: Double, sbc: Double, sbs: Double
    let g: Double
    var k: Int
    let order: Int

    order = Int(iir.order)

    theta = CMPi * Double(freq) / iir.fN
    sac = 0.0; sas = 0.0; sbc = 0.0; sbs = 0.0
    k = 0
    while k <= order {
        c = cos(Double(k) * theta)
        s = sin(Double(k) * theta)
        sac += c * iir.zero[k]
        sas += s * iir.zero[k]
        sbc += c * iir.pole[k]
        sbs += s * iir.pole[k]
        k += 1
    }
    g = sqrt((sac * sac + sas * sas) / (sbc * sbc + sbs * sbs))

    return Float(g)
}

//  poles and zeros from bilinear transform
private func butterworth(_ iir: inout IIR) {
    var f1: Double, f4: Double, f5: Double
    var tanw1: Double, tansqw1: Double
    var t: Double, re: Double, im: Double, b3: Double
    var aa: Double, aR: Double, aI: Double, h1: Double, h2: Double
    var p1R: Double, p2R: Double, p1I: Double, p2I: Double
    var fR: Double, fI: Double, gR: Double, gI: Double, sR: Double, sI: Double
    var k: Int, n: Int, m: Int, m1: Int, ir: Int, n1: Int, n2: Int

    n = Int(iir.order)
    k = 0
    while k <= n {
        iir.pReal[k] = 0
        iir.pImag[k] = 0
        k += 1
    }

    if iir.filterType == BP { n = n / 2 }
    ir = n % 2
    n1 = n + ir
    n2 = (3 * n + ir) / 2 - 1
    switch iir.filterType {
    case LP:
        f1 = iir.fp2
    case HP:
        f1 = iir.fN - iir.fp1
    case BP:
        f1 = iir.fp2 - iir.fp1
    default:
        f1 = 0
    }
    tanw1 = tan(0.5 * CMPi * f1 / iir.fN)
    tansqw1 = tanw1 * tanw1
    // low-pass poles
    re = 1.0
    im = 1.0
    k = n1
    while k <= n2 {
        t = 0.5 * Double(2 * k + 1 - ir) * CMPi / Double(n)
        b3 = 1.0 - 2.0 * tanw1 * cos(t) + tansqw1
        re = (1.0 - tansqw1) / b3
        im = 2.0 * tanw1 * sin(t) / b3

        m = 2 * (n2 - k) + 1
        iir.pReal[m + ir] = re
        iir.pImag[m + ir] = fabs(im)
        iir.pReal[m + ir + 1] = re
        iir.pImag[m + ir + 1] = -fabs(im)
        k += 1
    }
    if (n & 1) != 0 {
        re = (1.0 - tansqw1) / (1.0 + 2.0 * tanw1 + tansqw1)
        iir.pReal[1] = re
        iir.pImag[1] = 0
    }
    switch iir.filterType {
    case LP:
        m = 1
        while m <= n { iir.z[m] = -1.0; m += 1 }
    case HP:
        // low-pass to high-pass transformation
        m = 1
        while m <= n {
            iir.pReal[m] = -iir.pReal[m]
            iir.z[m] = 1.0
            m += 1
        }
    case BP:
        // low-pass to bandpass transformation
        m = 1
        while m <= n {
            iir.z[m] = 1.0
            iir.z[m + n] = -1.0
            m += 1
        }
        f4 = 0.5 * CMPi * iir.fp1 / iir.fN
        f5 = 0.5 * CMPi * iir.fp2 / iir.fN

        aa = cos(f4 + f5) / cos(f5 - f4)

        m1 = 0
        while m1 <= (Int(iir.order) - 1) / 2 {
            m = 2 * m1 + 1
            aR = iir.pReal[m]
            aI = iir.pImag[m]
            if fabs(aI) < 0.0001 {
                h1 = 0.5 * aa * (1.0 + aR)
                h2 = h1 * h1 - aR
                if h2 > 0.0 {
                    p1R = h1 + sqrt(h2)
                    p2R = h1 - sqrt(h2)
                    p1I = 0
                    p2I = 0
                } else {
                    p1R = h1
                    p2R = h1
                    p1I = sqrt(fabs(h2))
                    p2I = -p1I
                }
            } else {
                fR = aa * 0.5 * (1.0 + aR)
                fI = aa * 0.5 * aI
                gR = fR * fR - fI * fI - aR
                gI = 2.0 * fR * fI - aI
                sR = sqrt(0.5 * fabs(gR + sqrt(gR * gR + gI * gI)))
                sI = gI / (2.0 * sR)
                p1R = fR + sR
                p1I = fI + sI
                p2R = fR - sR
                p2I = fI - sI
            }
            iir.pReal[m] = p1R
            iir.pReal[m + 1] = p2R
            iir.pImag[m] = p1I
            iir.pImag[m + 1] = p2I
            m1 += 1
        }
        if (n & 1) != 0 {
            iir.pReal[2] = iir.pReal[n + 1]
            iir.pImag[2] = iir.pImag[n + 1]
        }
        k = n
        while k >= 1 {
            m = 2 * k - 1
            let rv = iir.pReal[k]
            iir.pReal[m] = rv
            iir.pReal[m + 1] = rv
            let iv = fabs(iir.pImag[k])
            iir.pImag[m] = iv
            iir.pImag[m + 1] = -iv
            k -= 1
        }
    default:
        break
    }
}

//  for lpf and hp, specify bw only (cutoff)
//  filter gain is returned
func butterworthDesign(_ order: Int32, _ type: Int32, _ bw: Float, _ fCenter: Float, _ pole: UnsafeMutablePointer<Double>!, _ zero: UnsafeMutablePointer<Double>!) -> Float {
    var iir = IIR()
    var zerop = [Double](repeating: 0, count: 16)
    var polep = [Double](repeating: 0, count: 16)
    let r: Double
    var alpha1: Double, alpha2: Double, beta1: Double, beta2: Double
    var i: Int, k: Int, m: Int, n: Int, pairs: Int, p: Int

    iir.order = order
    iir.filterType = type
    iir.fN = samplingRate * 0.5

    switch type {
    case LP:
        iir.fp1 = 0.0
        iir.fp2 = Double(bw)
    case HP:
        iir.fp1 = Double(bw)
        iir.fp2 = iir.fN
    default:
        // BP (and any other type) — matches C `default: case BP:`
        r = (Double(bw) + sqrt(Double(bw * bw) + 4.0 * Double(fCenter) * Double(fCenter))) / (2.0 * Double(fCenter))
        iir.fp1 = Double(fCenter) / r
        iir.fp2 = Double(fCenter) * r
    }

    butterworth(&iir)

    pole[0] = 1
    zero[0] = 1
    i = 1
    while i <= Int(order) {
        pole[i] = 0
        zero[i] = 0
        i += 1
    }

    k = 0
    n = Int(order)
    pairs = n / 2
    if (order & 1) != 0 {
        // first subfilter is first order
        pole[1] = -iir.z[1]
        zero[1] = -iir.pReal[1]
        k = 1
    }
    p = 1
    while p <= pairs {
        m = 2 * p - 1 + k
        alpha1 = -(iir.z[m] + iir.z[m + 1])
        alpha2 = iir.z[m] * iir.z[m + 1]
        beta1 = -2.0 * iir.pReal[m]
        beta2 = iir.pReal[m] * iir.pReal[m] + iir.pImag[m] * iir.pImag[m]

        zerop[1] = zero[1] + alpha1 * zero[0]
        polep[1] = pole[1] + beta1 * pole[0]
        i = 2
        while i <= n {
            zerop[i] = zero[i] + alpha1 * zero[i - 1] + alpha2 * zero[i - 2]
            polep[i] = pole[i] + beta1 * pole[i - 1] + beta2 * pole[i - 2]
            i += 1
        }
        i = 1
        while i <= n {
            zero[i] = zerop[i]
            pole[i] = polep[i]
            i += 1
        }
        p += 1
    }
    iir.pole = pole
    iir.zero = zero

    switch type {
    case LP:
        return filterGain(&iir, 0.0)
    case HP:
        return filterGain(&iir, Float(iir.fN))
    default:
        break
    }
    return filterGain(&iir, fCenter)
}

func notchDesign(_ bw: Float, _ fNotch: Float, _ pole: UnsafeMutablePointer<Double>!, _ zero: UnsafeMutablePointer<Double>!) -> Float {
    let w0: Float, Bw: Float
    let alpha: Double, beta: Double, t: Double

    w0 = Float(2.0 * CMPi * Double(fNotch) / samplingRate)
    Bw = Float(2.0 * CMPi * Double(bw) / samplingRate)
    t = tan(Double(Bw) * 0.5)

    alpha = (1.0 - t) / (1.0 + t)
    beta = cos(Double(w0))

    zero[0] = 1.0
    zero[1] = -2.0 * beta
    zero[2] = 1.0
    pole[0] = 1.0
    pole[1] = -2.0 * beta * (1.0 + alpha)
    pole[2] = alpha

    return Float(2.0 / (1.0 + alpha))
}
