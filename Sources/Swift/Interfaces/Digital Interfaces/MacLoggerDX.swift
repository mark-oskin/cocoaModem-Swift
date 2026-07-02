//
//  MacLoggerDX.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/17/11.
//  Swift port of MacLoggerDX.m.
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(MacLoggerDX)
class MacLoggerDX: DigitalInterface {

	//  DigitalInterfaces.h : kMLDXType
	private static let kMLDXType: Int32 = 2

	private var keyScript: NSAppleScript?
	private var unkeyScript: NSAppleScript?

	@objc(initWithName:)
	override init( name vname: String )
	{
		super.init( name: vname )
		interfaceType = MacLoggerDX.kMLDXType
		keyScript = nil
		unkeyScript = nil
		//  first check for existence of MacLoggerDX
		if NSWorkspace.shared.fullPath( forApplication: "MacLoggerDX" ) != nil {
			var isv5 = false

			if let mldxVersionScript = loadScriptFor( "mldxVersion" ) {
				var event: NSAppleEventDescriptor?
				if executeScript( mldxVersionScript, reply: &event, withError: "MacLoggerDX version" ) != nil {
					if let event = event, let response = event.stringValue {
						//  check if version string starts with a 5
						if response.first == "5" { isv5 = true }
						( "Found MacLoggerDX " + response ).withCString { Messages.logMessage( $0 ) }
					}
				}
			}
			if isv5 {
				keyScript = loadScriptFor( "mldx5Key" )
				unkeyScript = loadScriptFor( "mldx5Unkey" )
			}
			else {
				keyScript = loadScriptFor( "mldxKey" )
				unkeyScript = loadScriptFor( "mldxUnkey" )
			}
		}
	}

	@objc override func connected() -> Bool
	{
		return ( keyScript != nil && unkeyScript != nil )
	}

	@objc(setPTTState:)
	override func setPTTState( _ state: Bool )
	{
		//  don't do anything unless both scripts exist
		if keyScript == nil || unkeyScript == nil { return }

		if state {
			keyScript = executeScript( keyScript!, withError: "MacLoggerDX PTT on" )
			if keyScript != nil { interfaceConnected = true }
		}
		else {
			unkeyScript = executeScript( unkeyScript!, withError: "MacLoggerDX PTT off" )
			if unkeyScript != nil { interfaceConnected = true }
		}
	}
}
