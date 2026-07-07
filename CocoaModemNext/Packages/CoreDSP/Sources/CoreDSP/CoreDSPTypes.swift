//
//  CoreDSPTypes.swift
//  CoreDSP
//
//  The old cocoaModem Swift port left a handful of shared value types (and the
//  CMFs/CMPi constants) defined in a C header (CoreFilterTypes.h) exposed to
//  every Swift file through the app's bridging header -- fine for an app
//  target, but a pure SwiftPM package has no bridging header, so these become
//  real Swift declarations here, visible module-wide exactly as the C macros
//  and typedefs were.
//

import Foundation

public let CMFs: Double = 11025.0
public let CMPi: Double = 3.141592653589793

public struct CMDataStream {
    public var array: UnsafeMutablePointer<Float>!
    public var userData: Int = 0
    public var samplingRate: Float = 0
    public var sourceID: Int32 = 0
    public var samples: Int32 = 0
    public var components: Int32 = 0
    public var channels: Int32 = 1
    public init() {}
}

public struct CMAnalyticPair {
    public var re: Float
    public var im: Float
    public init(re: Float = 0, im: Float = 0) { self.re = re; self.im = im }
}

public struct CMAnalyticBuffer {
    public var re: UnsafeMutablePointer<Float>!
    public var im: UnsafeMutablePointer<Float>!
    public var size: Int32 = 0
    public init() {}
}
