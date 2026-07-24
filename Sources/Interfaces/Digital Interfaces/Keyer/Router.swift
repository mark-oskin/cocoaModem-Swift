//
//  Router.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/21/08.
//  Swift port of Router.m.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//

import Cocoa
import IOKit
import IOKit.serial

//  This establishes the interface to the µH Router for the PTTHub and FSKHub

@objc(Router)
class Router: NSObject {

	//  RouterCommands.h master-port commands used here (ROUTERFUNCTION = 0x80):
	private static let OPENMICROKEYER: Int32 = 0x80 + 0x01
	private static let OPENCWKEYER: Int32 = 0x80 + 0x02
	private static let OPENDIGIKEYER: Int32 = 0x80 + 0x03
	private static let KEYERID: Int32 = 0x80 + 0x09

	private var isLaunched = false
	private var routerVersion: Float = 1.7
	private var keyers = [MicroKeyer]()			//  array of MicroKeyer objects

	//  Returns nil when the µH Router / a microHAM keyer is unavailable, exactly like
	//  the original -[Router init] which returned nil in that case.  (A labelled,
	//  failable initializer is used because Swift cannot make the inherited NSObject
	//  -init failable; Router is only ever created from DigitalInterfaces.)
	init?( startRouter: Bool )
	{
		super.init()
		isLaunched = false
		routerVersion = 1.7
		keyers = [MicroKeyer]()
		if !openRouter() { return nil }			//  this also creates keyers array
	}

	//  Find all serial ports on the computer
	//  collect the stream name and the Unix device path name for each one and return the number that is found
	private func findPorts( max maxCount: Int ) -> ( paths: [String], streams: [String] )
	{
		var paths = [String]()
		var streams = [String]()

		var masterPort: mach_port_t = 0
		var kernResult = IOMasterPort( 0, &masterPort )
		if kernResult != KERN_SUCCESS { return ( paths, streams ) }

		guard let classesToMatch = IOServiceMatching( kIOSerialBSDServiceValue ) else { return ( paths, streams ) }

		// get iterator for serial ports (ignore modems)
		( classesToMatch as NSMutableDictionary )[ kIOSerialBSDTypeKey ] = kIOSerialBSDRS232Type

		var serialPortIterator: io_iterator_t = 0
		kernResult = IOServiceGetMatchingServices( masterPort, classesToMatch, &serialPortIterator )
		_ = kernResult

		// walk through the iterator
		var count = 0
		var modemService = IOIteratorNext( serialPortIterator )
		while modemService != 0 && count < maxCount {
			if let streamRef = IORegistryEntryCreateCFProperty( modemService, kIOTTYDeviceKey as CFString, kCFAllocatorDefault, 0 ),
			   let streamName = streamRef.takeRetainedValue() as? String {
				if let pathRef = IORegistryEntryCreateCFProperty( modemService, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0 ),
				   let pathName = pathRef.takeRetainedValue() as? String {
					streams.append( streamName )
					paths.append( pathName )
					count += 1
				}
			}
			IOObjectRelease( modemService )
			modemService = IOIteratorNext( serialPortIterator )
		}
		IOObjectRelease( serialPortIterator )
		return ( paths, streams )
	}

	//	v0.89
	private func makeListOfKeyers()
	{
		keyers.removeAll()
		//  open read/write ports to Router
		let routerRd = open( "/tmp/microHamRouterRead", O_RDONLY )
		let routerWr = open( "/tmp/microHamRouterWrite", O_WRONLY )
		if routerRd > 0 && routerWr > 0 {

			if routerVersion > 1.79 {
				//  new µH Router
				var request = [CChar]( repeating: 0, count: 2 )
				var response = [CChar]( repeating: 0, count: 21 )
				for i in 0 ..< 16 {
					request[0] = CChar( truncatingIfNeeded: Router.KEYERID )
					request[1] = CChar( truncatingIfNeeded: i )
					response[0] = 0
					_ = request.withUnsafeBufferPointer { write( routerWr, $0.baseAddress, 2 ) }
					_ = response.withUnsafeMutableBufferPointer { read( routerRd, $0.baseAddress, 20 ) }
					if response[0] == 0 { break }
					if let keyer = response.withUnsafeMutableBufferPointer( { MicroKeyer( keyerID: $0.baseAddress ) } ) {
						keyers.append( keyer )						//  v0.92 sanity check
					}
				}
			}
			else {
				//  try opening the three keyers
				//  if present, also open the PTT port to them v0.33
				let openCommand: [Int32] = [ Router.OPENMICROKEYER, Router.OPENCWKEYER, Router.OPENDIGIKEYER ]
				let dummySerial = [ "MK", "CK", "DK" ]
				for i in 0 ..< 3 {
					//  open a keyer (old style)
					var keyerReadFileDescriptor: Int32 = 0
					var keyerWriteFileDescriptor: Int32 = 0
					obtainRouterPorts( &keyerReadFileDescriptor, &keyerWriteFileDescriptor, openCommand[i], routerRd, routerWr )
					if keyerReadFileDescriptor > 0 && keyerWriteFileDescriptor > 0 {
						var serial = Array( dummySerial[i].utf8CString )
						if let keyer = serial.withUnsafeMutableBufferPointer( { MicroKeyer( readFileDescriptor: keyerReadFileDescriptor, writeFileDescriptor: keyerWriteFileDescriptor, serialNumber: $0.baseAddress ) } ) {
							keyers.append( keyer )					//  v0.92 sanity check
						}
					}
				}
			}
		}
		close( routerRd )
		close( routerWr )
	}

