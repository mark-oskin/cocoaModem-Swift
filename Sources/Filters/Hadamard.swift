// Swift port of hadamard.c
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/25/06.

import Foundation

struct HadamardTransform {
    var n: Int32
    var dir: Int32
    var buffer: UnsafeMutablePointer<Float>!
}

func Hadamard(_ order: Int32) -> UnsafeMutablePointer<HadamardTransform>! {
    let h = UnsafeMutablePointer<HadamardTransform>.allocate(capacity: 1)
    h.pointee.n = order
    h.pointee.dir = 1    //  forward transform
    h.pointee.buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(order))

    return h
}

func DeleteHadamard(_ h: UnsafeMutablePointer<HadamardTransform>!) {
    if let h = h {
        h.pointee.buffer.deallocate()
        h.deallocate()
    }
}

func TransformHadamard(_ h: UnsafeMutablePointer<HadamardTransform>!, _ in_: UnsafeMutablePointer<Float>!, _ spectrum: UnsafeMutablePointer<Float>!) {
    var d: UnsafeMutablePointer<Float>
    var d1: Float, d2: Float, scale: Float
    var i: Int32, j: Int32, k: Int32, n1: Int32, n2: Int32

    i = 0
    while i < h.pointee.n { spectrum[Int(i)] = in_[Int(i)]; i += 1 }
    if h.pointee.n < 2 { return }

    n1 = 2
    n2 = 1

    while n1 <= h.pointee.n {
        i = 0
        while i < h.pointee.n { h.pointee.buffer[Int(i)] = spectrum[Int(i)]; i += 1 }

        i = 0
        while i < h.pointee.n {
            k = i
            d = spectrum + Int(i)

            j = 0
            while j < n1 {

                d1 = h.pointee.buffer[Int(k)]
                d2 = h.pointee.buffer[Int(k + n2)]

                if (j & 0x2) != 0 {
                    d[Int(j)] = d1 - d2
                    d[Int(j + 1)] = d1 + d2
                } else {
                    d[Int(j)] = d1 + d2
                    d[Int(j + 1)] = d1 - d2
                }
                k += 1
                j += 2
            }
            i += n1
        }
        n2 = n1
        n1 *= 2
    }
    if h.pointee.dir < 0 {
        //  need to normalize by order is inverse transform
        scale = 1.0 / Float(h.pointee.n)
        i = 0
        while i < h.pointee.n { spectrum[Int(i)] *= scale; i += 1 }
    }
}
