//
//  Module.swift
//  cocoaModem
//
//  Created by Kok Chen on 9/3/05.
//  Swift port of Module.m.
//

import Cocoa

//  Implements AppleScript "module" class.

@objc(Module)
class Module: NSObject {

	//  text buffer sizes (from Module.h)
	private static let BUFMASK = 0xfff
	private static let BUFSIZE = 0xfff + 1

	private var parent: Transceiver!
	private var modem: Modem!
	private var isReceiverFlag: Bool = false
	private var index: Int32 = 0

	//  text buffer
	private let ptr = NSLock()
	private var producer: Int = 0
	private var consumer: Int = 0
	private var buffer = [CChar]( repeating: 0, count: Module.BUFSIZE )

	init( transceiver xcvr: Transceiver, receiver kind: Bool, index inIndex: Int32 )
	{
		super.init()
		index = inIndex
		parent = xcvr
		isReceiverFlag = kind
		modem = parent.modem()
		producer = 0
		consumer = 0
	}

	@objc func isReceiver() -> Bool
	{
		return isReceiverFlag
	}

	@objc func transceiver() -> Transceiver!
	{
		return parent
	}

	@objc(insertBuffer:)
	func insertBuffer( _ character: Int32 )
	{
		ptr.lock()
		let bIndex = producer & Module.BUFMASK
		buffer[ bIndex ] = CChar( truncatingIfNeeded: character )
		producer += 1
		ptr.unlock()
	}

	@objc func frequency() -> Float
	{
		return modem.frequency( for: self )
	}

	@objc(setFrequency:)
	func setFrequency( _ f: Float )
	{
		modem.setFrequency( f, module: self )
	}

	@objc(setReplay:)
	func setReplay( _ timeOffset: Float )
	{
		if isReceiverFlag { modem.setTimeOffset( timeOffset, index: index ) }
	}

	@objc func mark() -> Float
	{
		return modem.mark( for: self )
	}

	@objc(setMark:)
	func setMark( _ f: Float )
	{
		modem.setMark( f, module: self )
	}

	@objc func space() -> Float
	{
		return modem.space( for: self )
	}

	@objc(setSpace:)
	func setSpace( _ f: Float )
	{
		modem.setSpace( f, module: self )
	}

	@objc func baud() -> Float
	{
		return modem.baud( for: self )
	}

	@objc(setBaud:)
	func setBaud( _ f: Float )
	{
		modem.setBaud( f, module: self )
	}

	@objc func invert() -> Bool
	{
		return modem.invert( for: self )
	}

	@objc(setInvert:)
	func setInvert( _ state: Bool )
	{
		modem.setInvert( state, module: self )
	}

	@objc func breakin() -> Bool
	{
		return modem.breakin( for: self )
	}

	@objc(setBreakin:)
	func setBreakin( _ state: Bool )
	{
		modem.setBreakin( state, module: self )
	}

	@objc func stream() -> String?
	{
		//  quick check, without needing lock
		if producer == consumer { return "" }

		ptr.lock()
		if producer == consumer {
			//  the original returned here while still holding the lock (a latent, in
			//  practice unreachable path since producer only ever grows); unlock so we
			//  never deadlock a later call.
			ptr.unlock()
			return ""
		}
		var count = producer - consumer
		ptr.unlock()
		if count > 16 { count = 16 }

		var string = [CChar]( repeating: 0, count: 17 )
		var s = 0
		for _ in 0 ..< count {
			let idx = consumer & Module.BUFMASK
			consumer += 1
			let ch = Int( buffer[ idx ] ) & 0xff		//  mask to 8 bit ASCII
			if ch != 0 {
				string[ s ] = CChar( truncatingIfNeeded: ch )
				s += 1
			}
		}
		string[ s ] = 0
		if strlen( string ) == 0 { return "" }

		return string.withUnsafeBufferPointer { buf in
			NSString( cString: buf.baseAddress!, encoding: String.Encoding.isoLatin1.rawValue ) as String?
		}
	}

	@objc(setCStream:)
	func setCStream( _ text: UnsafeMutablePointer<CChar>? )
	{
		if isReceiverFlag { return }
		modem.transmitString( text )
	}

	@objc(setStream:)
	func setStream( _ text: String )
	{
		guard var cstr = text.cString( using: .isoLatin1 ) else { return }
		cstr.withUnsafeMutableBufferPointer { setCStream( $0.baseAddress ) }
	}

	@objc(flushText:)
	func flushText( _ command: NSScriptCommand? )
	{
		if isReceiverFlag {
			modem.flushClickBuffer()
			ptr.lock()
			producer = 0
			consumer = 0
			ptr.unlock()
			return
		}
		modem.flushAndLeaveTransmit()
	}

	//  we should get one buffer every 371.5 msec
	//  returns 1024 bytes (0-2756.25 Hz) or empty string if there is no data
	//	each byte represents pow( v, 0.25 )*5.52 (i.e., scaled square root of power).
	//	the value is 200 near full scale input,
	//	84 at -15 dB and 35.55 at -30 dB (i.e., about 30 dB per 5.62x)

	@objc func spectrum() -> String?
	{
		if !isReceiverFlag { return "" }

		guard let array = modem.waterfallBuffer( index ) else { return "" }

		var buf = [UInt8]( repeating: 0, count: 1025 )
		for i in 0 ..< 1024 {
			//  C truncates the double toward zero and takes the low 8 bits when
			//  storing into an unsigned char; guard the conversion like DisplayColor.cInt.
			let d = pow( Double( array[i] ), 0.25 ) * 5.52 + 0.5
			var t: Int32
			if d.isNaN { t = 0 }
			else if d >= 2147483647.0 { t = Int32.max }
			else if d <= -2147483648.0 { t = Int32.min }
			else { t = Int32( d.rounded( .towardZero ) ) }
			var p = UInt8( truncatingIfNeeded: t )
			if p <= 1 { p = 1 } else if p >= 254 { p = 254 }
			buf[i] = p
		}
		buf[1024] = 0
		return buf.withUnsafeBufferPointer { b -> String? in
			b.baseAddress!.withMemoryRebound( to: CChar.self, capacity: 1025 ) { cp in
				NSString( cString: cp, encoding: String.Encoding.isoLatin1.rawValue ) as String?
			}
		}
	}

	@objc func nextSpectrum() -> Int32
	{
		if !isReceiverFlag { return 1000000 }
		return modem.nextWaterfallScanline()
	}
}
