//
//  DigitalInterface.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/16/11.
//  Swift port of DigitalInterface.m.
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

//  Base class for VOX/CocoaPTT/User PTT/MacLoggerDX/microHAM keyer interfaces.
//
//  NOTE: the original Obj-C ivars name/hasPTT/connected/type each collide with an
//  accessor method of the same name (-name/-hasPTT/-connected/-type).  Swift does
//  not allow a stored property and a method to share a name, so the backing stores
//  are renamed (interfaceName/interfaceHasPTT/interfaceConnected/interfaceType)
//  while the accessor selectors are preserved exactly.  Subclasses reach the
//  renamed stores directly (they are internal).

@objc(DigitalInterface)
class DigitalInterface: AppleScriptSupport {

	private var interfaceName: String = ""
	internal var interfaceHasPTT: Bool = false		//  was ivar `hasPTT`
	internal var interfaceConnected: Bool = false	//  was ivar `connected`
	internal var interfaceType: Int32 = 0			//  was ivar `type`

	@objc(initWithName:)
	init( name vname: String )
	{
		super.init()
		interfaceType = 0
		interfaceHasPTT = false
		interfaceConnected = false
		interfaceName = vname
	}

	@objc func connected() -> Bool
	{
		return false
	}

	@objc func name() -> String
	{
		return interfaceName
	}

	@objc func type() -> Int32
	{
		return interfaceType
	}

	@objc func hasPTT() -> Bool
	{
		return interfaceHasPTT
	}

	@objc(setPTTState:)
	func setPTTState( _ state: Bool )
	{
	}

	@objc func hasFSK() -> Bool
	{
		return false
	}

	@objc func hasOOK() -> Bool
	{
		return false
	}

	@objc func closeConnection()
	{
	}
}
