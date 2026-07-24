//
//  MicroKeyer.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/1/10.
//  Swift port of MicroKeyer.m.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(MicroKeyer)
class MicroKeyer: DigitalInterface {

	//  DigitalInterfaces.h : kMicroHAMType
	private static let kMicroHAMType: Int32 = 4

	//  RouterCommands.h constants used here (kept local, mirroring Router.swift so
	//  RouterCommands.h need not enter the bridging header)
	private static let ROUTERFUNCTION: Int32 = 0x80
	private static let KEYERFUNCTION: Int32 = 0x40
	private static let FUNCTIONMASK: Int32 = 0x1f
	private static let WRITEONLY: Int32 = 0x80
	private static let OPENCONTROL: Int32 = 0x40 + 0x03
	private static let OPENPTT: Int32 = 0x40 + 0x04
	private static let OPENFSK: Int32 = 0x40 + 0x07
	private static let OPENFLAGS: Int32 = 0x40 + 0x09
	private static let CLOSEKEYER: Int32 = 0x40 + 0x1f

	//  keyerID[16] -- stable C buffer so -keyerID can hand back a char*
	private let keyerIDBuffer = UnsafeMutablePointer<CChar>.allocate( capacity: 16 )

	//  descriptor ivars collide with same-named accessor methods; backing stores renamed
	private var pttWriteFd: Int32 = 0			//  was ivar pttWriteDescriptor
	private var controlWriteFd: Int32 = 0		//  was ivar controlWriteDescriptor
	private var readFileDescriptor: Int32 = 0
	private var writeFileDescriptor: Int32 = 0
	private var fskWriteFd: Int32 = 0			//  was ivar fskWriteDescriptor
	private var flagsReadFd: Int32 = 0			//  was ivar flagsReadDescriptor
	private var newStyle: Bool = false
	private var useDigitalModeForFSK: Bool = false

	private func finishInit()
	{
		interfaceType = MicroKeyer.kMicroHAMType
		useDigitalModeForFSK = false

		fskWriteFd = 0 ; flagsReadFd = 0 ; pttWriteFd = 0 ; controlWriteFd = 0
		//  obtain ports to keyer functions
		obtainRouterPorts( nil, &pttWriteFd, MicroKeyer.OPENPTT | MicroKeyer.WRITEONLY, readFileDescriptor, writeFileDescriptor )
		obtainRouterPorts( nil, &controlWriteFd, MicroKeyer.OPENCONTROL | MicroKeyer.WRITEONLY, readFileDescriptor, writeFileDescriptor )
		//  obtain ports for FSK if the keyer supports it
		if isMicroKeyer() || isDigiKeyer() {
			obtainRouterPorts( nil, &fskWriteFd, MicroKeyer.OPENFSK | MicroKeyer.WRITEONLY, readFileDescriptor, writeFileDescriptor )
			obtainRouterPorts( &flagsReadFd, nil, MicroKeyer.OPENFLAGS, readFileDescriptor, writeFileDescriptor )
		}
	}

	//  old (single keyer) µH Router
	@objc(initWithReadFileDescriptor:writeFileDescriptor:serialNumber:)
	init?( readFileDescriptor keyerReadFileDescriptor: Int32, writeFileDescriptor keyerWriteFileDescriptor: Int32, serialNumber dummySerial: UnsafeMutablePointer<CChar>? )
	{
		super.init( name: "" )
		keyerIDBuffer.initialize( repeating: 0, count: 16 )
		newStyle = false
		if let dummySerial = dummySerial { strcpy( keyerIDBuffer, dummySerial ) }
		readFileDescriptor = keyerReadFileDescriptor
		writeFileDescriptor = keyerWriteFileDescriptor
		finishInit()
	}

	//  new (multi keyer) µH Router
	@objc(initWithKeyerID:)
	init?( keyerID kid: UnsafeMutablePointer<CChar>? )
	{
		super.init( name: "" )
		keyerIDBuffer.initialize( repeating: 0, count: 16 )
		newStyle = true
		if let kid = kid { strcpy( keyerIDBuffer, kid ) }
		readFileDescriptor = 0
		writeFileDescriptor = 0
		//  open read/write ports to Router
		let routerRd = open( "/tmp/microHamRouterRead", O_RDONLY )
		let routerWr = open( "/tmp/microHamRouterWrite", O_WRONLY )
		if routerRd > 0 && routerWr > 0 {
			obtainKeyerPortsFromKeyerID( &readFileDescriptor, &writeFileDescriptor, kid, routerRd, routerWr )
			close( routerRd )
			close( routerWr )
			finishInit()
		}
	}

