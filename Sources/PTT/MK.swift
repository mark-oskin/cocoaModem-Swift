//
//  MK.swift
//  cocoaPTT / cocoaModem 2.0
//
//  Created by Kok Chen on 4/4/06.
//  Swift port of microKEYER.m.
//  Copyright Kok Chen, W7AY. All rights reserved.
//

import Cocoa
import Darwin

@objc(MK)
class MK: PTTDevice {

	private var radioFlags: Int32 = 0

	//  the control byte is the second frame of a sequence, so we need to send a nop frame first
	private func sendControlByte( _ cmd: Int32 )
	{
		var nop: [UInt8] = [ 0x00, 0x80, 0x80, 0x80 ]

		write( fd, nop, 4 )
		nop[0] = ( ( cmd & 0x80 ) != 0 ) ? 0x41 : 0x40		// sequence flag and MSB of data
		nop[3] = UInt8( truncatingIfNeeded: cmd | 0x80 )	// 7 bit data witm MSB set
		write( fd, nop, 4 )
	}

	private func sendControl( _ array: [UInt8], length n: Int32 )
	{
		var i: Int32 = 0
		while i < n {
			sendControlByte( Int32( array[ Int( i ) ] ) )
			i += 1
		}
	}

	//  flag byte is the last byte of a radio frame
	private func sendFlagsToRadio( _ flags: Int32 )
	{
		var nop: [UInt8] = [ 0x28, 0x80, 0x80, 0x80 ]

		if ( flags & 0x80 ) != 0 { nop[0] |= 1 }
		nop[3] |= UInt8( truncatingIfNeeded: flags & 0xff )
		write( fd, nop, 4 )
	}

	private func readControl( _ buf: inout [UInt8], channel ch: inout [UInt8], maxlength length: Int32 ) -> Int32
	{
		var rbuf = [UInt8]( repeating: 0, count: 4 )

		var i = 0
		while true {
			let status = read( fd, &rbuf, 4 )
			if status != 4 { break }
			let channel = rbuf[0] & 0xfe
			if true /* || channel == 0x40 */ {
				ch[i] = channel
				buf[i] = ( rbuf[3] & 0x7f ) | ( ( ( rbuf[0] & 1 ) != 0 ) ? 0x80 : 0 )
				i += 1
				if i >= Int( length ) { break }
			}
		}
		return Int32( i )
	}

	private func transmitByte( _ v: Int32 )
	{
		let buf: [UInt8] = [ UInt8( truncatingIfNeeded: v ) ]

		write( fd, buf, 1 )
		usleep( 1000 )
	}

	private func downloadTest()
	{
		let reset: [UInt8] = [ 0x06, 0x86 ]
		var buf = [UInt8]( repeating: 0, count: 19 )
		var channel = [UInt8]( repeating: 0, count: 19 )
		var count: Int32

		//  reset device, this makes the bootloader wait for the 0x42 command
		sendControl( reset, length: 2 )
		usleep( 200000 )
		//  read reply
		count = readControl( &buf, channel: &channel, maxlength: 19 )
		if count == 2 && buf[0] == reset[0] && buf[1] == reset[1] {
			//  device is reset, waits for the start of download sequence
			transmitByte( 0x42 )						// start bootloader
			count = Int32( read( fd, &buf, 1 ) )		// get reply, expect 0x01 (started)
			if count > 0 && buf[0] == 1 {
				//  bootloader started
				transmitByte( 0x43 )					// get version
				count = Int32( read( fd, &buf, 9 ) )	// get reply, expect 0x02 and 8 data bytes
				if count == 9 && buf[0] == 2 {
					//  received version info
					print( String( format: "version: bootloader %d.%d product 0x%02x hardware %d mech %d\n",
						Int32( buf[2] & 0x7f ), Int32( buf[1] & 0x7f ), Int32( buf[3] & 0x7f ),
						Int32( buf[4] & 0x7f ), Int32( buf[5] & 0x7f ) ), terminator: "" )
				}
			}
		}
	}

	private func getVersion()
	{
		let vers: [UInt8] = [ 0x05, 0x85 ]
		var buf = [UInt8]( repeating: 0, count: 40 )
		var channel = [UInt8]( repeating: 0, count: 40 )
		var count: Int32

		//  reset device, this makes the bootloader wait for the 0x42 command
		sendControl( vers, length: 2 )
		usleep( 200000 )
		//  read reply
		count = readControl( &buf, channel: &channel, maxlength: 40 )
		var i: Int32 = 1
		while i < count {
			print( String( format: "%02x ", Int32( buf[ Int( i ) ] ) ), terminator: "" )
			i += 2
		}
		print( "" )
	}

	@objc(initWithDevice:name:)
	init?( device path: String, name stream: String )
	{
		super.init()

		streamName = stream
		radioFlags = 0
		fd = path.withCString { open( $0, O_WRONLY | O_NOCTTY | O_NDELAY ) }
		if fd >= 0 {

			if fcntl( fd, F_SETFL, 0 ) >= 0 {
				//  Get the current options and save them for later reset
				tcgetattr( fd, &originalTTYAttrs )
				//  These options are documented in the man page for termios
				//  (in Terminal enter: man termios)
				var options = originalTTYAttrs
				//  set device to 230400 baud, 8 bits no parity,one stop
				cfsetispeed( &options, speed_t( B230400 ) )
				cfsetospeed( &options, speed_t( B230400 ) )
				options.c_cflag = tcflag_t( CS8 | CREAD | CLOCAL )
				//  Set raw input, one second timeout
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

				tcgetattr( fd, &originalTTYAttrs )

				//  downloadTest()
				getVersion()
				return
			}
		}
		return nil
	}

	@objc(setKey:active:)
	override func setKey( _ rts: Int32, active pol: Bool ) -> Bool
	{
		radioFlags |= 0x4				//  PTT flag
		sendFlagsToRadio( radioFlags )
		return true
	}

	@objc(setUnkey:active:)
	override func setUnkey( _ rts: Int32, active pol: Bool ) -> Bool
	{
		radioFlags &= ~( 0x4 )			//  PTT flag
		sendFlagsToRadio( radioFlags )
		return true
	}
}
