//
//  FSK.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/12/08.
//  Swift port of FSK.m.
//  Copyright Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(FSK)
class FSK: NSObject {

	//  interface types (from FSK.h)
	private static let kSeparatorType: Int32 = 0
	private static let kAFSKType: Int32 = 1
	private static let kBadType: Int32 = 2
	private static let kFSKType: Int32 = 3
	private static let kOOKType: Int32 = 4
	private static let kPFSKType: Int32 = 5

	//  menu titles (from FSKMenu.h)
	private static let kAFSKMenuTitle = "AFSK"
	private static let kDigiKeyerMenuTitle = "FSK: digiKEYER"
	private static let kMicroKeyerMenuTitle = "FSK: microKEYER"
	private static let kDigiKeyerOOKMenuTitle = "OOK: digiKEYER"
	private static let kOOKMenuTitle = "OOK"
	private static let kFSKShortMenuTitle = "FSK: "

	private struct InterfaceEntry {
		var keyer: MicroKeyer?
		var type: Int32
		var enabled: Bool
	}

	private var modem: RTTY!
	private var menu: NSPopUpButton?
	private var interfaces = [InterfaceEntry]( repeating: InterfaceEntry( keyer: nil, type: 0, enabled: false ), count: 32 )
	private var hub: FSKHub!
	private var selectedPort: Int32 = 0

	@objc(initWithHub:menu:modem:)
	init( hub fskHub: FSKHub, menu fskMenu: NSPopUpButton?, modem client: RTTY )
	{
		super.init()
		modem = client
		menu = fskMenu
		hub = fskHub
		selectedPort = 0

		guard let digitalInterfaces = ( NSApp.delegate as? Application )?.digitalInterfaces() else { return }
		menu?.removeAllItems()

		menu?.addItem( withTitle: FSK.kAFSKMenuTitle )
		interfaces[0].type = FSK.kAFSKType
		interfaces[0].keyer = nil
		interfaces[0].enabled = true

		menu?.menu?.addItem( NSMenuItem.separator() )
		interfaces[1].type = FSK.kSeparatorType
		interfaces[1].keyer = nil
		interfaces[1].enabled = false

		let digiKeyers = digitalInterfaces.numberOfDigiKeyers()
		let microKeyers = digitalInterfaces.numberOfMicroKeyers()

		var menuItems: Int
		if digiKeyers <= 1 && microKeyers <= 1 {
			menu?.addItem( withTitle: FSK.kDigiKeyerMenuTitle )
			var keyer = digitalInterfaces.digiKeyer()
			if keyer == nil {
				interfaces[2].type = FSK.kBadType
				interfaces[2].keyer = nil
				interfaces[2].enabled = false
			}
			else {
				interfaces[2].type = FSK.kFSKType
				interfaces[2].keyer = keyer
				interfaces[2].enabled = true
			}

			menu?.addItem( withTitle: FSK.kMicroKeyerMenuTitle )
			keyer = digitalInterfaces.microKeyer()
			if keyer == nil {
				interfaces[3].type = FSK.kBadType
				interfaces[3].keyer = nil
				interfaces[3].enabled = false
			}
			else {
				interfaces[3].type = FSK.kFSKType
				interfaces[3].keyer = keyer
				interfaces[3].enabled = true
			}
			menuItems = 4
		}
		else {
			menuItems = 2
			let keyers = digitalInterfaces.microHAMKeyers()
			let n = keyers.count
			for i in 0 ..< n {
				//  list each keyer that is FSK capable
				let keyer = keyers[i]
				if keyer.isMicroKeyer() || keyer.isDigiKeyer() {
					menu?.addItem( withTitle: String( format: "%@ %s", FSK.kFSKShortMenuTitle, keyer.keyerID()! ) )
					interfaces[menuItems].type = FSK.kFSKType
					interfaces[menuItems].keyer = keyer
					interfaces[menuItems].enabled = true
					menuItems += 1
				}
			}
		}
		menu?.menu?.addItem( NSMenuItem.separator() )
		interfaces[menuItems].type = FSK.kSeparatorType
		interfaces[menuItems].keyer = nil
		interfaces[menuItems].enabled = false
		menuItems += 1

		menu?.addItem( withTitle: FSK.kDigiKeyerOOKMenuTitle )
		interfaces[menuItems].type = FSK.kPFSKType
		interfaces[menuItems].keyer = nil
		interfaces[menuItems].enabled = true
		menuItems += 1

		menu?.addItem( withTitle: FSK.kOOKMenuTitle )
		interfaces[menuItems].type = FSK.kOOKType
		interfaces[menuItems].keyer = nil
		interfaces[menuItems].enabled = true
	}

	// NSMenuValidation for FSK menus; called by RTTYConfig to validate its menus
	@objc(validateAfskMenuItem:)
	func validateAfskMenuItem( _ item: NSMenuItem ) -> Bool
	{
		let n = menu?.numberOfItems ?? 0
		for i in 0 ..< n {
			if item === menu?.item( at: i ) {
				return interfaces[i].enabled
			}
		}
		return true
	}

	@objc(fskPortForName:)
	func fskPortForName( _ title: String? ) -> Int32
	{
		guard let items = menu?.menu else { return 0 }
		let n = items.indexOfItem( withTitle: title ?? "" )
		if n < 0 { return 0 }

		guard let keyer = interfaces[n].keyer else { return 0 }
		return keyer.fskWriteDescriptor()
	}

	//  v0.89
	@objc(controlPortForName:)
	func controlPortForName( _ title: String? ) -> Int32
	{
		guard let items = menu?.menu else { return 0 }
		let n = items.indexOfItem( withTitle: title ?? "" )
		if n < 0 { return 0 }

		guard let keyer = interfaces[n].keyer else { return 0 }
		return keyer.controlWriteDescriptor()
	}

	//	v0.90
	@objc(checkAvailability:)
	func checkAvailability( _ title: String? ) -> Bool
	{
		guard let items = menu?.menu else { return false }
		let n = items.indexOfItem( withTitle: title ?? "" )
		if n < 0 { return false }

		return interfaces[n].enabled
	}

	@objc func selectedFSKPort() -> Int32
	{
		return fskPortForName( menu?.titleOfSelectedItem )
	}

	//  set fd to port selected by menu (or 0 if error)
	@objc func useSelectedPort() -> Int32
	{
		selectedPort = selectedFSKPort()
		return selectedPort
	}

	//  v0.87
	@objc(setKeyerMode:controlPort:)
	func setKeyerMode( _ mode: Int32, controlPort port: Int32 )
	{
		if port != 0 { hub.setKeyerMode( mode, controlPort: port ) }
	}

	//  streams

	@objc(startSampling:invert:stopBits:)
	func startSampling( _ baudrate: Float, invert invertTx: Bool, stopBits stopIndex: Int32 )
	{
		if selectedPort > 0 {
			hub.startSampling( selectedPort, baudRate: baudrate, invert: invertTx, stopBits: stopIndex, modem: modem )
		}
	}

	@objc func stopSampling()
	{
		if selectedPort > 0 { hub.stopSampling() }
	}

	@objc func clearOutput()
	{
		hub.clearOutput()
	}

	@objc(appendASCII:)
	func appendASCII( _ ascii: Int32 )
	{
		hub.appendASCII( ascii )
	}

	@objc(setUSOS:)
	func setUSOS( _ state: Bool )
	{
		hub.setUSOS( state )
	}
}
