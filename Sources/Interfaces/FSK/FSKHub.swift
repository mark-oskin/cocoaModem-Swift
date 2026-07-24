//
//  FSKHub.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/11/08.
//  Swift port of FSKHub.m.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(FSKHub)
class FSKHub: KeyerInterface {

	//  FSKHub.h shift states / masks (were file-scope in FSKHub.h)
	private static let kLTRSshift: Int32 = 0
	private static let kFIGSshift: Int32 = 1
	private static let LTRSMASK: Int32 = 0x100
	private static let FIGSMASK: Int32 = 0x200

	//  FSKHub.m file-scope constants and tables
	private static let CMFIGSCODE: UInt8 = 0x1b
	private static let CMLTRSCODE: UInt8 = 0x1f
	private static let kRobustThreshold: Int32 = 16

	private static let CMLtrs: [CChar] = Array( "*E*A SIU*DRJNFCKTZLWHYPQOBG*MXV*".unicodeScalars ).map { CChar( bitPattern: UInt8( $0.value ) ) }
	private static let CMFigs: [CChar] = Array( "*3\n- *87*$4*,!:(5\")2#6019?&*./;*".unicodeScalars ).map { CChar( bitPattern: UInt8( $0.value ) ) }
	private static let stopMask: [Int32] = [ /* 1 stop */ 0x0, /* 1.5 stops */ 0x8, /* 2 stops */ 0x4, /* default */ 0x8 ]

	private var fskBusy = false

	private var currentFd: Int32 = 0
	private var shift: Int32 = FSKHub.kLTRSshift
	//  the following are for polling flags channel
	private var selectSet = fd_set()
	private var readSet = fd_set()
	private var tempBuffer = [UInt8]( repeating: 0, count: 64 )

	private var selectCount: Int32 = 0
	private var closed = false
	private var running = false
	private var modem: RTTY?
	private var usos = false

	// ring buffer
	private var fskBuffer = [UInt8]( repeating: 0, count: 4096 )		//  ascii ring buffer
	private var producer: Int32 = 0
	private var consumer: Int32 = 0
	private var baudot = [Int32]( repeating: 0, count: 256 )

	//  currentBaudotCharacter ivar collides with the -currentBaudotCharacter method; backing store renamed
	private var currentBaudotChar: Int32 = 0
	private var robust = false											//  v0.88 USOS "compatibility mode"
	private var spaceFollowedFIGS = false								//  use robust mode to force compatibility of figs followed by space
	private var implicitState: Int32 = 0
	private var robustCount: Int32 = 0

