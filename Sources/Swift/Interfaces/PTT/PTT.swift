//
//  PTT.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 5/11/06.
//  Swift port of PTT.m.
//  Copyright Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(PTT)
class PTT: NSObject {

	//  DIGI KEYER / microKEYER / CW KEYER menu titles (from PTT.m)
	private static let DKMENU = "DIGI KEYER"
	private static let MKMENU = "microKEYER"
	private static let CKMENU = "CW KEYER"

	//  constants formerly reached through PTTHub.h / DigitalInterfaces.h:
	//    kMicroKeyerGroup = 4   (PTTHub.h)
	//    kUserPTTIndex    = kUserPTTType = 3   (PTTHub.h / DigitalInterfaces.h)
	//    kPTTItems        = 16  (PTTHub.h)
	//    kMicroHAMType    = 4   (DigitalInterfaces.h)
	private static let kMicroKeyerGroup = 4
	private static let kUserPTTIndex = 3
	private static let kPTTItems = 16
	private static let kMicroHAMType: Int32 = 4

	private var hub: PTTHub!
	private var menu: NSPopUpButton!
	private var interfaces = [DigitalInterface?]( repeating: nil, count: 32 )
	private var dummyInterfaces = [DigitalInterface]()

	@objc(initWithHub:menu:)
	init( hub inHub: PTTHub, menu inMenu: NSPopUpButton )
	{
		super.init()
		menu = inMenu
		hub = inHub
		hub.register( self )
		dummyInterfaces = [DigitalInterface]()

		guard let digitalInterfaces = ( NSApp.delegate as? Application )?.digitalInterfaces() else { return }

		//	v0.89 -- set up PTT popup menu
		menu.removeAllItems()
		var n = 0

		var interface: DigitalInterface = digitalInterfaces.voxInterface()
		interfaces[n] = interface ; n += 1
		menu.insertItem( withTitle: interface.name(), at: 0 )

		interface = digitalInterfaces.cocoaPTTInterface()
		interfaces[n] = interface ; n += 1
		menu.insertItem( withTitle: interface.name(), at: 1 )

		interface = digitalInterfaces.macLoggerDX()
		interfaces[n] = interface ; n += 1
		menu.insertItem( withTitle: interface.name(), at: 2 )

		interface = digitalInterfaces.userPTTInterface()
		interfaces[n] = interface ; n += 1
		menu.insertItem( withTitle: interface.name(), at: 3 )

		let microKeyers = digitalInterfaces.microHAMKeyers()

		if microKeyers.count <= 0 {
			//  use old style menu
			interface = DigitalInterface( name: PTT.DKMENU )
			dummyInterfaces.append( interface )
			interfaces[n] = interface ; n += 1
			menu.insertItem( withTitle: interface.name(), at: PTT.kMicroKeyerGroup )

			interface = DigitalInterface( name: PTT.MKMENU )
			dummyInterfaces.append( interface )
			interfaces[n] = interface ; n += 1
			menu.insertItem( withTitle: interface.name(), at: PTT.kMicroKeyerGroup + 1 )

			interface = DigitalInterface( name: PTT.CKMENU )
			dummyInterfaces.append( interface )
			interfaces[n] = interface ; n += 1
			menu.insertItem( withTitle: interface.name(), at: PTT.kMicroKeyerGroup + 2 )
		}
		else {
			let cks = digitalInterfaces.numberOfCWKeyers()
			let mks = digitalInterfaces.numberOfMicroKeyers()
			let dks = digitalInterfaces.numberOfDigiKeyers()
			for i in 0 ..< microKeyers.count {
				let keyer = microKeyers[i]
				let name: String
				if keyer.isDigiKeyer() {
					name = ( dks > 1 ) ? String( format: "%@    %s", PTT.DKMENU, keyer.keyerID()! ) : PTT.DKMENU
				}
				else if keyer.isCWKeyer() {
					name = ( cks > 1 ) ? String( format: "%@      %s", PTT.CKMENU, keyer.keyerID()! ) : PTT.CKMENU
				}
				else {
					name = ( mks > 1 ) ? String( format: "%@   %s", PTT.MKMENU, keyer.keyerID()! ) : PTT.MKMENU
				}
				menu.insertItem( withTitle: name, at: PTT.kMicroKeyerGroup + i )
				interfaces[n] = keyer ; n += 1
			}
		}
		menu.selectItem( at: 0 )
		menu.action = #selector( menuChanged(_:) )	//  causes validateMenuItems to get called
		menu.target = self
	}

	@objc(menuChanged:)
	func menuChanged( _ sender: Any? )
	{
	}

	@objc func applicationTerminating()
	{
	}

	private func selectedInterface() -> DigitalInterface?
	{
		let index = menu.indexOfSelectedItem
		if index >= 0 {
			return interfaces[ index ]
		}
		return nil
	}

	//  v0.87 set keyer mode of a microHAM keyer
	@objc(setKeyerMode:)
	func setKeyerMode( _ mode: Int32 )
	{
		guard let interface = selectedInterface() else { return }
		if interface.type() != PTT.kMicroHAMType { return }
		( interface as? MicroKeyer )?.setKeyerMode( mode )
	}

	//  check if q-CW exists
	@objc func hasQCW() -> Bool
	{
		let interface = selectedInterface()
		if interface?.type() != PTT.kMicroHAMType { return false }
		return ( interface as? MicroKeyer )?.hasQCW() ?? false
	}

	@objc(updateUserPTTName:)
	func updateUserPTTName( _ name: String )
	{
		menu.item( at: PTT.kUserPTTIndex )?.title = name
	}

	@objc(executePTT:)
	func executePTT( _ state: Bool )
	{
		let index = menu.indexOfSelectedItem
		if index >= 0 {
			if let interface = interfaces[ index ] {
				interface.setPTTState( state )
			}
		}
	}

	@objc(selectItem:)
	func selectItem( _ pttName: String )
	{
		menu.selectItem( withTitle: pttName )
		let index = menu.indexOfSelectedItem
		if index >= 0 {
			if let interface = interfaces[ index ], interface.connected() {
				return
			}
		}
		hub.missingPTT( Int32( index ), name: pttName )
		//  select VOX instead
		menu.selectItem( at: 0 )
	}

	@objc func selectedItem() -> String?
	{
		return menu.titleOfSelectedItem
	}

	// NSMenuValidation for PTT menu
	@objc(validateMenuItem:)
	func validateMenuItem( _ item: NSMenuItem ) -> Bool
	{
		for i in 0 ..< PTT.kPTTItems {
			if item === menu.item( at: i ) {
				guard let interface = interfaces[ i ] else { return false }
				return interface.connected()
			}
		}
		return true
	}
}
