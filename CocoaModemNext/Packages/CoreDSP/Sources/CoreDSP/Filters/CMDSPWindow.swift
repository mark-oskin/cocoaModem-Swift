// Swift port of CMDSPWindow.c
//
//  CMDSPWindow.c
//  Filter (CoreModem)
//
//  Created by Kok Chen on Sun May 30 2004.
//

import Foundation

private let numpi = 3.14159265358979

//  sinc from -w.pi to w.pi
func CMSinc(_ i: Int32, _ n: Int32, _ w: Double) -> Double {
    var x: Double
    let t: Double

    if i < 0 || i >= n { return 0.0 }
    t = Double(n) / 2.0
    if (n & 1) == 0 { x = (Double(i) + 0.5 - t) / t } else { x = (Double(i) - t) / t }
    x = x * w
    if fabs(x) < 0.0001 { return 1.0 }

    return sin(numpi * x) / (numpi * x)
}

func CMHammingWindow(_ i: Int32, _ n: Int32) -> Double {
    let x: Float

    if i < 0 || i >= n { return 0.0 }
    if (n & 1) == 0 { x = Float(i) + 0.5 } else { x = Float(i) }
    return 0.54 + 0.46 * (sin(numpi * Double(x) / Double(n)))
}

func CMHanningWindow(_ i: Int32, _ n: Int32) -> Double {
    let x: Float

    if i < 0 || i >= n { return 0.0 }
    if (n & 1) == 0 { x = Float(i) + 0.5 } else { x = Float(i) }
    return 0.5 + 0.5 * (sin(numpi * Double(x) / Double(n)))
}

func CMBlackmanWindow(_ i: Int32, _ n: Int32) -> Double {
    let x: Float

    if i < 0 || i >= n { return 0.0 }
    if (n & 1) == 0 { x = Float(i) + 0.5 } else { x = Float(i) }
    return (0.42 - 0.5 * cos(2 * numpi * Double(x) / Double(n)) + 0.08 * cos(4 * numpi * Double(x) / Double(n)))
}

//  half cycle raised sine
func CMSineWindow(_ i: Int32, _ n: Int32) -> Double {
    let x: Float

    if i < 0 || i >= n { return 0.0 }
    if (n & 1) == 0 { x = Float(i) + 0.5 } else { x = Float(i) }
    return (sin(numpi * Double(x) / Double(n)))
}

//  produces a slightly more symmetrcal frequency impulse than the standard Blackman
func CMModifiedBlackmanWindow(_ i: Int32, _ n: Int32) -> Double {
    let x: Float

    if i < 0 || i >= n { return 0.0 }
    if (n & 1) == 0 { x = Float(i) + 0.5 } else { x = Float(i) }
    return (0.426 - 0.5 * cos(2 * numpi * Double(x) / Double(n)) + 0.074 * cos(4 * numpi * Double(x) / Double(n)))
}

func CMMakeSinc(_ n: Int32, _ w: Double) -> UnsafeMutablePointer<Float>! {
    let p: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    var i: Int32 = 0
    while i < n { p[Int(i)] = Float(CMSinc(i, n, w)); i += 1 }
    return p
}

private func fillBlackmanWindow(_ p: UnsafeMutablePointer<Float>!, _ n: Int32) {
    var i: Int32 = 0
    while i < n { p[Int(i)] = Float(CMBlackmanWindow(i, n)); i += 1 }
}

private func fillModifiedBlackmanWindow(_ p: UnsafeMutablePointer<Float>!, _ n: Int32) {
    var i: Int32 = 0
    while i < n { p[Int(i)] = Float(CMModifiedBlackmanWindow(i, n)); i += 1 }
}

func CMMakeBlackmanWindow(_ n: Int32) -> UnsafeMutablePointer<Float>! {
    let p: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    fillBlackmanWindow(p, n)
    return p
}

func CMMakeModifiedBlackmanWindow(_ n: Int32) -> UnsafeMutablePointer<Float>! {
    let p: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>.allocate(capacity: Int(n))
    fillModifiedBlackmanWindow(p, n)
    return p
}