	private func openRouter() -> Bool
	{
		isLaunched = false
		//  check for existence of µH Router
		let workspace = NSWorkspace.shared
		guard workspace.absolutePathForApplication( withBundleIdentifier: "w7ay.mh Router" ) != nil else { return false }

		//  check for microHam devices among the serial ports
		//  don't bother with launching the Router app otherwise
		var hasKeyer = false
		let ( _, streams ) = findPorts( max: 32 )
		let ports = streams.count
		var cstring = [CChar]( repeating: 0, count: 16 )
		for i in 0 ..< ports {
			let stream = streams[i] as NSString
			let name = ( stream.length < 13 ) ? "" : stream.substring( to: 12 )
			for k in 0 ..< 16 { cstring[k] = 0 }
			if let cs = name.cString( using: .isoLatin1 ) {
				let cnt = min( cs.count, 16 )
				for k in 0 ..< cnt { cstring[k] = cs[k] }
			}
			cstring[10] = 0x4D	//  'M' -- change usbserial-DK and usbserial-CK to MK
			let matched = cstring.withUnsafeBufferPointer { ptr -> Bool in
				return strcmp( ptr.baseAddress, "usbserial-MK" ) == 0 || strcmp( ptr.baseAddress, "usbserial-M2" ) == 0
			}
			if matched { hasKeyer = true }
		}
		if hasKeyer {
			isLaunched = launch()
			if isLaunched {
				//  v0.89
				if let routerVersionScript = loadScriptFor( "routerVersion" ) {
					var event: NSAppleEventDescriptor?
					if executeScript( routerVersionScript, reply: &event ) != nil {
						if let event = event, let response = event.stringValue {
							parseVersion( response )
						}
					}
					makeListOfKeyers()
				}
			}
			return true
		}
		return false
	}

	//  sscanf( response, "%f", &version )
	private func parseVersion( _ response: String )
	{
		guard let cs = response.cString( using: .isoLatin1 ) else { return }
		cs.withUnsafeBufferPointer { buf in
			guard let base = buf.baseAddress else { return }
			var end: UnsafeMutablePointer<CChar>? = nil
			let v = strtof( base, &end )
			if end != UnsafeMutablePointer( mutating: base ) { routerVersion = v }
		}
	}

	@objc func version() -> Float
	{
		return routerVersion
	}

	//	return array of MicroKeyer objects
	@objc func connectedKeyers() -> [MicroKeyer]
	{
		return keyers
	}

	private func launch() -> Bool
	{
		//  start up Router by using AppleScript and asking for a parameter
		//  Use AppleScript instead of NSWorkspace to guarantee router is running
		guard let launchScript = loadScriptFor( "routerLaunchScript" ) else { return false }
		if executeScript( launchScript, withError: "router launch" ) != nil {
			return true
		}
		return false
	}

	@objc func launched() -> Bool
	{
		return isLaunched
	}

	private func releaseKeyers()
	{
		keyers.removeAll()
	}

	//  v0.66  user router script when cocoaModem quits
	//  if defined, this is run instead of closeRouter
	@objc(runQuitScript:)
	func runQuitScript( _ filename: String )
	{
		if !isLaunched { /* never launched */ return }

		releaseKeyers()
		if let microhamRouterQuitScript = loadScriptForPath( filename ) {
			executeScript( microhamRouterQuitScript, withError: "microhamRouter" )
		}
	}

	@objc func closeRouter()
	{
		releaseKeyers()
		if let microhamRouterQuitScript = loadScriptFor( "routerCloseScript" ) {
			executeScript( microhamRouterQuitScript, withError: "microhamRouter" )
		}
	}

	private func loadScriptForPath( _ path: String, withErrorDictionary dict: inout NSDictionary? ) -> NSAppleScript?
	{
		if path.count > 0 {
			let url = URL( fileURLWithPath: path )
			if !url.isFileURL { return nil }
			guard let script = NSAppleScript( contentsOf: url, error: &dict ) else {
				path.withCString { Messages.appleScriptError( dict as? [AnyHashable: Any], script: $0 ) }
				return nil
			}
			return script
		}
		return nil
	}

	//  load a script file with an arbitrary path name
	private func loadScriptForPath( _ path: String ) -> NSAppleScript?
	{
		var dict: NSDictionary?
		return loadScriptForPath( path, withErrorDictionary: &dict )
	}

	private func loadScriptFor( _ scptFile: String, withErrorDictionary dict: inout NSDictionary? ) -> NSAppleScript?
	{
		let path = Bundle.main.path( forResource: scptFile, ofType: "scpt" )
		return loadScriptForPath( path ?? "", withErrorDictionary: &dict )
	}

	//  load a script file from the Application bundle
	private func loadScriptFor( _ scptFile: String ) -> NSAppleScript?
	{
		var dict: NSDictionary?
		return loadScriptFor( scptFile, withErrorDictionary: &dict )
	}

	//  return the script back if succeded, return nil if failed
	@discardableResult
	private func executeScript( _ script: NSAppleScript, withError msg: String ) -> NSAppleScript?
	{
		var err: NSDictionary?
		script.executeAndReturnError( &err )
		if err == nil {
			return script
		}
		// AppleScript error
		msg.withCString { Messages.appleScriptError( err as? [AnyHashable: Any], script: $0 ) }
		return nil
	}

	//  return the script back if succeded, return nil if failed
	private func executeScript( _ script: NSAppleScript, reply event: inout NSAppleEventDescriptor? ) -> NSAppleScript?
	{
		var err: NSDictionary?
		event = script.executeAndReturnError( &err )
		if err == nil {
			return script
		}
		return nil
	}
}
