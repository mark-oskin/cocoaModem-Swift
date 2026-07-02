//
//  VOXInterface.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/16/11.
//  Swift port of VOXInterface.m.
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(VOXInterface)
class VOXInterface: DigitalInterface {

	//  DigitalInterfaces.h : kVOXType
	private static let kVOXType: Int32 = 0

	@objc(initWithName:)
	override init( name vname: String )
	{
		super.init( name: vname )
		interfaceHasPTT = true
		interfaceType = VOXInterface.kVOXType
	}

	@objc override func connected() -> Bool
	{
		return true
	}
}
