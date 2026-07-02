//
//  PTTHub.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 5/11/06.
//  Swift port of PTTHub.m.
//

import Cocoa

@objc(PTTHub)
class PTTHub: KeyerInterface {

	//  PTTHub.h : kPTTItems (v0.89 allow 12(!) microKeyers)
	private static let kPTTItems = 16

	private var client = [PTT?]( repeating: nil, count: 64 )
	private var clients: Int32 = 0

	private var exist = [Bool]( repeating: false, count: PTTHub.kPTTItems )
	private var missingAlertMessage = [Bool]( repeating: false, count: PTTHub.kPTTItems )
	private var pttEngaged: Bool = false

	private var application: Application?
	private var digitalInterfaces: DigitalInterfaces?

	//  The PTT Hub handles all PTT requests from PTT objects.
	//	Each modem interface (TxConfig) has its own PTT object.  Each PTT object calls this hub when they get used.

	override init()
	{
		super.init()

		application = NSApp.delegate as? Application
		digitalInterfaces = application?.digitalInterfaces()

		//  catches SIGPIPE in case sleep wakeups don't reconnect.
		signal( SIGPIPE ) { _ in }

		//  all PTT objects that use PTTHub
		clients = 0
		pttEngaged = false

		//  make cocoaModem active even when other helper apps have been launched
		NSApp.activate( ignoringOtherApps: true )
	}

	@objc(registerPTT:)
	func register( _ ptt: PTT )
	{
		client[ Int( clients ) ] = ptt
		clients += 1
	}

	@objc(updateUserPTTScripts:)
	func updateUserPTTScripts( _ newFolder: String )
	{
		guard let digitalInterfaces = digitalInterfaces else { return }

		if digitalInterfaces.userPTTInterface().updateScripts( fromFolder: newFolder ) {
			let name = digitalInterfaces.userPTTInterface().folderName()
			for i in 0 ..< Int( clients ) { client[i]?.updateUserPTTName( name ) }
		}
		else {
			for i in 0 ..< Int( clients ) { client[i]?.updateUserPTTName( "User Defined" ) }
		}
	}

	//  called from a PTT device
	//	This issues an alert if a PTT device is missing but will do it just once
	@objc(missingPTT:name:)
	func missingPTT( _ index: Int32, name: String )
	{
		if missingAlertMessage[ Int( index ) ] { return }
		missingAlertMessage[ Int( index ) ] = true
		_ = Messages.alert( withMessageText: NSLocalizedString( "missing ptt", comment: "" ), informativeText: "PTT device \(name) is not found." )
	}

	//  set up the audio routing for the microKeyer v0.33, for digiKeyer v0.51
	//  v0.89  no longer used (original body was commented out)
	@objc(microKeyerSetupArray:count:useDigitalModeOnlyForFSK:)
	func microKeyerSetupArray( _ array: UnsafeMutablePointer<Int32>?, count: Int32, useDigitalModeOnlyForFSK digitalModeOnlyForFSK: Bool )
	{
	}
}
