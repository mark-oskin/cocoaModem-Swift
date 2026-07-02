//
//  SubDictionary.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/10/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of SubDictionary.m.
//

import Cocoa

@objc(SubDictionary)
class SubDictionary: NSObject {
    private let dict = NSMutableDictionary(capacity: 16)

    @objc func dictionary() -> NSMutableDictionary {
        return dict
    }

    @objc(intValueForKey:)
    func intValueForKey(_ key: String) -> Int32 {
        guard let num = dict.object(forKey: key) as? NSNumber else { return 0 }
        return num.int32Value
    }

    @objc(setInt:forKey:)
    func setInt(_ value: Int32, forKey key: String) {
        dict.setObject(NSNumber(value: value), forKey: key as NSString)
    }

    @objc(floatValueForKey:)
    func floatValueForKey(_ key: String) -> Float {
        guard let num = dict.object(forKey: key) as? NSNumber else { return 0 }
        return num.floatValue
    }

    @objc(setFloat:forKey:)
    func setFloat(_ value: Float, forKey key: String) {
        dict.setObject(NSNumber(value: value), forKey: key as NSString)
    }
}
