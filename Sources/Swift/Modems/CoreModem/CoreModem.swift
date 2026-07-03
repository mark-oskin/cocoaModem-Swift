//
//  CoreModem.swift
//  cocoaModem
//
//  Created by Kok Chen on 10/26/05.
//  Swift port of CoreModem.{h,m}.
//
//  Declares the four global sin/cos lookup tables (mssin, lssin, mscos, lscos)
//  as module-level globals with the SAME names and types the C exposed through
//  the bridging header (`extern float *mssin, *lssin, *mscos, *lscos;`), and a
//  CoreModem class whose -init allocates and fills them exactly as the C did.
//

import Foundation

//  CMPi as defined in CoreFilterTypes.h ("#define CMPi 3.141592653589793" == M_PI)
private let CMPi = 3.141592653589793

//  static sin/cos tables (were the C globals `float *mssin, *lssin, *mscos, *lscos;`)
var mssin: UnsafeMutablePointer<Float>!
var lssin: UnsafeMutablePointer<Float>!
var mscos: UnsafeMutablePointer<Float>!
var lscos: UnsafeMutablePointer<Float>!

@objc(CoreModem)
class CoreModem: NSObject {

    override init() {
        super.init()

        mssin = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        lssin = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        mscos = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        lscos = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        for i in 0..<1024 {
            var theta = Double(i << 10) * 2.0 * CMPi / 262144.0
            mssin[i] = Float(sin(theta))
            mscos[i] = Float(cos(theta))
            theta = Double(i) * 2.0 * CMPi / 262144.0
            lssin[i] = Float(sin(theta))
            lscos[i] = Float(cos(theta))
        }
    }

    deinit {
        mssin.deallocate()
        lssin.deallocate()
        mscos.deallocate()
        lscos.deallocate()
    }
}
