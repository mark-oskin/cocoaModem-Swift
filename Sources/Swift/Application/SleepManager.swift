//
//  SleepManager.swift
//  cocoaModem 2.0
//
//  Swift port of SleepManager.m (Kok Chen, 5/10/06).
//

import Foundation
import IOKit
import IOKit.pwr_mgt

//  Power messages from <IOKit/IOMessage.h>.
//  The kIOMessage... macros (iokit_common_msg values) are not importable into Swift,
//  so the constants are spelled out here:  sys_iokit | sub_iokit_common | code
private let kMessageSystemWillSleep = natural_t( 0xE0000280 )		//  kIOMessageSystemWillSleep
private let kMessageCanSystemSleep = natural_t( 0xE0000270 )		//  kIOMessageCanSystemSleep
private let kMessageSystemHasPoweredOn = natural_t( 0xE0000300 )	//  kIOMessageSystemHasPoweredOn

//  C callback registered with IORegisterForSystemPower.
//  refcon carries an unretained reference to the SleepManager instance,
//  exactly like the original Objective-C code which passed self unretained.
private func powerManagerCallback( _ refcon: UnsafeMutableRawPointer?, _ service: io_service_t, _ messageType: natural_t, _ message: UnsafeMutableRawPointer? )
{
	guard let refcon = refcon else { return }
	let ourself = Unmanaged<SleepManager>.fromOpaque( refcon ).takeUnretainedValue()

	switch messageType {
	case kMessageSystemWillSleep:
		ourself.aboutToSleep( Int( bitPattern: message ) )
	case kMessageCanSystemSleep:
		ourself.allowSleep( Int( bitPattern: message ) )
	case kMessageSystemHasPoweredOn:
		ourself.wakingFromSleep()
	default:
		break
	}
}

//  Base class for a generic power manager
//  Subclasses can override the messages -aboutToSleep: -allowSleep: and wakingFromSleep
@objc(SleepManager)
class SleepManager: NSObject {
	var powerManager: io_connect_t = 0
	var notifyPort: IONotificationPortRef?
	var notifier: io_object_t = 0

	override init()
	{
		super.init()
		//  accepts sleep and wakeup notifications from the power manager
		//  (self is passed unretained through the refcon, matching the original MRC code)
		powerManager = IORegisterForSystemPower( Unmanaged.passUnretained( self ).toOpaque(), &notifyPort, powerManagerCallback, &notifier )
		if powerManager != 0, let notifyPort = notifyPort {
			CFRunLoopAddSource( CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource( notifyPort ).takeUnretainedValue(), .commonModes )
		}
	}

	deinit
	{
		if powerManager != 0, let notifyPort = notifyPort {
			CFRunLoopRemoveSource( CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource( notifyPort ).takeUnretainedValue(), .commonModes )
			IODeregisterForSystemPower( &notifier )
			IOServiceClose( powerManager )
			IONotificationPortDestroy( notifyPort )
		}
	}

	//  -------------------------------------------------------------------------
	//  Local PowerManager support (for sleep and wakeups)
	//	Override these in subclasses to do something useful

	@objc func aboutToSleep( _ message: Int )
	{
		//  sleep any task that need to nap and sends allows power change
		IOAllowPowerChange( powerManager, message )
	}

	@objc func allowSleep( _ message: Int )
	{
		//  allows system to sleep
		IOAllowPowerChange( powerManager, message )
	}

	@objc func wakingFromSleep()
	{
		//  wake up tasks that were put to sleep
	}
}
