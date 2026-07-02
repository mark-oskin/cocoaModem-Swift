//
//  KeyerInterface.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/11/08.
//  Swift port of KeyerInterface.m (the class only).
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  NOTE: the two global C helpers obtainRouterPorts()/obtainKeyerPortsFromKeyerID()
//  remain as C in KeyerInterface.m / KeyerInterface.h so that Router.swift,
//  MicroKeyer.swift and any Obj-C caller keep a stable C linkage symbol.
//

import Cocoa

//  Per-keyer cache carried by PTTHub / FSKHub (was the C struct MicroHamKeyerCache).
struct MicroHamKeyerCache {
	var keyer: MicroKeyer? = nil
	var controlPort: Int32 = 0
	//  FSK
	var fskPort: Int32 = 0
	var flagsPort: Int32 = 0
	var currentBaudConstant: Int32 = 0
	var currentTxInvert: Int32 = 0
	var currentStopIndex: Int32 = 0
	//  PTT
	var pttPort: Int32 = 0
}

//  common base class for PTTHub and FSKHub to provide linkage to Router (µH Router)

@objc(KeyerInterface)
class KeyerInterface: AppleScriptSupport {

	//  µH Router -- base ivars reached by PTTHub / FSKHub subclasses -> internal
	internal var selectedMicroKeyer: MicroKeyer?
	internal var router: Router?
	internal var microKeyerCache = [MicroHamKeyerCache]( repeating: MicroHamKeyerCache(), count: 16 )
	internal var activeKeyers: Int32 = 0

	override init()
	{
		super.init()
		//  0 - 1 bit, 1 = 1.5 stop bits, 2 = 2 stop bits
		var cache = MicroHamKeyerCache()
		cache.currentStopIndex = 1
		microKeyerCache = [MicroHamKeyerCache]( repeating: cache, count: 16 )
		activeKeyers = 0
		router = nil
		selectedMicroKeyer = nil
	}

	//	v0.87
	//  mode =	0 - CW
	//			1 - Voice
	//			2 - FSK
	//			3 - Digital
	@objc(setKeyerMode:controlPort:)
	func setKeyerMode( _ mode: Int32, controlPort port: Int32 )
	{
		if port <= 0 { return }

		var control: [UInt8] = [ 0x0f, 0x02, 0x00, 0x8f ]
		control[2] = UInt8( truncatingIfNeeded: mode )
		_ = control.withUnsafeBufferPointer { write( port, $0.baseAddress, 4 ) }
	}

	@objc func digiKeyerControlPort() -> Int32
	{
		//  override by sub class
		return 0
	}

	@objc func microKeyerControlPort() -> Int32
	{
		//  override by sub class
		return 0
	}

	@objc func cwKeyerControlPort() -> Int32
	{
		//  override by sub class
		return 0
	}
}
