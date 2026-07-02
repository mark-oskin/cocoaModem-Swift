//
//  ModemSleepManager.swift
//  cocoaModem 2.0
//
//  Swift port of ModemSleepManager.m (Kok Chen, 5/10/06).
//

import Foundation
import IOKit.pwr_mgt

@objc(ModemSleepManager)
class ModemSleepManager: SleepManager {
	//  unretained back pointer to the Application (matches the original MRC assign)
	private unowned(unsafe) let client: Application

	@objc(initWithApplication:)
	init( application app: Application )
	{
		client = app
		super.init()
	}

	override func allowSleep( _ message: Int )
	{
		//  allows system to sleep
		IOCancelPowerChange( powerManager, message )
	}

	override func aboutToSleep( _ message: Int )
	{
		//  note, we cannot cancel sleep from a here
		client.putCodecsToSleep()
		super.aboutToSleep( message )
	}

	override func wakingFromSleep()
	{
		//  wake up everybody that were put to sleep
		client.wakeCodecsUp()
	}
}
