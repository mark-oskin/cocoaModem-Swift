//
//  PTTDevice.swift
//  cocoaPTT / cocoaModem 2.0
//
//  Created by Kok Chen on 4/4/06.
//  Swift port of PTTDevice.m.
//  Copyright Kok Chen, W7AY. All rights reserved.
//

import Cocoa
import Darwin

//  RigBlaster nomic wires OR both RTS and DTR together!
private func serialFlag(_ rts: Int32) -> Int32 {
	switch rts {
	case 0:
		return TIOCM_DTR
	case 2:
		return ( TIOCM_RTS | TIOCM_DTR )
	default:	//  includes case 1
		return TIOCM_RTS
	}
}

@objc(PTTDevice)
class PTTDevice: NSObject {

	//  ---- ivars (former Obj-C instance variables) ------------------------
	//  base ivars accessed by the MK subclass -> internal
	internal var fd: Int32 = -1
	internal var originalTTYAttrs = termios()
	internal var streamName: String?		//  -name selector returns this

	//  base ivars only used inside setKey/setUnkey -> private
	private var activeHigh: Bool = false
	private var useRTS: Bool = false

	//  plain designated init so the MK subclass can call super.init()
	//  (mirrors MK.m's `self = [super init]`, which reached NSObject's -init).
	override init()
	{
		super.init()
	}

	@objc(initWithDevice:name:allowRead:)
	init?( device path: String, name stream: String, allowRead: Bool )
	{
		super.init()

		streamName = stream
		if allowRead {
			fd = path.withCString { open( $0, O_NOCTTY | O_NDELAY ) }
		}
		else {
			fd = path.withCString { open( $0, O_WRONLY | O_NOCTTY | O_NDELAY ) }
		}
		if fd >= 0 {
			if fcntl( fd, F_SETFL, 0 ) >= 0 {
				//  Get the current options and save them for later reset
				tcgetattr( fd, &originalTTYAttrs )
				//  Set raw input, one second timeout
				//  These options are documented in the man page for termios
				//  (in Terminal enter: man termios)
				var options = originalTTYAttrs
				options.c_cflag |= tcflag_t( CLOCAL | CREAD )
				options.c_lflag &= ~tcflag_t( ICANON | ECHO | ECHOE | ISIG )
				options.c_oflag &= ~tcflag_t( OPOST )
				withUnsafeMutablePointer( to: &options.c_cc ) {
					$0.withMemoryRebound( to: cc_t.self, capacity: Int( NCCS ) ) {
						$0[ Int( VMIN ) ] = 0
						$0[ Int( VTIME ) ] = 10
					}
				}
				//  Set the options
				tcsetattr( fd, TCSANOW, &options )
				return
			}
		}
		return nil
	}

	@objc func name() -> String?
	{
		return streamName
	}

	@objc(setKey:active:)
	func setKey( _ rts: Int32, active pol: Bool ) -> Bool
	{
		var bits: Int32 = 0

		useRTS = ( rts != 0 )
		activeHigh = pol

		if fd >= 0 {
			ioctl( fd, UInt( TIOCMGET ), &bits )
			let flag = serialFlag( rts )
			if activeHigh {
				bits |= flag
			}
			else {
				bits &= ~flag
			}
			ioctl( fd, UInt( TIOCMSET ), &bits )
			return true
		}
		return false
	}

	@objc(setUnkey:active:)
	func setUnkey( _ rts: Int32, active pol: Bool ) -> Bool
	{
		var bits: Int32 = 0

		useRTS = ( rts != 0 )
		activeHigh = pol

		if fd >= 0 {
			ioctl( fd, UInt( TIOCMGET ), &bits )
			let flag = serialFlag( rts )
			if !activeHigh {
				bits |= flag
			}
			else {
				bits &= ~flag
			}
			ioctl( fd, UInt( TIOCMSET ), &bits )
			return true
		}
		return false
	}

	@objc func close()
	{
		if fd >= 0 { Darwin.close( fd ) }
		fd = 0
	}

	deinit
	{
		if fd >= 0 { Darwin.close( fd ) }
	}
}
