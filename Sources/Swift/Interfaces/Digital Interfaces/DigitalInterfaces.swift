//
//  DigitalInterfaces.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/17/11.
//  Swift port of DigitalInterfaces.m.
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(DigitalInterfaces)
class DigitalInterfaces: NSObject {

	//  kMicrohamAutoRouting from ModemConfig.h
	private static let kMicrohamAutoRouting: Int32 = 0

	private var routerObj: Router?
	private var voxInterfaceObj: DigitalInterface!
	private var cocoaPTTInterfaceObj: DigitalInterface!
	private var userPTTInterfaceObj: DigitalInterface!
	private var mldxInterface: DigitalInterface!

	private var digiKeyerCount: Int32 = 0
	private var digiKeyerIICount: Int32 = 0
	private var microKeyerCount: Int32 = 0
	private var cwKeyerCount: Int32 = 0

	override init()
	{
		super.init()

		voxInterfaceObj = VOXInterface( name: "VOX" )
		cocoaPTTInterfaceObj = CocoaPTTInterface( name: "CocoaPTT" )
		userPTTInterfaceObj = UserPTTInterface( name: "User PTT" )
		mldxInterface = MacLoggerDX( name: "MacLoggerDX" )

		//  Router returns nil if Router is unavailable
		routerObj = Router( startRouter: true )
		digiKeyerCount = 0 ; digiKeyerIICount = 0 ; microKeyerCount = 0 ; cwKeyerCount = 0

		if let router = routerObj {
			let array = router.connectedKeyers()
			let n = array.count
			for i in 0 ..< n {
				let keyer = array[i]
				if keyer.isDigiKeyer() { digiKeyerCount += 1 }
				if keyer.isDigiKeyerII() { digiKeyerIICount += 1 }
				if keyer.isMicroKeyer() { microKeyerCount += 1 }
				if keyer.isCWKeyer() { cwKeyerCount += 1 }
			}
		}
	}

	//  NOTE: Swift cannot expose two distinct zero-argument init selectors on one
	//  class (both would be `init()`), so the original no-argument `initWithoutRouter`
	//  is exposed here as `initWithoutRouter:` and its sole caller (Application.m)
	//  updated to match.
	@objc(initWithoutRouter:)
	init( withoutRouter: Bool )
	{
		super.init()

		voxInterfaceObj = VOXInterface( name: "VOX" )
		cocoaPTTInterfaceObj = CocoaPTTInterface( name: "CocoaPTT" )
		userPTTInterfaceObj = UserPTTInterface( name: "User PTT" )
		mldxInterface = MacLoggerDX( name: "MacLoggerDX" )
		//  set Router to nil
		routerObj = nil
		digiKeyerCount = 0 ; digiKeyerIICount = 0 ; microKeyerCount = 0 ; cwKeyerCount = 0
	}

	@objc func voxInterface() -> DigitalInterface!
	{
		return voxInterfaceObj
	}

	@objc func cocoaPTTInterface() -> DigitalInterface!
	{
		return cocoaPTTInterfaceObj
	}

	@objc func userPTTInterface() -> DigitalInterface!
	{
		return userPTTInterfaceObj
	}

	@objc func macLoggerDX() -> DigitalInterface!
	{
		return mldxInterface
	}

	@objc func microHAMKeyers() -> [MicroKeyer]
	{
		guard let router = routerObj else { return [] }
		return router.connectedKeyers()
	}

	//	return the first microKeyer found
	@objc func microKeyer() -> MicroKeyer?
	{
		guard let router = routerObj else { return nil }
		let keyers = router.connectedKeyers()
		for keyer in keyers {
			if keyer.isMicroKeyer() { return keyer }
		}
		return nil
	}

	@objc func digiKeyer() -> MicroKeyer?
	{
		guard let router = routerObj else { return nil }
		let keyers = router.connectedKeyers()
		for keyer in keyers {
			if keyer.isDigiKeyer() { return keyer }
		}
		return nil
	}

	@objc func cwKeyer() -> MicroKeyer?
	{
		guard let router = routerObj else { return nil }
		let keyers = router.connectedKeyers()
		for keyer in keyers {
			if keyer.isCWKeyer() { return keyer }
		}
		return nil
	}

	@objc(useDigitalModeOnlyForFSK:)
	func useDigitalModeOnlyForFSK( _ state: Bool )
	{
		guard let router = routerObj else { return }
		let keyers = router.connectedKeyers()
		for keyer in keyers {
			keyer.useDigitalMode( forFSK: state )
		}
	}

	@objc func numberOfDigiKeyers() -> Int32
	{
		return digiKeyerCount
	}

	@objc func numberOfDigiKeyerIIs() -> Int32
	{
		return digiKeyerIICount
	}

	@objc func numberOfMicroKeyers() -> Int32
	{
		return microKeyerCount
	}

	@objc func numberOfCWKeyers() -> Int32
	{
		return cwKeyerCount
	}

	@objc func router() -> Router?
	{
		return routerObj
	}

	@objc(terminate:)
	func terminate( _ config: Config )
	{
		guard let router = routerObj else { return }

		if config.quitWithAutoRouting() {
			//  v0.93b
			let keyers = router.connectedKeyers()
			for keyer in keyers {
				keyer.setKeyerMode( DigitalInterfaces.kMicrohamAutoRouting )
			}
		}
		let routerQuitScriptFile = config.microKeyerQuitScriptFileName()
		if let file = routerQuitScriptFile, file.count > 0 {
			router.runQuitScript( file )
		} else {
			router.closeRouter()
		}
		routerObj = nil
	}

	@objc func closePTTConnections()
	{
		cocoaPTTInterfaceObj.closeConnection()
		userPTTInterfaceObj.closeConnection()
	}
}
