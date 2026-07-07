//
//  CoreModem.swift
//  CoreDSP
//
//  The four sin/cos lookup tables every NCO (all tone generation) reads from.
//  The old app built these via a class whose -init had to run exactly once and
//  then be discarded (a leftover of the original Objective-C's manual retain
//  count and a one-shot "initialize CoreModem framework" call). A lazily
//  computed, thread-safe static table has the same one-time-computation
//  behavior with none of that ceremony.
//

import Foundation

private let tableCount = 1024

private func makeTable(shifted: Bool, cosine: Bool) -> [Float] {
    var table = [Float](repeating: 0, count: tableCount)
    for i in 0..<tableCount {
        let theta = (shifted ? Double(i << 10) : Double(i)) * 2.0 * CMPi / 262144.0
        table[i] = Float(cosine ? cos(theta) : sin(theta))
    }
    return table
}

public let mssin: [Float] = makeTable(shifted: true, cosine: false)
public let mscos: [Float] = makeTable(shifted: true, cosine: true)
public let lssin: [Float] = makeTable(shifted: false, cosine: false)
public let lscos: [Float] = makeTable(shifted: false, cosine: true)