	//	(Private API)
	//  set up FSK ports to the Router
	private func setupMicrohamRouter()
	{
		router = ( NSApp.delegate as? Application )?.digitalInterfaces()?.router()
		guard let router = router else { return }

		let keyers = router.connectedKeyers()
		let n = keyers.count

		//  set up listener for read ports
		selectCount = 0
		activeKeyers = 0
		for i in 0 ..< n {
			let keyer = keyers[i]
			let fskFd = keyer.fskWriteDescriptor()
			if fskFd > 0 {
				let idx = Int( activeKeyers )
				microKeyerCache[idx].keyer = keyer
				microKeyerCache[idx].fskPort = fskFd
				microKeyerCache[idx].controlPort = keyer.controlWriteDescriptor()
				let flagsFd = keyer.flagsReadDescriptor()
				if flagsFd > 0 {
					fdSet( flagsFd, &selectSet )
					microKeyerCache[idx].flagsPort = flagsFd
					if flagsFd > selectCount { selectCount = flagsFd }
				}
				activeKeyers += 1
			}
		}
		if selectCount > 0 {
			//  create thread to listen to flags
			Thread.detachNewThreadSelector( #selector( pollThread ), toTarget: self, with: nil )
		}
	}

	override init()
	{
		super.init()
		usos = true							//  v0.84
		fskBusy = false
		currentFd = 0
		selectCount = 0
		shift = FSKHub.kLTRSshift
		closed = false
		running = false
		producer = 0
		consumer = 0
		currentBaudotChar = Int32( FSKHub.CMLTRSCODE )	//  v0.88 feedback to aural monitor
		robust = false						//  v0.88 USOS "compatibility mode"
		spaceFollowedFIGS = false
		robustCount = 0

		modem = nil

		//  initialize Baudot table with spaces
		for i in 0 ..< 256 { baudot[i] = 0x04 + FSKHub.LTRSMASK + FSKHub.FIGSMASK }

		for i in 0 ..< 32 {
			let ch = Int( FSKHub.CMLtrs[i] ) & 0x7f
			var encoded: Int
			switch ch {
			case 0x2a, 0x0a, 0x0d:			//  '*', '\n', '\r'
				encoded = 0
			default:
				encoded = ch
			}
			if encoded > 0 {
				baudot[ encoded ] = Int32( i & 0x1f ) + FSKHub.LTRSMASK
				if encoded >= 0x41 && encoded <= 0x5a {		//  'A' ... 'Z'
					baudot[ encoded - 0x41 + 0x61 ] = Int32( i & 0x1f ) + FSKHub.LTRSMASK
				}
			}
		}
		for i in 0 ..< 32 {
			let ch = Int( FSKHub.CMFigs[i] ) & 0x7f
			var encoded: Int
			switch ch {
			case 0x2a, 0x0a, 0x0d:			//  '*', '\n', '\r'
				encoded = 0
			default:
				encoded = ch
			}
			if encoded > 0 { baudot[ encoded ] = Int32( i & 0x1f ) + FSKHub.FIGSMASK }
		}
		baudot[ 0x20 ] = 0x04 + FSKHub.LTRSMASK + FSKHub.FIGSMASK		//  ' '
		baudot[ 0x0a ] = 0x02 + FSKHub.LTRSMASK + FSKHub.FIGSMASK
		baudot[ 0x0d ] = 0x08 + FSKHub.LTRSMASK + FSKHub.FIGSMASK
		baudot[ 0x27 ] = 0x05 + FSKHub.FIGSMASK							//  '\''

		fdZero( &selectSet )
		setupMicrohamRouter()

		//  make cocoaModem active even when other helper apps are launched
		NSApp.activate( ignoringOtherApps: true )
	}

	//  v0.84
	@objc(setUSOS:)
	func setUSOS( _ state: Bool )
	{
		usos = state
	}

	@objc func closeFSKConnections()
	{
		closed = true
		running = false

		//  close µH Router ports
		if router != nil {
			for i in 0 ..< Int( activeKeyers ) {
				microKeyerCache[i].fskPort = 0
				microKeyerCache[i].controlPort = 0
				if microKeyerCache[i].flagsPort > 0 {
					//  send a character to the flags FIFO to kill the thread
					let dummy: [UInt8] = [ 0, 0 ]
					_ = dummy.withUnsafeBufferPointer { write( microKeyerCache[i].flagsPort, $0.baseAddress, 1 ) }
					microKeyerCache[i].flagsPort = 0
				}
			}
			Thread.sleep( forTimeInterval: 0.1 )
		}
	}

	@objc func digiKeyerFSKPort() -> Int32
	{
		for i in 0 ..< Int( activeKeyers ) {
			if let keyer = microKeyerCache[i].keyer, keyer.isDigiKeyer() { return microKeyerCache[i].fskPort }
		}
		return 0
	}

	@objc func microKeyerFSKPort() -> Int32
	{
		for i in 0 ..< Int( activeKeyers ) {
			if let keyer = microKeyerCache[i].keyer, keyer.isMicroKeyer() { return microKeyerCache[i].fskPort }
		}
		return 0
	}

	//	v0.87
	@objc override func digiKeyerControlPort() -> Int32
	{
		for i in 0 ..< Int( activeKeyers ) {
			if let keyer = microKeyerCache[i].keyer, keyer.isDigiKeyer() { return microKeyerCache[i].controlPort }
		}
		return 0
	}

	//	v0.87
	@objc override func microKeyerControlPort() -> Int32
	{
		for i in 0 ..< Int( activeKeyers ) {
			if let keyer = microKeyerCache[i].keyer, keyer.isMicroKeyer() { return microKeyerCache[i].controlPort }
		}
		return 0
	}

	//  streams

	private func sendLTRS()
	{
		let buf: [UInt8] = [ FSKHub.CMLTRSCODE, 0 ]
		setCurrentBaudotCharacter( Int32( FSKHub.CMLTRSCODE ) )		//  v0.88 set character for aural monitor
		_ = buf.withUnsafeBufferPointer { write( currentFd, $0.baseAddress, 1 ) }
		shift = FSKHub.kLTRSshift
		robustCount = 0
	}

	private func sendFIGS()
	{
		let buf: [UInt8] = [ FSKHub.CMFIGSCODE, 0 ]
		setCurrentBaudotCharacter( Int32( FSKHub.CMFIGSCODE ) )		//  v0.88 set character for aural monitor
		_ = buf.withUnsafeBufferPointer { write( currentFd, $0.baseAddress, 1 ) }
		shift = FSKHub.kFIGSshift
		robustCount = 0
	}

	//  unmap phi to zero
	private static func unmap( _ d: Int32 ) -> Int32
	{
		if d == 216 || d == 175 { return 0x30 }		//  '0'
		return d & 0x7f
	}

	//  v0.88 -- an approximation of the most recent character that was sent
	@objc func currentBaudotCharacter() -> Int32
	{
		return currentBaudotChar
	}

	//  v0.88 feedback to aural monitor
	@objc(setCurrentBaudotCharacter:)
	func setCurrentBaudotCharacter( _ c: Int32 )
	{
		currentBaudotChar = c
	}

	//  v0.88 USOS "compatibility mode"
	@objc(setRobustMode:)
	func setRobustMode( _ state: Bool )
	{
		robust = state
		robustCount = 0
	}

	private func sendNextBaudotCharacter( _ index: Int32 )
	{
		if currentFd <= 0 || running == false { return }

		if producer == consumer {
			//  no new characters, send LTRS as diddle
			sendLTRS()
			return
		}

		let ascii = Int32( fskBuffer[ Int( consumer & 0x7ff ) ] )
		if let modem = modem { modem.transmittedCharacter( ascii ) }

		if ascii == 0x5 { return }

		consumer = ( consumer + 1 ) & 0x7ff

		let bchar = baudot[ Int( FSKHub.unmap( ascii & 0xff ) & 0x7f ) ]

		if spaceFollowedFIGS {
			if robust {
				//  check if we need to force a LTRS shift (for USOS) or FIGS shift (for non-USOS)
				if usos {
					//  transmitting with USOS, check for the case "1<space>A"
					if ( bchar & FSKHub.FIGSMASK ) == 0 { sendLTRS() }	// current character is not FIGS, force a LTRS out in USOS
				}
				else {
					//  transmitting with non-USOS, check for the case "1<space>2"
					if ( bchar & FSKHub.LTRSMASK ) == 0 { sendFIGS() }	// current character is not LTRS, force a FIGS out in USOS
				}
			}
			spaceFollowedFIGS = false
		}

		if shift == FSKHub.kLTRSshift {
			//  changing from LTRS to FIGS
			if ( bchar & FSKHub.LTRSMASK ) == 0 { sendFIGS() }
		}
		else {
			//  changing from FIGS to LTRS
			if ( bchar & FSKHub.FIGSMASK ) == 0 { sendLTRS() }
		}

		//	send character now
		let buf: [UInt8] = [ UInt8( truncatingIfNeeded: bchar & 0x1f ), 0 ]
		setCurrentBaudotCharacter( Int32( buf[0] ) )								//  v0.88 feedback to aural monitor
		_ = buf.withUnsafeBufferPointer { write( currentFd, $0.baseAddress, 1 ) }
		robustCount += 1															//  v0.88 added robust mode to FSK

		spaceFollowedFIGS = false
		//  v0.84 bug fix: change shift to LTRS if USOS is on
		if ascii == 0x20 {		//  ' '
			if shift == FSKHub.kFIGSshift { spaceFollowedFIGS = true }			//  v0.88 for USOS compatibility
			if usos {
				//  note: no explicit LTRS character is sent
				shift = FSKHub.kLTRSshift
			}
		}
		if robustCount > FSKHub.kRobustThreshold {									//  v0.88 robust mode
			if shift == FSKHub.kLTRSshift { sendLTRS() }
			if shift == FSKHub.kFIGSshift { sendFIGS() }
		}
	}

	//  thread to poll for flag changes
	@objc private func pollThread()
	{
		autoreleasepool {
			//  Start polling.  select() blocks until one or more file descriptors has data
			while true {
				if closed { break }
				//  poll the full set
				readSet = selectSet									//  FD_COPY
				var count = select( selectCount + 1, &readSet, nil, nil, nil )

				if count < 0 { break }		//  abort polling when an error is seen
				if count > 0 {
					for i in 0 ..< Int( activeKeyers ) {
						let fd = microKeyerCache[i].flagsPort
						if fd > 0 {
							if fdIsSet( fd, &readSet ) {
								let bytes = tempBuffer.withUnsafeMutableBufferPointer { read( fd, $0.baseAddress, 1 ) }
								if bytes == 1 && ( tempBuffer[0] & 0x20 ) == 0 {
									sendNextBaudotCharacter( Int32( i ) )
								}
								count -= 1
							}
						}
					}
					//  sanity check -- clear everything fd if count not zero
					if count > 0 {
						var fd: Int32 = 0
						while fd < 1024 {			//  FD_SETSIZE
							if fdIsSet( fd, &readSet ) {
								_ = tempBuffer.withUnsafeMutableBufferPointer { read( fd, $0.baseAddress, 64 ) }
							}
							fd += 1
						}
					}
				}
			}
		}
	}

	//  start is delayed to allow a steady mark tone that is at least a character long after PTT is engaged
	//  This makes sure the first character prints correctly.
	@objc(delayedStart:)
	private func delayedStart( _ timer: Timer )
	{
		running = true
		sendLTRS()		//  fires off the stream
		fskBusy = true
	}

	private func setupBaudRate( _ rate: Int32, invertFSK: Bool, stopIndex: Int32, keyerCache: MicroHamKeyerCache )
	{
		guard router != nil else { return }
		guard let keyer = keyerCache.keyer else { return }

		let controlWrite = keyer.controlWriteDescriptor()
		if controlWrite > 0 {
			var buf = [UInt8]( repeating: 0, count: 32 )
			//  baud rate
			buf[0] = 0x03
			buf[1] = UInt8( truncatingIfNeeded: rate & 0xff )
			buf[2] = UInt8( truncatingIfNeeded: ( rate / 256 ) & 0xff )
			buf[3] = UInt8( truncatingIfNeeded: FSKHub.stopMask[ Int( stopIndex & 0x3 ) ] )	//  stop bits
			buf[4] = 0x83
			_ = buf.withUnsafeBufferPointer { write( controlWrite, $0.baseAddress, 5 ) }
			Thread.sleep( forTimeInterval: 0.01 )
			//  set digital keyer mode v0.68
			buf[0] = 0x0a
			buf[1] = 0x03
			buf[2] = 0x8a
			_ = buf.withUnsafeBufferPointer { write( controlWrite, $0.baseAddress, 3 ) }
			Thread.sleep( forTimeInterval: 0.01 )
			//  invert FSK v0.68 (use the special 0f..8f backdoor in µH Router)
			buf[0] = 0x0f
			buf[1] = 0x01
			buf[2] = invertFSK ? 1 : 0
			buf[3] = 0x8f
			_ = buf.withUnsafeBufferPointer { write( controlWrite, $0.baseAddress, 4 ) }
			Thread.sleep( forTimeInterval: 0.01 )
		}
	}

	@objc(startSampling:baudRate:invert:stopBits:modem:)
	func startSampling( _ fd: Int32, baudRate baudRateIn: Float, invert invertTx: Bool, stopBits stopIndex: Int32, modem inModem: RTTY )
	{
		var baudRate = baudRateIn

		if fskBusy { stopSampling() }

		currentFd = fd
		if fd > 0 {
			var i = 0
			while i < Int( activeKeyers ) {
				if fd == microKeyerCache[i].fskPort { break }
				i += 1
			}
			if i >= Int( activeKeyers ) { return }		//  fd not found

			//  check and set baud rate
			if baudRate < 10 { baudRate = 10 }
			let rate = Int32( 2700.0 / baudRate + 0.5 )

			modem = inModem

			let invInt: Int32 = invertTx ? 1 : 0
			if rate != microKeyerCache[i].currentBaudConstant || invInt != microKeyerCache[i].currentTxInvert || stopIndex != microKeyerCache[i].currentStopIndex {
				setupBaudRate( rate, invertFSK: invertTx, stopIndex: stopIndex, keyerCache: microKeyerCache[i] )
			}
			microKeyerCache[i].currentBaudConstant = rate
			microKeyerCache[i].currentTxInvert = invInt
			microKeyerCache[i].currentStopIndex = stopIndex

			producer = 0
			consumer = 0
			Timer.scheduledTimer( timeInterval: 0.18, target: self, selector: #selector( delayedStart(_:) ), userInfo: self, repeats: false )
		}
	}

	@objc func stopSampling()
	{
		running = false
		fskBusy = false
		modem = nil
	}

	@objc func clearOutput()
	{
		producer = 0
		consumer = 0
	}

	@objc(appendASCII:)
	func appendASCII( _ ascii: Int32 )
	{
		let next = ( producer + 1 ) & 0x7ff
		if next == consumer { return }

		fskBuffer[ Int( producer & 0x7ff ) ] = UInt8( truncatingIfNeeded: ascii )
		producer = next
	}

	//  MARK: fd_set helpers (Swift has no FD_ZERO/FD_SET/FD_ISSET macros)

	private func fdZero( _ set: inout fd_set )
	{
		withUnsafeMutableBytes( of: &set ) { raw in
			raw.bindMemory( to: Int32.self ).update( repeating: 0 )
		}
	}

	private func fdSet( _ fd: Int32, _ set: inout fd_set )
	{
		let intOffset = Int( fd ) / 32
		let bitOffset = Int( fd ) % 32
		withUnsafeMutableBytes( of: &set ) { raw in
			let bits = raw.bindMemory( to: Int32.self )
			bits[ intOffset ] |= Int32( bitPattern: UInt32( 1 ) << UInt32( bitOffset ) )
		}
	}

	private func fdIsSet( _ fd: Int32, _ set: inout fd_set ) -> Bool
	{
		let intOffset = Int( fd ) / 32
		let bitOffset = Int( fd ) % 32
		return withUnsafeMutableBytes( of: &set ) { raw -> Bool in
			let bits = raw.bindMemory( to: Int32.self )
			return ( bits[ intOffset ] & Int32( bitPattern: UInt32( 1 ) << UInt32( bitOffset ) ) ) != 0
		}
	}
}