	deinit {
		let closeRequest = CChar( truncatingIfNeeded: MicroKeyer.CLOSEKEYER )
		if pttWriteFd > 0 { close( pttWriteFd ) }
		if controlWriteFd > 0 { close( controlWriteFd ) }
		if fskWriteFd > 0 { close( fskWriteFd ) }
		if flagsReadFd > 0 { close( flagsReadFd ) }
		var req = closeRequest
		write( writeFileDescriptor, &req, 1 )
		if readFileDescriptor > 0 { close( readFileDescriptor ) }
		if writeFileDescriptor > 0 { close( writeFileDescriptor ) }
		keyerIDBuffer.deallocate()
	}

	@objc func keyerTypeString() -> String
	{
		if isMicroKeyerI() { return "microKeyer" }
		if isMicroKeyerII() { return "microKeyer II" }
		if isDigiKeyerI() { return "digiKeyer" }
		if isDigiKeyerII() { return "digiKeyer II" }
		if isCWKeyer() { return "cwKeyer" }
		return "unknown microHAM keyer"
	}

	@objc override func hasFSK() -> Bool
	{
		return isDigiKeyer() || isMicroKeyer()
	}

	@objc override func connected() -> Bool
	{
		return true
	}

	private func isType( _ a: CChar, _ b: CChar ) -> Bool
	{
		return keyerIDBuffer[0] == a && keyerIDBuffer[1] == b
	}

	@objc func isMicroKeyer() -> Bool
	{
		return isType( 0x4D, 0x4B ) || isType( 0x4D, 0x32 )		//  "MK" || "M2"
	}

	@objc func isMicroKeyerI() -> Bool
	{
		return isType( 0x4D, 0x4B )								//  "MK"
	}

	@objc func isMicroKeyerII() -> Bool
	{
		return isType( 0x4D, 0x32 )								//  "M2"
	}

	@objc func isDigiKeyer() -> Bool
	{
		return isType( 0x44, 0x4B ) || isType( 0x44, 0x32 )		//  "DK" || "D2"
	}

	@objc func isDigiKeyerI() -> Bool
	{
		return isType( 0x44, 0x4B )								//  "DK"
	}

	@objc func isDigiKeyerII() -> Bool
	{
		return isType( 0x44, 0x32 )								//  "D2"
	}

	@objc func isCWKeyer() -> Bool
	{
		return isType( 0x43, 0x4B )								//  "CK"
	}

	@objc func keyerID() -> UnsafeMutablePointer<CChar>!
	{
		return keyerIDBuffer
	}

	@objc func flagsReadDescriptor() -> Int32
	{
		return flagsReadFd
	}

	@objc func fskWriteDescriptor() -> Int32
	{
		return fskWriteFd
	}

	@objc func controlWriteDescriptor() -> Int32
	{
		return controlWriteFd
	}

	@objc func pttWriteDescriptor() -> Int32
	{
		return pttWriteFd
	}

	@objc(setPTTState:)
	override func setPTTState( _ state: Bool )
	{
		var c: CChar = state ? 0x31 : 0x30				//  "1" : "0"
		write( pttWriteFd, &c, 1 )
	}

	@objc(useDigitalModeForFSK:)
	func useDigitalMode( forFSK state: Bool )
	{
		useDigitalModeForFSK = state
	}

	@objc(setKeyerMode:)
	func setKeyerMode( _ mode: Int32 )
	{
		var control: [UInt8] = [ 0x0f, 0x02, 0x00, 0x8f ]
		control[2] = UInt8( truncatingIfNeeded: mode )
		if controlWriteFd > 0 {
			_ = control.withUnsafeBufferPointer { write( controlWriteFd, $0.baseAddress, 4 ) }
		}
	}

	@objc func selectForFSK()
	{
		let control: [UInt8] = [ 0x0a, 0x03, 0x8a ]
		if useDigitalModeForFSK && ( isMicroKeyer() || isMicroKeyerII() || isDigiKeyer() || isDigiKeyerII() ) {
			_ = control.withUnsafeBufferPointer { write( controlWriteFd, $0.baseAddress, 3 ) }
		}
	}

	@objc func hasQCW() -> Bool
	{
		return isDigiKeyerII()
	}
}
